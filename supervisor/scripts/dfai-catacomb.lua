-- dfai-catacomb: dig and furnish a new catacomb wing on the Overseer's order
-- (user: "might need more catacombs"). Finds solid, dry rock beside a corridor
-- on a level that already has catacombs, digs a 9x5 vault behind a doorway,
-- then fills it with quickfort: 18 coffins (top and bottom rows, an aisle
-- between), a door, and a 1-tile tomb zone on each coffin (as df-ai's own
-- catacombs have). Coffins come from the fort's stock; df-ai makes more when
-- it runs short.
--   dfai-catacomb new        plan one now (a second order queues after it)
--   dfai-catacomb status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-catacomb'
local W, H = 9, 5
local BP = 'dfai-gen/catacomb.csv'

local function load() return dfhack.persistent.getSiteData(KEY, {wings = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function project(fn, ...)
    local a = {...}
    pcall(function() reqscript('dfai-projects')[fn](table.unpack(a)) end)
end
local function attrs(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt]
end
local function is_wall(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == df.tiletype_shape.WALL and a.material ~= df.tiletype_material.CONSTRUCTION
        and a.material ~= df.tiletype_material.TREE and a.material ~= df.tiletype_material.ROOT
end
local function is_floor(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == df.tiletype_shape.FLOOR
end
-- no water, magma, caverns, outside or hidden holes anywhere around the tile
local function safe(x, y, z)
    if not dfhack.maps.isValidTilePos(x, y, z) or not is_wall(x, y, z) then return false end
    for dz = -1, 1 do for dx = -1, 1 do for dy = -1, 1 do
        local f = dfhack.maps.getTileFlags(x + dx, y + dy, z + dz)
        if not f then return false end
        if f.flow_size > 0 or f.water_table or f.outside or f.feature_global or f.feature_local then return false end
        local a = attrs(x + dx, y + dy, z + dz)
        if a and dz ~= 0 and a.shape == df.tiletype_shape.EMPTY then return false end
    end end end
    return true
end

-- a vault: doorway (dx,dy) from the corridor tile, room beyond it

-- designate a tile for digging with a priority (quickfort's own designation of
-- the doorway didn't stick: the corridor walls are smoothed, and something
-- clears it); the room behind it stays hidden until the doorway is open
local function designate(x, y, z, prio)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    if not f or not b then return end
    f.dig = df.tile_dig_designation.Default
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = prio or 2000
    b.flags.designated = true
end
-- (a designated tile becomes a Dig job and its flag clears: only re-mark
-- tiles with neither, or every check piles up another job)
local function keep_digging(w)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local jobs = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.Dig and j.pos.z == w.z then jobs[j.pos.x * 10000 + j.pos.y] = true end
        l = l.next
    end
    local function want(x, y)
        if not is_floor(x, y, w.z) and not jobs[x * 10000 + y] and dfhack.maps.getTileFlags(x, y, w.z).dig == df.tile_dig_designation.No then
            designate(x, y, w.z, 2000)
        end
    end
    want(w.door[1], w.door[2])
    for x = x1, x2 do for y = y1, y2 do want(x, y) end end
end
local DIRS = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
local function room_box(fx, fy, d)
    local dx, dy = d[1], d[2]
    local doorx, doory = fx + dx, fy + dy
    local x1, y1, x2, y2
    if dy ~= 0 then   -- north/south: the room's long side faces the corridor
        x1, x2 = doorx - (W // 2), doorx + (W // 2)
        if dy < 0 then y2 = doory - 1 y1 = y2 - H + 1 else y1 = doory + 1 y2 = y1 + H - 1 end
    else
        y1, y2 = doory - (W // 2), doory + (W // 2)
        if dx < 0 then x2 = doorx - 1 x1 = x2 - H + 1 else x1 = doorx + 1 x2 = x1 + H - 1 end
    end
    return doorx, doory, x1, y1, x2, y2
end
local function fits(fx, fy, z, d)
    local doorx, doory, x1, y1, x2, y2 = room_box(fx, fy, d)
    if not safe(doorx, doory, z) then return nil end
    for x = x1 - 1, x2 + 1 do for y = y1 - 1, y2 + 1 do
        if not (x == doorx and y == doory) and not is_wall(x, y, z) then return nil end
        if x >= x1 and x <= x2 and y >= y1 and y <= y2 and not safe(x, y, z) then return nil end
    end end
    if reqscript('dfai-plan').planned_room_at(x1, y1, x2, y2, z) then return nil end
    return {door = {doorx, doory}, box = {x1, y1, x2, y2}, z = z, long_x = d[2] ~= 0}
end

local function find_site()
    -- levels with catacombs, nearest the biggest cluster first
    local lv, cx, cy = {}, {}, {}
    for _, t in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
        lv[t.z] = (lv[t.z] or 0) + 1
        cx[t.z] = (cx[t.z] or 0) + t.x1
        cy[t.z] = (cy[t.z] or 0) + t.y1
    end
    local levels = {}
    for z, n in pairs(lv) do levels[#levels + 1] = {z = z, n = n, x = cx[z] // n, y = cy[z] // n} end
    table.sort(levels, function(a, b) return a.n > b.n end)
    local cit = dfhack.units.getCitizens(true)[1]
    for _, L in ipairs(levels) do
        local best, bd
        for x = L.x - 30, L.x + 30 do for y = L.y - 30, L.y + 30 do
            if is_floor(x, y, L.z) and not dfhack.buildings.findAtTile(xyz2pos(x, y, L.z))
                and (not cit or dfhack.maps.canWalkBetween(cit.pos, xyz2pos(x, y, L.z))) then
                for _, d in ipairs(DIRS) do
                    local f = fits(x, y, L.z, d)
                    if f then
                        local dist = (x - L.x) ^ 2 + (y - L.y) ^ 2
                        if not bd or dist < bd then best, bd = f, dist end
                    end
                end
            end
        end end
        if best then return best end
    end
end

-- the blueprint for one wing, written fresh each time (quickfort runs it)
local function write_bp(w)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local gx1, gy1 = math.min(x1, w.door[1]), math.min(y1, w.door[2])
    local gx2, gy2 = math.max(x2, w.door[1]), math.max(y2, w.door[2])
    local function grid(fn)
        local rows = {}
        for y = gy1, gy2 do
            local r = {}
            for x = gx1, gx2 do r[#r + 1] = fn(x, y) or '' end
            rows[#rows + 1] = table.concat(r, ',')
        end
        return table.concat(rows, '\n')
    end
    local function coffin(x, y)
        if x < x1 or x > x2 or y < y1 or y > y2 then return false end
        if w.long_x then return y == y1 or y == y2 else return x == x1 or x == x2 end
    end
    local body = '#dig label(dig) start(1;1)\n' .. grid(function(x, y)
            if (x == w.door[1] and y == w.door[2]) or (x >= x1 and x <= x2 and y >= y1 and y <= y2) then return 'd' end end)
        .. '\n#build label(build) start(1;1)\n' .. grid(function(x, y)
            if x == w.door[1] and y == w.door[2] then return 'd' end
            if coffin(x, y) then return 'n' end end)
        .. '\n#zone label(zone) start(1;1)\n' .. grid(function(x, y) if coffin(x, y) then return 'T' end end) .. '\n'
    local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
    dfhack.filesystem.mkdir_recursive(dir)
    local f = io.open(dir .. '/catacomb.csv', 'w')
    f:write(body)
    f:close()
    return gx1, gy1
end
local function qf(w, label)
    local gx, gy = write_bp(w)
    return dfhack.run_command_silent('quickfort', 'run', BP, '-n', '/' .. label, '-c', ('%d,%d,%d'):format(gx, gy, w.z))
end
local function count(w, fn)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local n, of = 0, 0
    for x = x1, x2 do for y = y1, y2 do of = of + 1 if fn(x, y) then n = n + 1 end end end
    return n, of
end

local function step(s)
    local w = s.current
    if not w then
        if (s.queued or 0) <= 0 then return end
        w = find_site()
        if not w then s.last = 'no solid dry rock beside a corridor near the catacombs' s.queued = 0 return end
        s.queued = s.queued - 1
        w.phase = 'dig'
        w.key = ('catacomb-%d'):format(#s.wings + 1)
        s.current = w
        qf(w, 'dig')
        project('add', w.key, 'A New Catacomb Wing', w.box[1], w.box[2], w.z, w.box[3], w.box[4], w.z, true)
        s.last = ('digging a new catacomb wing at %d,%d,%d'):format(w.box[1], w.box[2], w.z)
        return
    end
    if w.phase == 'dig' then
        local dug, of = count(w, function(x, y) return is_floor(x, y, w.z) end)
        s.last = ('digging the new catacomb wing: %d of %d'):format(dug, of)
        if dug == of and is_floor(w.door[1], w.door[2], w.z) then
            w.phase = 'build'
            qf(w, 'build')
        else
            keep_digging(w)
        end
    elseif w.phase == 'build' then
        local placed = count(w, function(x, y)
            local b = dfhack.buildings.findAtTile(xyz2pos(x, y, w.z))
            return b and b:getType() == df.building_type.Coffin and b:getBuildStage() >= b:getMaxBuildStage()
        end)
        s.last = ('furnishing the new catacomb wing: %d of 18 coffins'):format(placed)
        -- quickfort places a coffin only where a free coffin exists at that
        -- moment: Cloisterbolt's wing sat at 7 of 18 for good with 102 coffins
        -- in stock, because the build ran once. Re-run it now and then
        -- (built and placed tiles are skipped), and zone the wing once no
        -- coffin has been added for a few passes even if some tiles can't
        -- take one.
        w.passes = (w.passes or 0) + 1
        if placed ~= w.placed then w.placed, w.since = placed, w.passes end
        if w.passes % 5 == 0 then qf(w, 'build') end
        if placed >= 18 or (placed > 0 and w.passes - (w.since or 0) >= 30) then
            w.phase = 'zone'
        end
    elseif w.phase == 'zone' then
        -- one tomb per coffin: DFHack's burial zones only coffins that have
        -- no zone yet. (A quickfort zone pass on top of coffins that burial
        -- had already zoned made two tombs on one coffin, and neither was
        -- ever filled: 4 such pairs at Cloisterbolt.)
        dfhack.run_command_silent('burial')
        -- quickfort's tombs refuse citizens by default: open them to the dead
        local x1, y1, x2, y2 = table.unpack(w.box)
        for _, t in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
            if t.z == w.z and t.x1 >= x1 and t.x1 <= x2 and t.y1 >= y1 and t.y1 <= y2 then
                t.zone_settings.tomb.flags.no_citizens = false
            end
        end
        w.phase = 'done'
        table.insert(s.wings, {box = w.box, z = w.z, door = w.door})
        s.current = nil
        project('done', w.key)
        s.last = ('new catacomb wing ready: 18 tombs at level %d'):format(w.z)
    end
end

local tick   -- defined below; watch() starts it

-- The dead and the room for them. Unburied: bodies of the fort's dead (any
-- citizen, and named pets) not in a coffin. Free: tombs nobody is assigned to
-- that take citizens.
local function census()
    local civ = df.global.plotinfo.civ_id
    local fg
    do
        local c = dfhack.units.getCitizens(true)[1]
        fg = c and dfhack.maps.getWalkableGroup(c.pos)
    end
    local dead = {}
    for _, u in ipairs(df.global.world.units.all) do
        if dfhack.units.isDead(u) and u.civ_id == civ and u.hist_figure_id ~= -1 then dead[u.hist_figure_id] = u end
    end
    local unburied, reachable, body_ok = 0, 0, {}
    for _, i in ipairs(df.global.world.items.other.CORPSE) do
        local u = dead[i.hist_figure_id]
        if u and not i.flags.in_building and not i.flags.removed then
            unburied = unburied + 1
            local x, y, z = dfhack.items.getPosition(i)
            if x and fg and dfhack.maps.getWalkableGroup(xyz2pos(x, y, z)) == fg then
                reachable = reachable + 1
                body_ok[i.hist_figure_id] = true
            end
        end
    end
    local free = 0
    for _, t in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
        if t.assigned_unit_id == -1 and not t.zone_settings.tomb.flags.no_citizens then free = free + 1 end
    end
    return {unburied = unburied, reachable = reachable, free = free, body_ok = body_ok, dead = dead}
end

-- Two tomb zones on one coffin: DF assigns both and fills neither (four
-- coffins at Cloisterbolt stood empty this way while the dead lay on the
-- corpse pile). Keep one zone per coffin - the one assigned to a dead unit
-- whose body can be carried in, else a dead unit, else any - and remove the
-- rest (a removed zone is what the zone menu's remove does).
function dedupe_tombs(fg)
    local by = {}
    for _, t in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
        for _, b in ipairs(t.contained_buildings or {}) do
            if b:getType() == df.building_type.Coffin then
                by[b.id] = by[b.id] or {}
                table.insert(by[b.id], t)
            end
        end
    end
    local body_reach = {}
    for _, i in ipairs(df.global.world.items.other.CORPSE) do
        if not i.flags.in_building then
            local x, y, z = dfhack.items.getPosition(i)
            if x and fg and dfhack.maps.getWalkableGroup(xyz2pos(x, y, z)) == fg then body_reach[i.unit_id] = true end
        end
    end
    local function score(t)
        local u = t.assigned_unit_id ~= -1 and df.unit.find(t.assigned_unit_id)
        if u and dfhack.units.isDead(u) and body_reach[u.id] then return dfhack.units.isDwarf(u) and 4 or 3 end   -- a dwarf before a pet
        if u and dfhack.units.isDead(u) then return 2 end
        if u then return 1 end
        return 0
    end
    local drop = {}
    for _, zs in pairs(by) do
        if #zs > 1 then
            table.sort(zs, function(a, b) local sa, sb = score(a), score(b) if sa ~= sb then return sa > sb end return a.id < b.id end)
            for i = 2, #zs do drop[#drop + 1] = zs[i].id end
        end
    end
    for _, id in ipairs(drop) do   -- ids first: never remove while walking the list
        local z = df.building.find(id)
        if z then dfhack.buildings.deconstruct(z) end
    end
    return #drop
end

-- every so often: a wing when the reachable dead outnumber the free tombs, and
-- memorial slabs only where a body can't be buried (a ghost always gets one)
local function watch()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local ok, err = pcall(function()
        local s = load()
        do
            local c1 = dfhack.units.getCitizens(true)[1]
            local n = dedupe_tombs(c1 and dfhack.maps.getWalkableGroup(c1.pos))
            if n > 0 then s.deduped = (s.deduped or 0) + n end
        end
        local c = census()
        s.census = {unburied = c.unburied, reachable = c.reachable, free = c.free}
        if c.reachable > c.free and not s.current and (s.queued or 0) <= 0 then
            s.queued = 1
            s.last = ('%d of the dead can be carried to a tomb and only %d tombs are free: digging another wing'):format(c.reachable, c.free)
            repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
        end
        -- (Never delete manager orders from Lua: erasing 112 engraving orders
        -- from the list was followed by DF crashing on load. Surplus orders
        -- are left to wait; df-ai no longer queues duplicates.)
        save(s)
    end)
    if not ok then dfhack.printerr('dfai-catacomb watch: ' .. tostring(err)) end
end

function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(step, s)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
    if not s.current and (s.queued or 0) <= 0 then repeatUtil.cancel(KEY) end
end

function status()
    local s = load()
    local free = 0
    for _, t in ipairs(df.global.world.buildings.other.ZONE_TOMB) do if t.assigned_unit_id == -1 then free = free + 1 end end
    local c = s.census
    return ('catacombs: %d tomb zones, %d unclaimed; %s%s%s'):format(#df.global.world.buildings.other.ZONE_TOMB, free,
        s.last or 'no new wings ordered', (s.queued or 0) > 0 and (' (%d more ordered)'):format(s.queued) or '',
        c and ('; the dead: %d unburied, %d of them can be carried in, %d tombs free'):format(c.unburied, c.reachable, c.free) or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1]
if cmd == 'new' then
    local s = load()
    s.queued = (s.queued or 0) + 1
    save(s)
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print('catacombs: a new wing ordered')
elseif cmd == 'find' then
    -- dry run: where would a wing go, and what would quickfort do there
    local t0 = os.clock()
    local w = find_site()
    if not w then print('no site') return end
    print(('site: room %d,%d..%d,%d level %d, door %d,%d (%.2fs)'):format(w.box[1], w.box[2], w.box[3], w.box[4], w.z, w.door[1], w.door[2], os.clock() - t0))
    local gx, gy = write_bp(w)
    for _, l in ipairs({'dig', 'build', 'zone'}) do
        print(l .. ': ' .. (dfhack.run_command_silent('quickfort', 'run', BP, '-n', '/' .. l, '-c', ('%d,%d,%d'):format(gx, gy, w.z), '--dry-run'):gsub('%s+', ' ')))
    end
elseif cmd == 'dedupe' then
    -- now, on a game tick; prints what it removed
    dfhack.timeout(1, 'ticks', function()
        local c1 = dfhack.units.getCitizens(true)[1]
        local ok, n = pcall(dedupe_tombs, c1 and dfhack.maps.getWalkableGroup(c1.pos))
        _G.dfai_catacomb_dedupe = ok and ('removed ' .. tostring(n) .. ' duplicate tomb zones') or ('error: ' .. tostring(n))
    end)
    print('catacombs: removing duplicate tomb zones on the next tick')
elseif cmd == 'resume' then
    local s = load()
    if s.current or (s.queued or 0) > 0 then repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick) end
    repeatUtil.scheduleEvery(KEY .. '-watch', 1200, 'ticks', watch)
    dfhack.timeout(10, 'ticks', watch)
else
    print(status())
end
