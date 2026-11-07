-- dfai-watchpost: a roof over the fort entrance with bolt throwers on top, the
-- fort's watch post for fliers and anything coming at the gate (user: "modify
-- the entrance to have a roof and bolt throwers up top and thats the 'watch
-- post' for flyers and such"). Guard duty (dfai-guard) stations squads up here.
--
-- WHERE: just inside the curtain wall's gate, on flat natural ground with
-- solid undug rock under every tile and no df-ai room planned beneath. Never
-- over the fort's stair head: Cloisterbolt's post stood over the entrance
-- stair shaft, the ground under it caved in six times and dropped stone, logs
-- and cages down the shaft (13 dwarves and pets dead); Machinegems died the
-- same way at its stair head. A post found standing over dug ground is
-- retired: no guards on it, nothing more built there (its roof is left
-- alone: pulling it down could start another collapse).
--
-- The roof (constructed floor, one level over the yard, 7x7) goes
-- up one ring at a time from whatever already holds it (the hillside, a
-- bunker roof next to it): a roof tile is only placed beside a tile that is
-- already solid, so nothing is ever built unsupported (a floating floor
-- finished first would come down on whoever is below). A built stair in the
-- yard takes builders, the guards and the operators up. Then four bolt
-- throwers on the roof's edges, facing N, E, S and W, firing at enemies only.
--   dfai-watchpost start | status | find
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-watchpost'
local R = 3   -- the roof reaches R tiles out from the entrance

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end
local function shape(x, y, z) local a = attrs(x, y, z) return a and a.shape end
local S = df.tiletype_shape

local function stair_head()
    local ok, d = pcall(require('json').decode_file, dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json')
    if ok and type(d) == 'table' and d.site_id == df.global.plotinfo.site_id then
        for _, p in ipairs(d.pois or {}) do if p.kind == 'Entrance' then return p end end
    end
end

local planned = (function()
    local ok, P = pcall(require, 'plugins.df-ai')
    return ok and P.planned_room_at or function() return '' end
end)()

-- the ground under the post: every tile of the footprint natural open floor
-- on level z with solid wall right under it, and no df-ai room planned on
-- that level under it or a tile around it, so it stays solid. (What came
-- down at Cloisterbolt was ground resting on open space; rooms further down
-- under a solid layer are fine.)
-- (new = choosing a site: the yard must be open natural floor too; an
-- existing post only needs the solid ground, as its stair and roof change
-- the yard's tiles)
local function is_tree(x, y, z)
    local a = attrs(x, y, z)
    return a and a.material == df.tiletype_material.TREE
end

local function real_building(x, y, z)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    local t = b and b:getType()
    return t and t ~= df.building_type.Civzone and t ~= df.building_type.Stockpile
end

-- (new = choosing a site: the yard must be open natural floor too, apart
-- from trees, which are counted (they get felled); an existing post only
-- needs the solid ground, as its stair and roof change the yard's tiles)
local function sound_ground(x1, y1, x2, y2, z, new)
    local trees = 0
    for x = x1, x2 do for y = y1, y2 do
        if new then
            if is_tree(x, y, z) or is_tree(x, y, z + 1) then
                trees = trees + 1
            else
                -- the roof goes a level up, so traps, workshops and walls on
                -- the ground are fine under it; the roof level must be free
                local f = dfhack.maps.getTileFlags(x, y, z)
                if not f or f.flow_size > 0 then return false, 'water' end
                -- caravans come first: never over the trade depot
                local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
                if b and b:getType() == df.building_type.TradeDepot then return false, 'the trade depot' end
                if shape(x, y, z + 1) ~= S.EMPTY then return false, 'something at roof height' end
            end
        end
        if not is_tree(x, y, z) and shape(x, y, z - 1) ~= S.WALL then return false, 'dug ground under it' end
    end end
    for dz = 1, 1 do
        local ok, r = pcall(planned, x1 - 1, y1 - 1, x2 + 1, y2 + 1, z - dz)
        if ok and r and r ~= '' then return false, 'df-ai plans a room under it' end
    end
    return true, nil, trees
end

-- the curtain wall's gate and the way into the fort from it
local function gate()
    local w = dfhack.persistent.getSiteData('dfai-walls', {})
    local g = (w.gates and w.gates[1]) or (w.gate and {x = w.gate[1], y = w.gate[2]})
    if not g or not w.box then return nil end
    local b = w.box
    local side = g.side or w.side
    if not side then
        local d = {N = math.abs(g.y - b.y1), S = math.abs(g.y - b.y2), W = math.abs(g.x - b.x1), E = math.abs(g.x - b.x2)}
        side = 'N' for k, v in pairs(d) do if v < d[side] then side = k end end
    end
    local inward = ({N = {0, 1}, S = {0, -1}, W = {1, 0}, E = {-1, 0}})[side]
    return {x = g.x, y = g.y, side = side, ix = inward[1], iy = inward[2], box = b}
end

local function ground_z(x, y)
    for z = df.global.world.map.z_count - 2, 1, -1 do
        local a = attrs(x, y, z)
        local f = dfhack.maps.getTileFlags(x, y, z)
        if a and f and f.outside and a.shape ~= S.EMPTY and a.material ~= df.tiletype_material.TREE then return z end
    end
end

-- a yard for the post: from a few tiles inside the gate, further in and to
-- either side, the first sound 7x7 that keeps clear of the stair head
local function entrance()
    local g = gate()
    if not g then return nil end
    local head = stair_head()
    local why, best
    local tally = {}
    for k = R + 3, R + 14 do
        for _, side in ipairs({0, 2, -2, 4, -4, 6, -6}) do
            local cx = g.x + g.ix * k + (g.iy ~= 0 and side or 0)
            local cy = g.y + g.iy * k + (g.ix ~= 0 and side or 0)
            local z = ground_z(cx, cy)
            if z and cx - R > g.box.x1 + 1 and cx + R < g.box.x2 - 1 and cy - R > g.box.y1 + 1 and cy + R < g.box.y2 - 1
                and not (head and math.abs(head.x - cx) <= R + 3 and math.abs(head.y - cy) <= R + 3) then
                local ok, w, trees = sound_ground(cx - R, cy - R, cx + R, cy + R, z, true)
                if ok and trees == 0 then return {x = cx, y = cy, z = z} end
                if ok then
                    if not best or trees < best.trees then best = {x = cx, y = cy, z = z, trees = trees} end
                else
                    why = w
                    tally[w] = (tally[w] or 0) + 1
                end
            end
        end
    end
    if best then return best end   -- trees on it: felled first (step)
    local t = {}
    for k, v in pairs(tally) do t[#t + 1] = ('%s %d'):format(k, v) end
    return nil, why and ('no sound ground inside the gate (' .. table.concat(t, ', ') .. ')') or 'no flat ground inside the gate'
end

-- solid enough to hold a roof tile beside it: a wall, or a floor that is
-- itself held (natural ground, a constructed floor, a stair top)
local function holds(x, y, z)
    local a = attrs(x, y, z)
    if not a then return false end
    if a.shape == S.WALL or a.shape == S.FORTIFICATION then return true end
    if a.shape == S.FLOOR or a.shape == S.STAIR_DOWN or a.shape == S.STAIR_UPDOWN or a.shape == S.RAMP_TOP then
        return a.material == df.tiletype_material.CONSTRUCTION or shape(x, y, z - 1) == S.WALL
    end
    return false
end

-- the plan for this entrance: the roof box, the stair tile, the engine tiles
local function plan(e)
    local p = {x1 = e.x - R, y1 = e.y - R, x2 = e.x + R, y2 = e.y + R, z = e.z, roof = e.z + 1}
    -- the stair: a free natural floor tile in the yard on solid ground, not
    -- under an engine, nearest the middle first
    local cand = {}
    for x = p.x1 + 1, p.x2 - 1 do for y = p.y1 + 1, p.y2 - 1 do
        if not (x == e.x and y == e.y) then cand[#cand + 1] = {x, y, math.abs(x - e.x) + math.abs(y - e.y)} end
    end end
    table.sort(cand, function(a, b) return a[3] < b[3] end)
    for _, c in ipairs(cand) do
        local x, y = c[1], c[2]
        local a = attrs(x, y, e.z)
        local hi = shape(x, y, e.z + 1)
        if a and (a.shape == S.FLOOR or a.shape == S.SHRUB or a.shape == S.PEBBLES) and a.material ~= df.tiletype_material.CONSTRUCTION
            and not real_building(x, y, e.z) and shape(x, y, e.z - 1) == S.WALL
            and (hi == S.EMPTY or hi == S.STAIR_DOWN) then
            p.sx, p.sy = x, y
            break
        end
    end
    if not p.sx then return nil, 'no free floor in the entrance yard for a stair' end
    p.engines = {
        {x = e.x, y = e.y - R, face = 0, name = 'N'}, {x = e.x + R, y = e.y, face = 2, name = 'E'},
        {x = e.x, y = e.y + R, face = 4, name = 'S'}, {x = e.x - R, y = e.y, face = 6, name = 'W'},
    }
    return p
end

local function parts_free()
    local n = 0
    for _, i in ipairs(df.global.world.items.other.BOLT_THROWER_PARTS or {}) do
        if not i.flags.in_building and not i.flags.forbid and not i.flags.in_job then n = n + 1 end
    end
    return n
end
local function orders_for(jt)
    local n = 0
    for _, mo in ipairs(df.global.world.manager_orders.all) do if mo.job_type == jt then n = n + mo.amount_left end end
    return n
end
local function engine_at(x, y, z)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    if b and b:getType() == df.building_type.SiegeEngine then return b end
end

-- a plan whose ground is not sound (an older post over the stair head)
local function sound_plan(p)
    return p and p.x1 and sound_ground(p.x1, p.y1, p.x2, p.y2, p.z)
end

-- unfinished engines on a retired roof are taken back (built ones and the
-- roof itself stay: removing them could set off another collapse)
local function retire(s)
    local p = s.plan
    local n = 0
    for _, g in ipairs(p.engines or {}) do
        local b = engine_at(g.x, g.y, p.roof)
        if b and b:getBuildStage() < b:getMaxBuildStage() then
            dfhack.buildings.deconstruct(b)
            n = n + 1
        end
    end
    s.retired = s.retired or {}
    table.insert(s.retired, {x1 = p.x1, y1 = p.y1, x2 = p.x2, y2 = p.y2, z = p.z, roof = p.roof})
    s.plan = nil
    for k in pairs(s) do if tostring(k):find('^armed_') then s[k] = nil end end
    s.announced = nil
    return n
end

local function step(s)
    if s.plan and not sound_plan(s.plan) then
        local n = retire(s)
        dfhack.gui.showAnnouncement('The watch post over the stair shaft is retired: the ground under it is dug out. A new one goes up inside the gate.', COLOR_YELLOW, true)
        s.note = ('retired the post at %d,%d (dug ground under it); %d unfinished bolt throwers taken back'):format(s.retired[#s.retired].x1 + R, s.retired[#s.retired].y1 + R, n)
    end
    if not s.plan then
        local e, ewhy = entrance()
        if not e then return 'waiting: ' .. (ewhy or 'no gate yet') .. (s.note and ('; ' .. s.note) or '') end
        local p, why = plan(e)
        if not p then return 'waiting: ' .. why end
        p.ex, p.ey = e.x, e.y
        s.plan = p
    end
    local p = s.plan
    -- parts for the four engines, from the start
    dfhack.run_command_silent('autolabor', 'SIEGECRAFT', '1', '3')
    local built = 0
    for _, g in ipairs(p.engines) do if engine_at(g.x, g.y, p.roof) then built = built + 1 end end
    local want = #p.engines - built
    if want > 0 and parts_free() + orders_for(df.job_type.ConstructBoltThrowerParts) < want then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructBoltThrowerParts","amount_total":%d,"material_category":["wood"]}')
            :format(want - parts_free() - orders_for(df.job_type.ConstructBoltThrowerParts)))
    end
    -- trees on the yard or reaching over the roof come down first
    local standing = 0
    for _, pl in ipairs(df.global.world.plants.all) do
        local t = pl.pos
        if t.z == p.z and t.x >= p.x1 - 2 and t.x <= p.x2 + 2 and t.y >= p.y1 - 2 and t.y <= p.y2 + 2 and pl.tree_info then
            local over = false
            for x = p.x1, p.x2 do for y = p.y1, p.y2 do
                if is_tree(x, y, p.z) or is_tree(x, y, p.roof) then over = true end
            end end
            if over then
                standing = standing + 1
                pcall(dfhack.designations.markPlant, pl)
            end
        end
    end
    if standing > 0 then
        local still = 0
        for x = p.x1, p.x2 do for y = p.y1, p.y2 do
            if is_tree(x, y, p.z) or is_tree(x, y, p.roof) then still = still + 1 end
        end end
        if still > 0 then return ('felling the trees on the watch post yard (%d tiles of tree left)'):format(still) end
    end
    -- the stair
    local lo, hi = shape(p.sx, p.sy, p.z), shape(p.sx, p.sy, p.roof)
    if not (lo == S.STAIR_UP or lo == S.STAIR_UPDOWN) then
        if not dfhack.buildings.findAtTile(xyz2pos(p.sx, p.sy, p.z)) then
            dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.UpStair, pos = xyz2pos(p.sx, p.sy, p.z)}
        end
        return 'building the stair up from the entrance yard'
    end
    if not (hi == S.STAIR_DOWN or hi == S.STAIR_UPDOWN) then
        if not dfhack.buildings.findAtTile(xyz2pos(p.sx, p.sy, p.roof)) then
            dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.DownStair, pos = xyz2pos(p.sx, p.sy, p.roof)}
        end
        return 'building the top of the stair'
    end
    -- the roof, a ring at a time from what holds it
    local left, placed = 0, 0
    for x = p.x1, p.x2 do for y = p.y1, p.y2 do
        if not (x == p.sx and y == p.sy) and shape(x, y, p.roof) == S.EMPTY then
            left = left + 1
            if not dfhack.buildings.findAtTile(xyz2pos(x, y, p.roof)) then
                local held = false
                for dx = -1, 1 do for dy = -1, 1 do
                    if (dx ~= 0 or dy ~= 0) and holds(x + dx, y + dy, p.roof) then held = true end
                end end
                if held and placed < 12 then
                    if dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.Floor, pos = xyz2pos(x, y, p.roof)} then
                        placed = placed + 1
                    end
                end
            end
        end
    end end
    if left > 0 then return ('roofing the entrance: %d tiles to go'):format(left) end
    -- the engines on the roof's edges
    local waiting = 0
    for _, g in ipairs(p.engines) do
        local b = engine_at(g.x, g.y, p.roof)
        if not b then
            if parts_free() > 0 then
                dfhack.buildings.constructBuilding{type = df.building_type.SiegeEngine, subtype = df.siegeengine_type.BoltThrower,
                    pos = xyz2pos(g.x, g.y, p.roof), width = 1, height = 1}
            end
            waiting = waiting + 1
        elseif b:getBuildStage() < b:getMaxBuildStage() then
            waiting = waiting + 1
        elseif not s['armed_' .. g.name] then
            local face = g.face
            dfhack.timeout(1, 'ticks', function()
                b.facing, b.resting_orientation = face, face
                b.action = df.siegeengine_action.FireAtWill   -- enemies only; metal bolts are for killing
            end)
            s['armed_' .. g.name] = true
        end
    end
    if waiting > 0 then return ('roof done; %d of 4 bolt throwers still to build'):format(waiting) end
    dfhack.run_command_silent('autolabor', 'SIEGEOPERATE', '2', '6')
    if not s.announced then
        s.announced = true
        dfhack.gui.showAnnouncement('The watch post over the fort entrance is ready: four bolt throwers on its roof.', COLOR_LIGHTGREEN, true)
    end
    return 'ready: roof over the entrance, four bolt throwers on top'
end

-- where the guards stand: the middle of the roof
function posts()
    local s = load()
    if s.plan and s.plan.ex and shape(s.plan.ex, s.plan.ey, s.plan.roof) == S.FLOOR and sound_plan(s.plan) then
        return {{s.plan.ex, s.plan.ey, s.plan.roof}}
    end
    return {}
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    -- the yard is the walled ground inside the curtain wall's gate: before
    -- the wall stands, the "entrance" is the fort's stair head, and the stair
    -- went into the stair shaft (Machinegems: waited there for two years)
    local w = dfhack.persistent.getSiteData('dfai-walls', {})
    if not s.plan and not ((w.gates and #w.gates > 0) or w.gate) then
        s.last = 'waits for the curtain wall (the watch post stands over its entrance yard)'
        save(s)
        return
    end
    local ok, msg = pcall(step, s)
    s.last = ok and msg or ('error: ' .. tostring(msg))
    save(s)
end

function status() return 'watch post: ' .. (load().last or 'idle') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('watch post: watching')
elseif cmd == 'find' then
    local e, ewhy = entrance()
    if not e then print('no: ' .. tostring(ewhy or 'no gate yet')) return end
    local p, why = plan(e)
    if not p then print('no: ' .. why) return end
    print(('roof %d,%d..%d,%d on level %d; stair at %d,%d; engines at %s'):format(p.x1, p.y1, p.x2, p.y2, p.roof, p.sx, p.sy,
        table.concat((function() local t = {} for _, g in ipairs(p.engines) do t[#t + 1] = ('%s %d,%d'):format(g.name, g.x, g.y) end return t end)(), ', ')))
else
    print(status())
end
