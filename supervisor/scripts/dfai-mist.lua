-- dfai-mist: a wind-powered mist generator for any fort (user: big projects
-- on the priority list, "be creative and dont make anything for one specific
-- fort"). The layout is the one that ran at Showerwheels, packed as a
-- relocatable 19x11 pavilion that dfai-surface places on open ground by the
-- gate:
--
--   level z    a walled hall with doors on all four sides; the west room is
--              the "mist room": 4 statues under 4 holes in the roof
--   level z+1  the roof, with a fortification parapet; on it 4 screw pumps
--              in a ring push water round and drop it through the holes onto
--              the statues (falling water = mist), 4 windmills drive them
--
-- Steps: walls (+ statues) -> roof -> pumps, gears, axles, windmills -> once
-- the windmills turn, a priming pond on one hole: dwarves bucket water in;
-- with about three buckets inside the pond zone is removed (no top-ups, no
-- floods) and the ring runs on its own. Parts come from work orders
-- (quickfort orders). Waits on the Overseer's priority list ("mist").
--   dfai-mist start | status | find (dry run) | now
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-mist'
local W, H = 19, 11

-- the layout, west to east, north to south
local A = [[
Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,d,Cw,Cw,Cw,Cw
Cw,,,,,,,,Cw,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,,d
Cw,,,,,,,,Cw,,,,,,,,,,Cw
d,,,,,,,,d,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,,Cw
Cw,,,,,,,,Cw,,,,,,,,,Cu,Cw
Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,Cw,d,Cw,Cw,Cw,Cw]]
local B = [[
CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,,Cf,Cf,,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,,Cf,Cf,,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,CF
CF,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cf,Cd,CF
CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF,CF]]
local C = [[
,,,,,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,
,,,,Msh,,,,,,,,,,,,,,
,,,,Mg,,,,,,,,,,,,,,
,,Msm,Mg,Mg,Msu,Mg,Mh(2x1),,Mg,Mh(2x1),,Mg,,,,,,
,,,,Msk,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,,]]
local STATUES = {{2, 2}, {5, 2}, {2, 5}, {5, 5}}       -- level z, under the roof holes
local WINDMILLS = {{9, 2}, {12, 2}, {9, 6}, {12, 6}}    -- centres, level z+1
local POND = {5, 2}                                     -- a roof hole, level z+1
local PRIME_WATER = 21                                  -- three buckets, in 1/7ths

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local S = reqscript('dfai-surface')

local function grid(text)
    local g, y = {}, 0
    for line in text:gmatch('[^\n]+') do
        local x = 0
        for cellv in (line .. ','):gmatch('([^,]*),') do
            if cellv ~= '' then g[#g + 1] = {x, y, cellv} end
            x = x + 1
        end
        y = y + 1
    end
    return g
end
local function write_bp()
    local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
    dfhack.filesystem.mkdir_recursive(dir)
    local statues = {}
    for y = 0, H - 1 do
        local r = {}
        for x = 0, W - 1 do
            local s = ''
            for _, st in ipairs(STATUES) do if st[1] == x and st[2] == y then s = 's' end end
            r[#r + 1] = s
        end
        statues[#statues + 1] = table.concat(r, ',')
    end
    for name, body in pairs({mist_walls = '#build label(walls) start(1;1)\n' .. A, mist_roof = '#build label(roof) start(1;1)\n' .. B,
            mist_machines = '#build label(machines) start(1;1)\n' .. C, mist_statues = '#build label(statues) start(1;1)\n' .. table.concat(statues, '\n')}) do
        local f = io.open(dir .. '/' .. name .. '.csv', 'w') f:write(body .. '\n') f:close()
    end
end
local function qf(b, name, up, verb)
    return dfhack.run_command_silent('quickfort', verb or 'run', 'dfai-gen/' .. name .. '.csv', '-c', ('%d,%d,%d'):format(b.x1, b.y1, b.z + (up and 1 or 0)))
end

local function is_construction(x, y, z)
    local a = S.attrs(x, y, z)
    return a and a.material == df.tiletype_material.CONSTRUCTION
end
local function done_building(x, y, z, btype)
    local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return bld and (not btype or bld:getType() == btype) and bld:getBuildStage() >= bld:getMaxBuildStage()
end
local function left(b, g, up)
    local n = 0
    for _, c in ipairs(g) do
        local x, y, z = b.x1 + c[1], b.y1 + c[2], b.z + (up and 1 or 0)
        if c[3] == 'd' then if not done_building(x, y, z, df.building_type.Door) then n = n + 1 end
        elseif c[3]:sub(1, 1) == 'C' then if not is_construction(x, y, z) then n = n + 1 end
        elseif not done_building(x, y, z) then n = n + 1 end
    end
    return n
end

local function windmills(b)
    local placed, built = 0, 0
    for _, w in ipairs(WINDMILLS) do
        local cx, cy, z = b.x1 + w[1], b.y1 + w[2], b.z + 1
        local bld = dfhack.buildings.findAtTile(xyz2pos(cx, cy, z))
        if bld and bld:getType() == df.building_type.Windmill then
            placed = placed + 1
            if bld:getBuildStage() >= bld:getMaxBuildStage() then built = built + 1 end
        elseif not bld then
            local floor = true
            for dx = -1, 1 do for dy = -1, 1 do if not is_construction(cx + dx, cy + dy, z) then floor = false end end end
            if floor and pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Windmill, pos = xyz2pos(cx - 1, cy - 1, z), width = 3, height = 3}) then
                placed = placed + 1
            end
        end
    end
    return placed, built
end
local function power(b)
    local cur, need = 0, 0
    for _, m in ipairs(df.global.world.machines.all) do
        local inside = false
        for _, c in ipairs(m.components) do
            local bld = df.building.find(c.building_id)
            if bld and bld.z == b.z + 1 and bld.x1 >= b.x1 and bld.x2 <= b.x2 and bld.y1 >= b.y1 and bld.y2 <= b.y2 then inside = true end
        end
        if inside then cur, need = cur + m.cur_power, need + m.min_power end
    end
    return cur, need
end
local function water_inside(b)
    local w = 0
    for z = b.z, b.z + 1 do for x = b.x1, b.x2 do for y = b.y1, b.y2 do
        local f = dfhack.maps.getTileFlags(x, y, z)
        if f and not f.liquid_type then w = w + f.flow_size end
    end end end
    return w
end
local function mist_near(b)
    local m = 0
    for _, fl in ipairs(df.global.flows) do
        if fl.type == df.flow_type.Mist and fl.density > 0 and fl.pos.x >= b.x1 - 6 and fl.pos.x <= b.x2 + 6 and fl.pos.y >= b.y1 - 6 and fl.pos.y <= b.y2 + 6 then m = m + 1 end
    end
    return m
end
local function pond_zone(b)
    local px, py, pz = b.x1 + POND[1], b.y1 + POND[2], b.z + 1
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if z.type == df.civzone_type.Pond and z.z == pz and z.x1 <= px and z.x2 >= px and z.y1 <= py and z.y2 >= py then return z end
    end
end
local function make_pond(b)
    local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
    local f = io.open(dir .. '/mist_pond.csv', 'w') f:write('#zone label(pond)\np{name="Mist Generator Priming Pond"}\n') f:close()
    dfhack.run_command_silent('quickfort', 'run', 'dfai-gen/mist_pond.csv', '-c', ('%d,%d,%d'):format(b.x1 + POND[1], b.y1 + POND[2], b.z + 1))
    local z = pond_zone(b)
    if z then z.spec_sub_flag.active = true end
end

-- the 19x11 needs flat open ground with open sky over it
-- ramps are fine (walls and the hall floor go over them), and so is a ramp
-- top under the roof; the statues need real floor
local TREE = df.tiletype_material.TREE
local function site_tile(x, y, z, lx, ly)
    local a, up = S.attrs(x, y, z), S.attrs(x, y, z + 1)
    if not a or not up then return false end
    local Sh = df.tiletype_shape
    local f = dfhack.maps.getTileFlags(x, y, z)
    -- trees in the way are felled first (trunk here, branches above)
    if a.material == TREE and not f.hidden then return up.material == TREE or up.shape == Sh.EMPTY end
    if up.material == TREE then return S.buildable(x, y, z) end
    local ground = S.buildable(x, y, z) or (a.shape == Sh.RAMP and not f.hidden and f.flow_size == 0 and not dfhack.buildings.findAtTile(xyz2pos(x, y, z)))
    if not ground then return false end
    for _, st in ipairs(STATUES) do if st[1] == lx and st[2] == ly and a.shape == Sh.RAMP then return false end end
    local fu = dfhack.maps.getTileFlags(x, y, z + 1)
    return fu.outside and (up.shape == Sh.EMPTY or up.shape == Sh.RAMP_TOP)
end
-- hilly maps rarely have a flat 19x11 by the door: look over the whole map
-- (nearest first) and a few levels up and down
function find_site() return S.find_near_gate(W, H, site_tile, {min_dist = 8, max_dist = 60, levels = {0, 1, -1, 2, -2, 3, -3}}) end

-- fell every tree in the box; true once none are left
local function clear_trees(b)
    local left = 0
    for z = b.z, b.z + 1 do for x = b.x1, b.x2 do for y = b.y1, b.y2 do
        local a = S.attrs(x, y, z)
        if a and a.material == TREE then
            left = left + 1
            if a.shape == df.tiletype_shape.WALL or a.shape == df.tiletype_shape.TRUNK_BRANCH or z == b.z then
                local des = dfhack.maps.getTileFlags(x, y, z)
                if des.dig == df.tile_dig_designation.No then
                    des.dig = df.tile_dig_designation.Default
                    dfhack.maps.getTileBlock(x, y, z).flags.designated = true
                end
            end
        end
    end end end
    return left
end

local function step(s)
    local b = s.box
    if b.phase == 'clear' then
        local n = clear_trees(b)
        if n > 0 then return ('mist generator: felling the trees on its plot, %d tree tiles left'):format(n) end
        b.phase = 'walls'
    end
    if b.phase == 'walls' then
        S.builders(true, KEY)
        local n = left(b, grid(A))
        if n > 0 then
            if (s.tries or 0) % 5 == 0 then qf(b, 'mist_walls') end
            s.tries = (s.tries or 0) + 1
            return ('mist generator: walls and doors, %d left'):format(n)
        end
        qf(b, 'mist_statues') qf(b, 'mist_roof', true) qf(b, 'mist_machines', true, 'orders')
        b.phase, s.tries = 'roof', 0
        return 'mist generator: walls done; roof, statues and machine parts ordered'
    elseif b.phase == 'roof' then
        local n = left(b, grid(B), true)
        if (s.tries or 0) % 5 == 0 then qf(b, 'mist_roof', true) qf(b, 'mist_statues') qf(b, 'mist_machines', true) end
        s.tries = (s.tries or 0) + 1
        windmills(b)
        if n > 0 then return ('mist generator: roof and parapet, %d left'):format(n) end
        b.phase, s.tries = 'machines', 0
        return 'mist generator: roof done'
    elseif b.phase == 'machines' then
        if (s.tries or 0) % 3 == 0 then qf(b, 'mist_machines', true) qf(b, 'mist_statues') end
        s.tries = (s.tries or 0) + 1
        local n = left(b, grid(C), true)
        local placed, built = windmills(b)
        if n > 0 or built < #WINDMILLS then
            return ('mist generator: machines, %d parts left, windmills %d placed %d built'):format(n, placed, built)
        end
        b.phase = 'ready'
        S.builders(false, KEY)
        return 'mist generator: built'
    elseif b.phase == 'ready' then
        local cur, need = power(b)
        if cur > 0 and cur >= need then b.phase = 'priming' return 'mist generator: windmills turning, priming' end
        return ('mist generator: built, waiting for wind (power %d of %d)'):format(cur, need)
    elseif b.phase == 'priming' then
        local w = water_inside(b)
        if w >= PRIME_WATER or (w >= 7 and mist_near(b) > 0) then
            local z = pond_zone(b)
            if z then dfhack.buildings.deconstruct(z) end
            b.phase = 'running'
            dfhack.gui.showAnnouncement('The mist generator is running.', COLOR_LIGHTCYAN, true)
            return ('mist generator: primed with %d/7 of water, running on its own'):format(w)
        end
        if not pond_zone(b) then make_pond(b) end
        return ('mist generator: priming, %d/7 of water in, the pond is open'):format(w)
    elseif b.phase == 'running' then
        -- a leak or evaporation: prime again
        local w = water_inside(b)
        if w < 3 then b.phase = 'priming' end
        return ('mist generator: running, %d/7 water, %d mist clouds'):format(w, mist_near(b))
    end
    return 'mist generator: ' .. tostring(b.phase)
end

local function plan(s)
    local b, why = find_site()
    if not b then s.last = 'mist generator: ' .. tostring(why) return false end
    b.phase = 'clear'
    s.box, s.tries = b, 0
    write_bp()
    pcall(function() reqscript('dfai-projects').add('mist', 'The Mist Generator', b.x1, b.y1, b.z, b.x2, b.y2, b.z + 1, true) end)
    s.last = ('mist generator planned at %d,%d level %d'):format(b.x1, b.y1, b.z)
    return true
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        if not s.box then
            if #dfhack.units.getCitizens(true) < 20 then s.last = 'mist generator: waits for 20 citizens' return end
            local okp, pri = pcall(reqscript, 'dfai-priorities')
            if okp then
                local go, why = pri.allowed('mist')
                if not go then s.last = 'mist generator: on hold, ' .. tostring(why) return end
                if pri.no_water() then s.last = 'mist generator: waits, there is no water on the map to prime it with' return end
            end
            if not plan(s) then return end
        end
        write_bp()
        dfhack.run_command_silent('unsuspend')
        s.last = step(s)
        if s.box.phase == 'running' then pcall(function() reqscript('dfai-projects').done('mist') end) end
    end)
    if not ok then s.last = 'mist generator error: ' .. tostring(err) end
    save(s)
end

function status() return load().last or 'mist generator: idle' end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    print('mist generator: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('mist generator: queued')
elseif cmd == 'find' then
    local b, why = find_site()
    if not b then print('no site: ' .. tostring(why)) return end
    print(('site %d,%d..%d,%d level %d'):format(b.x1, b.y1, b.x2, b.y2, b.z))
    write_bp()
    for _, l in ipairs({{'mist_walls'}, {'mist_statues'}, {'mist_roof', true}, {'mist_machines', true}}) do
        local out = dfhack.run_command_silent('quickfort', 'run', 'dfai-gen/' .. l[1] .. '.csv', '-c', ('%d,%d,%d'):format(b.x1, b.y1, b.z + (l[2] and 1 or 0)), '--dry-run')
        print(l[1] .. ': ' .. out:gsub('%s+', ' '))
    end
else
    print(status())
end
