-- dfai-bunker: bolt-thrower bunkers outside the gate (user: "one day id like
-- to make little bunkers with the bolt throwers for defense ... metal bolts
-- are for killing, bone and light bolts are for training").
--
-- One bunker, front facing the nearest map edge (where invaders arrive):
--
--     W F F F F F W     W constructed wall    F fortification (the bolt
--     W z . . . . W       thrower fires through these; arrows mostly don't)
--     W z . T . . W     T bolt thrower (1x1; the operator stands behind it,
--     W z . . . . W       so the 3x3 round it stays clear)
--     W W W d W W W     z stockpile: METAL bolts only - they're for killing
--                       d door, at the back, towards the fort
--   + a roof of constructed floor over all of it, one level up
--
-- Steps: a siege workshop (dfai-build) -> bolt thrower parts (work order) ->
-- walls, fortifications, door, ammo pile -> roof -> the engine -> set to
-- face out and "fire at enemies" (never practice fire: that burns the metal
-- bolts). Siege operators and engineers are kept by autolabor.
-- Bunkers wait on the Overseer's priority list ("bunkers"); one per 40
-- citizens, at most 3.
--   dfai-bunker start | status | find (dry run: where, and quickfort's check)
--   dfai-bunker new   (one now, ignoring the priority list)
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-bunker'
local SURF = reqscript('dfai-surface')
local W, D = 7, 5          -- across, deep (front row v=0)

local function load() return dfhack.persistent.getSiteData(KEY, {built = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end

-- local (u across, v depth from the front) -> map, for a facing
local FACE = {North = 0, East = 2, South = 4, West = 6}
local function to_map(b, u, v)
    if b.face == 'North' then return b.x + u, b.y + v
    elseif b.face == 'South' then return b.x + W - 1 - u, b.y + D - 1 - v
    elseif b.face == 'East' then return b.x + D - 1 - v, b.y + u
    else return b.x + v, b.y + W - 1 - u end
end
local function box(b)   -- map rectangle
    if b.face == 'North' or b.face == 'South' then return b.x, b.y, b.x + W - 1, b.y + D - 1 end
    return b.x, b.y, b.x + D - 1, b.y + W - 1
end
local function cell(u, v)
    if v == 0 then return (u == 0 or u == W - 1) and 'wall' or 'fort' end
    if u == 0 or u == W - 1 then return 'wall' end
    if v == D - 1 then return u == W // 2 and 'door' or 'wall' end
    if u == 1 then return 'pile' end
    if u == W // 2 and v == 2 then return 'engine' end
    -- a stair up to the roof: the roof's middle can only be built from up
    -- there (built from inside, its jobs kept getting cancelled), and the
    -- roof turret's operator climbs it
    if u == W - 2 and v == 2 then return 'stair' end
    return 'floor'
end

local function entrance()
    local ok, d = pcall(require('json').decode_file, dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json')
    if ok and type(d) == 'table' and d.site_id == df.global.plotinfo.site_id then
        for _, p in ipairs(d.pois or {}) do if p.kind == 'Entrance' then return p end end
    end
end

local function good_tile(x, y, z, from)
    local a = attrs(x, y, z)
    -- flat ground; pebbles and shrubs are cleared by the construction (a sapling isn't)
    local S = df.tiletype_shape
    if not a or not (a.shape == S.FLOOR or a.shape == S.PEBBLES or a.shape == S.SHRUB)
        or a.material == df.tiletype_material.TREE then return false end
    local f = dfhack.maps.getTileFlags(x, y, z)
    if f.hidden or not f.outside or f.flow_size > 0 then return false end
    if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
    local up = attrs(x, y, z + 1)
    if not up or up.shape ~= df.tiletype_shape.EMPTY then return false end   -- room for the roof
    return true
end

function find_site()
    local e = entrance()
    if not e then return nil, 'no fort entrance known yet' end
    local mx, my = dfhack.maps.getTileSize()
    -- face the nearest map edge
    local d = {North = e.y, South = my - 1 - e.y, West = e.x, East = mx - 1 - e.x}
    local faces = {'North', 'South', 'West', 'East'}
    table.sort(faces, function(a, b) return d[a] < d[b] end)
    local cit = dfhack.units.getCitizens(true)[1]
    local res = SURF.reserved()
    -- the gate's level first, then the levels just above and below (hills)
    for _, dz in ipairs({0, 1, -1, 2, -2, 3, -3}) do
    for _, face in ipairs(faces) do
        local dx, dy = 0, 0
        if face == 'North' then dy = -1 elseif face == 'South' then dy = 1 elseif face == 'West' then dx = -1 else dx = 1 end
        for dist = 5, 24 do
            for side = 0, 16 do
                for _, sgn in ipairs({1, -1}) do
                    local off = side * sgn
                    -- the bunker's middle 'dist' tiles out from the gate, slid sideways by 'off'
                    local cx, cy = e.x + dx * dist + (dx == 0 and off or 0), e.y + dy * dist + (dy == 0 and off or 0)
                    local b = {face = face, z = e.z + dz}
                    if face == 'North' or face == 'South' then b.x, b.y = cx - W // 2, cy - D // 2 else b.x, b.y = cx - D // 2, cy - W // 2 end
                    local x1, y1, x2, y2 = box(b)
                    local ok = x1 > 2 and y1 > 2 and x2 < mx - 3 and y2 < my - 3
                    -- keep clear of other bunkers, projects and the curtain wall
                    if ok and SURF.taken(x1, y1, x2, y2, b.z, 3, res) then ok = false end
                    for x = x1, x2 do
                        if not ok then break end
                        for y = y1, y2 do if not good_tile(x, y, b.z) then ok = false break end end
                    end
                    if ok then
                        local bx, by = to_map(b, W // 2, D)     -- just outside the door
                        if cit and not dfhack.maps.canWalkBetween(cit.pos, xyz2pos(bx, by, b.z)) then ok = false end
                    end
                    if ok then b.x1, b.y1, b.x2, b.y2 = x1, y1, x2, y2 return b end
                end
            end
        end
    end
    end
    return nil, 'no flat, open ground near the gate'
end

-- quickfort blueprints for one bunker
local function write_bp(b)
    local x1, y1, x2, y2 = box(b)
    local grid = {}
    for v = 0, D - 1 do for u = 0, W - 1 do local x, y = to_map(b, u, v) grid[x * 1000 + y] = cell(u, v) end end
    local function rows(fn)
        local r = {}
        for y = y1, y2 do
            local row = {}
            for x = x1, x2 do row[#row + 1] = fn(grid[x * 1000 + y], x, y) or '' end
            r[#r + 1] = table.concat(row, ',')
        end
        return table.concat(r, '\n')
    end
    local ex, ey = to_map(b, W // 2, 2)
    local body = '#build label(walls) start(1;1)\n' .. rows(function(c) return ({wall = 'Cw', fort = 'CF'})[c] end)
        -- the door goes in once the walls stand (a door needs a wall to hang on)
        .. '\n#build label(door) start(1;1)\n' .. rows(function(c) return c == 'door' and 'd' or nil end)
        .. '\n#place label(pile) start(1;1)\n' .. rows(function(c, x, y)
            local px, py = to_map(b, 1, 1)
            if x == px and y == py then
                return ('z(%dx%d)'):format(math.abs(select(1, to_map(b, 1, 3)) - px) + 1, math.abs(select(2, to_map(b, 1, 3)) - py) + 1)
            end end)
        -- (quickfort centres a 3x3 building on its cell)
        .. '\n#build label(engine) start(1;1)\n' .. rows(function(c, x, y) if x == ex and y == ey then return 'it' end end)
        .. '\n#build label(stair) start(1;1)\n' .. rows(function(c) return c == 'stair' and 'Cu' or nil end)
    local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
    dfhack.filesystem.mkdir_recursive(dir)
    local f = io.open(dir .. '/bunker.csv', 'w') f:write(body .. '\n') f:close()
    local roof = '#build label(roof) start(1;1)\n' .. rows(function(c) return c == 'stair' and 'Cd' or 'Cf' end)
        -- a second bolt thrower on the roof, over the first: open sky, for
        -- fliers (buzzards kept interrupting the builders)
        .. '\n#build label(turret) start(1;1)\n' .. rows(function(c, x, y) if x == ex and y == ey then return 'it' end end)
    f = io.open(dir .. '/bunker_roof.csv', 'w') f:write(roof .. '\n') f:close()
end
local function qf(b, label, dry)
    write_bp(b)
    local up = label == 'roof' or label == 'turret'
    local file = up and 'dfai-gen/bunker_roof.csv' or 'dfai-gen/bunker.csv'
    local x1, y1 = box(b)
    local args = {'quickfort', 'run', file, '-n', '/' .. label, '-c', ('%d,%d,%d'):format(x1, y1, up and b.z + 1 or b.z)}
    if dry then args[#args + 1] = '--dry-run' end
    return dfhack.run_command_silent(table.unpack(args))
end

local function have_siege_workshop()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY or df.global.world.buildings.all) do
        if b:getType() == df.building_type.Workshop and b.type == df.workshop_type.Siege and b:getBuildStage() >= b:getMaxBuildStage() then return true end
    end
end
local function parts_free()
    local n = 0
    for _, i in ipairs(df.global.world.items.other.BOLT_THROWER_PARTS or {}) do
        if not i.flags.in_building and not i.flags.forbid and not i.flags.in_job then n = n + 1 end
    end
    return n
end
local function parts_ready() return parts_free() > 0 end
local function order_count(jt)
    local n = 0
    for _, mo in ipairs(df.global.world.manager_orders.all) do if mo.job_type == jt then n = n + mo.amount_left end end
    return n
end
local function built(x, y, z, want)
    local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return bld and bld:getType() == want and bld:getBuildStage() >= bld:getMaxBuildStage()
end
local function shape_is(x, y, z, sh) local a = attrs(x, y, z) return a and a.shape == sh end

-- the bunker's progress: walls+fortifications as constructed tiles, roof floors, engine
local function progress(b)
    local walls, of = 0, 0
    for v = 0, D - 1 do for u = 0, W - 1 do
        local c = cell(u, v)
        local x, y = to_map(b, u, v)
        if c == 'wall' or c == 'fort' then
            of = of + 1
            local a = attrs(x, y, b.z)
            if a and (a.shape == df.tiletype_shape.WALL or a.shape == df.tiletype_shape.FORTIFICATION) and a.material == df.tiletype_material.CONSTRUCTION then walls = walls + 1 end
        end
    end end
    local roof, rof = 0, 0
    local x1, y1, x2, y2 = box(b)
    for x = x1, x2 do for y = y1, y2 do
        rof = rof + 1
        local a = attrs(x, y, b.z + 1)
        if a and a.material == df.tiletype_material.CONSTRUCTION then roof = roof + 1 end
    end end
    return walls, of, roof, rof
end

-- the bunker's siege engine on a level (inside: b.z; the roof: b.z + 1).
-- Quickfort sizes a bolt thrower as 3x3 around its cell but DF builds it
-- 1x1 at the top-left of that, so look anywhere in the bunker.
local function engine_of(b, z)
    local x1, y1, x2, y2 = box(b)
    for x = x1, x2 do for y = y1, y2 do
        local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z or b.z))
        if bld and bld:getType() == df.building_type.SiegeEngine then return bld end
    end end
end
-- face out, fire at enemies only (never PracticeFire: metal bolts are for killing)
local function arm(e, face)
    dfhack.timeout(1, 'ticks', function()
        e.facing = FACE[face]
        e.resting_orientation = FACE[face]
        e.action = df.siegeengine_action.FireAtWill
    end)
end
-- parts for both engines (inside and on the roof), ordered from the start
local function order_parts(want)
    dfhack.run_command_silent('autolabor', 'SIEGECRAFT', '1', '3')
    local have = parts_free() + order_count(df.job_type.ConstructBoltThrowerParts)
    if have < want then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructBoltThrowerParts","amount_total":%d,"material_category":["wood"]}'):format(want - have))   -- no material: the job 'completes' and makes nothing
    end
end

local function step(s)
    local b = s.current
    if not b then return end
    if b.phase == 'workshop' then
        if have_siege_workshop() then b.phase = 'parts'
        else
            if not b.ws_ordered then dfhack.run_command_silent('dfai-build', 'new', 'workshop-ws') b.ws_ordered = true end
            s.last = 'waiting for a siege workshop' return
        end
    end
    if b.phase == 'parts' then
        order_parts(2)
        if parts_ready() then b.phase = 'walls' qf(b, 'walls') qf(b, 'pile')
        else
            s.last = 'waiting for bolt thrower parts from the siege workshop' return
        end
    end
    if b.phase == 'walls' then
        local w, of = progress(b)
        b.waits = (b.waits or 0) + 1
        if b.waits % 10 == 0 then
            -- a wall nobody can stand beside never gets built (Topcloister's
            -- last bunker wall waited 1,500 days): drop it and go on without it
            local x1, y1, x2, y2 = box(b)
            SURF.drop_unreachable(x1, y1, x2, y2, b.z, b.z)
            -- something else standing where a wall goes (df-ai put a cage trap
            -- on Topcloister's last bunker wall tile): a trap is taken up (df-ai
            -- sets traps elsewhere), anything else and that tile is left out
            for v = 0, D - 1 do for u = 0, W - 1 do
                local c = cell(u, v)
                if c == 'wall' or c == 'fort' then
                    local x, y = to_map(b, u, v)
                    local o = dfhack.buildings.findAtTile(xyz2pos(x, y, b.z))
                    if o and o:getType() ~= df.building_type.Construction then
                        if o:getType() == df.building_type.Trap then pcall(dfhack.buildings.deconstruct, o) end
                    end
                end
            end end
            qf(b, 'walls')   -- re-place anything cancelled
        end
        -- wall tiles that can't be built, counted fresh: nobody can stand beside
        -- them, or a building other than a trap is in the way
        local skip = 0
        for v = 0, D - 1 do for u = 0, W - 1 do
            local c = cell(u, v)
            if c == 'wall' or c == 'fort' then
                local x, y = to_map(b, u, v)
                local a = attrs(x, y, b.z)
                local done_ = a and (a.shape == df.tiletype_shape.WALL or a.shape == df.tiletype_shape.FORTIFICATION) and a.material == df.tiletype_material.CONSTRUCTION
                local o = dfhack.buildings.findAtTile(xyz2pos(x, y, b.z))
                if not done_ and (not SURF.reachable_beside(x, y, b.z)
                    or (o and o:getType() ~= df.building_type.Construction and o:getType() ~= df.building_type.Trap)) then skip = skip + 1 end
            end
        end end
        b.skipped = skip
        s.last = ('building the bunker walls: %d of %d%s'):format(w, of, skip > 0 and (' (%d no dwarf can reach, left out)'):format(skip) or '')
        if w + skip >= of then b.phase, b.waits = 'roof', 0 qf(b, 'door') qf(b, 'stair') qf(b, 'roof') end
        return
    end
    if b.phase == 'roof' then
        local _, _, r, rof = progress(b)
        b.waits = (b.waits or 0) + 1
        if b.waits % 10 == 0 or not b.stair_placed then qf(b, 'door') qf(b, 'stair') qf(b, 'roof') b.stair_placed = true end
        order_parts(b.engine_id and 1 or 2)
        s.last = ('roofing the bunker: %d of %d'):format(r, rof)
        if r >= rof then b.phase, b.waits = 'engine', 0 qf(b, 'engine') end
        return
    end
    if b.phase == 'engine' then
        local e = engine_of(b)
        b.waits = (b.waits or 0) + 1
        if not e and b.waits % 10 == 0 then qf(b, 'engine') end
        if e and e:getBuildStage() >= e:getMaxBuildStage() then
            local pile
            local px, py = to_map(b, 1, 2)
            pile = dfhack.buildings.findAtTile(xyz2pos(px, py, b.z))
            if pile and pile:getType() == df.building_type.Stockpile then
                dfhack.run_command_silent('stockpiles', 'import', 'metalammo', '-s', tostring(pile.id))
            end
            arm(e, b.face)
            dfhack.run_command_silent('autolabor', 'SIEGEOPERATE', '2', '6')
            b.engine_id = e.id
            b.phase, b.waits = 'turret', 0
            qf(b, 'turret')
            s.last = 'the bunker engine is ready; putting a second bolt thrower on the roof'
        else
            s.last = 'waiting for the bolt thrower to be built'
        end
        return
    end
    if b.phase == 'turret' then
        local t = engine_of(b, b.z + 1)
        b.waits = (b.waits or 0) + 1
        order_parts(t and 0 or 1)
        if not t and (b.waits % 10 == 0 or b.waits == 1) then qf(b, 'turret') end
        if t and t:getBuildStage() >= t:getMaxBuildStage() then
            arm(t, b.face)
            local x1, y1, x2, y2 = box(b)
            table.insert(s.built, {x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = b.z, face = b.face, engine = b.engine_id, turret = t.id})
            pcall(function() reqscript('dfai-projects').done('bunker' .. #s.built) end)
            s.current = nil
            s.last = ('bunker %d ready, facing %s: one bolt thrower inside, one on the roof, firing at enemies'):format(#s.built, b.face:lower())
            dfhack.gui.showAnnouncement('A bolt-thrower bunker is ready outside the gate, with a second bolt thrower on its roof.', COLOR_LIGHTGREEN, true)
        else
            s.last = (parts_ready() or t) and 'waiting for the roof bolt thrower to be built' or 'waiting for bolt thrower parts for the roof'
        end
    end
end

local function start_one(s)
    local b, why = find_site()
    if not b then s.last = 'no bunker site: ' .. tostring(why) return false end
    b.phase = 'workshop'
    s.current = b
    pcall(function() reqscript('dfai-projects').add('bunker' .. (#s.built + 1), 'A Bolt-Thrower Bunker', b.x1, b.y1, b.z, b.x2, b.y2, b.z + 1, true) end)
    s.last = ('a bunker is planned at %d,%d level %d, facing %s'):format(b.x1, b.y1, b.z, b.face:lower())
    return true
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        if not s.current then
            local want = math.min(3, math.max(1, #dfhack.units.getCitizens(true) // 40))
            if #s.built >= want then s.last = ('%d bunkers; enough for now'):format(#s.built) return end
            local okp, pri = pcall(reqscript, 'dfai-priorities')
            if okp then
                local go, why = pri.allowed('bunkers')
                if not go then s.last = 'on hold: ' .. tostring(why) return end
            end
            start_one(s)
        end
        step(s)
    end)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
end

function status()
    local s = load()
    return ('bunkers: %s; %d built'):format(s.last or 'idle', #s.built)
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('bunkers: watching')
elseif cmd == 'new' then
    local s = load()
    if s.current then print('bunkers: one is already under way') return end
    dfhack.timeout(1, 'ticks', function() local s2 = load() start_one(s2) save(s2) end)
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('bunkers: one ordered now')
elseif cmd == 'expedite' then
    -- testing only (armok): finish this bunker's placed construction sites
    -- now with DFHack's build-now, then let the next check go on to the next
    -- step. Parts still come from the siege workshop.
    local s = load()
    local b = s.current
    if not b then print('bunkers: none under way') return end
    for _, l in ipairs({'walls', 'door', 'stair', 'roof'}) do qf(b, l) end
    if b.phase == 'engine' then qf(b, 'engine') end
    if b.phase == 'turret' then qf(b, 'turret') end
    local x1, y1, x2, y2 = box(b)
    print(dfhack.run_command_silent('build-now', ('%d,%d,%d'):format(x1, y1, b.z), ('%d,%d,%d'):format(x2, y2, b.z + 1)))
    dfhack.timeout(5, 'ticks', tick)
    print(('bunkers: expedited (%s); parts free: %d'):format(b.phase, parts_free()))
elseif cmd == 'find' then
    local b, why = find_site()
    if not b then print('no site: ' .. tostring(why)) return end
    print(('site: %d,%d..%d,%d level %d, facing %s'):format(b.x1, b.y1, b.x2, b.y2, b.z, b.face))
    for _, l in ipairs({'walls', 'door', 'pile', 'stair', 'roof', 'engine', 'turret'}) do print(l .. ': ' .. (qf(b, l, true):gsub('%s+', ' '))) end
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen/bunker.csv') print(f:read('a')) f:close()
else
    print(status())
end
