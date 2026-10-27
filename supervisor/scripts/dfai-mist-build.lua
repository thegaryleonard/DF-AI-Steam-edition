-- The walled entrance + mist generator for Showerwheels (user's design from the
-- last fort, mirrored: entrance room west, mist chamber east, one roof over
-- both with a fortification parapet, 4 windmills and the 4-pump ring on it).
-- Replays dfhack-config/blueprints/dfai-mist/*.csv with quickfort --transform
-- fliph (pump directions mirror correctly) in stages, one check a game day.
--@module = true
--[====[
dfai-mist-build
===============
    dfai-mist-build start | now | status
]====]

local repeatUtil = require('repeat-util')
local KEY = 'dfai-mist-build'
local SITE = 350
local CUR = '35,116,174'     -- the box's top-right corner (fliph mirrors west of it)
local CUR_UP = '35,116,175'
local X1, Y1, X2, Y2, Z = 17, 116, 35, 126, 174
local WINDMILLS = {{26, 118}, {23, 118}, {26, 122}, {23, 122}}   -- centres, z175
local OPEN_DOORWAY = {[17 * 1000 + 121] = true}                     -- ramp top: no door

local function load() return dfhack.persistent.getSiteData(KEY, {phase = 'A'}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function cells()
    local ok, d = pcall(require('json').decode_file, dfhack.getDFPath() .. '/dfhack-config/dfai-mist-cells.json')
    return ok and d or nil
end
local function qf(file, cur, verb)
    return dfhack.run_command_silent('quickfort', verb or 'run', 'dfai-mist/' .. file, '-c', cur, '-t', 'fliph')
end
local function project(fn, ...)
    local a = {...}
    pcall(function() reqscript('dfai-projects')[fn](table.unpack(a)) end)
end

local function is_construction(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].material == df.tiletype_material.CONSTRUCTION
end
local function done_building(x, y, z, btype)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return b and (not btype or b:getType() == btype) and b:getBuildStage() >= b:getMaxBuildStage()
end

-- how many cells of a stage still need building
local function left_A(d)
    local n = 0
    for _, c in ipairs(d.A) do
        local x, y, z, k = c[1], c[2], c[3], c[4]
        if OPEN_DOORWAY[x * 1000 + y] then
        elseif k == 'd' then if not done_building(x, y, z, df.building_type.Door) then n = n + 1 end
        elseif not is_construction(x, y, z) then n = n + 1 end
    end
    return n
end
local function left_B(d)
    local n = 0
    for _, c in ipairs(d.B) do
        if not is_construction(c[1], c[2], c[3]) then n = n + 1 end
    end
    return n
end
local function left_C(d)
    local n = 0
    for _, c in ipairs(d.C) do
        if c[4] ~= 'Mm' and not done_building(c[1], c[2], c[3]) then n = n + 1 end
    end
    return n
end

local function windmills()
    local placed, built = 0, 0
    for _, w in ipairs(WINDMILLS) do
        local cx, cy, z = w[1], w[2], 175
        local b = dfhack.buildings.findAtTile(xyz2pos(cx, cy, z))
        if b and b:getType() == df.building_type.Windmill then
            placed = placed + 1
            if b:getBuildStage() >= b:getMaxBuildStage() then built = built + 1 end
        elseif not b then
            local floor = true
            for dx = -1, 1 do for dy = -1, 1 do
                if not is_construction(cx + dx, cy + dy, z) then floor = false end
            end end
            if floor then
                local ok = pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Windmill,
                    pos = xyz2pos(cx - 1, cy - 1, z), width = 3, height = 3})
                if ok then placed = placed + 1 end
            end
        end
    end
    return placed, built
end

local function power()
    local cur, need = 0, 0
    for _, m in ipairs(df.global.world.machines.all) do
        local in_box = false
        for _, c in ipairs(m.components) do
            local b = df.building.find(c.building_id)
            if b and b.z == 175 and b.x1 >= X1 and b.x2 <= X2 and b.y1 >= Y1 and b.y2 <= Y2 then in_box = true end
        end
        if in_box then cur, need = cur + m.cur_power, need + m.min_power end
    end
    return cur, need
end

function step()
    local site = dfhack.world.getCurrentSite()
    if not site or site.id ~= SITE then return 'not this fort' end
    local d = cells()
    if not d then return 'no cell list' end
    local s = load()
    dfhack.run_command_silent('unsuspend')
    if s.phase == 'A' then
        if not s.project then
            project('add', 'mist', 'The Walled Entrance And Mist Generator', X1, Y1, Z, X2, Y2, Z + 1, true)
            s.project = true
        end
        local n = left_A(d)
        if n > 0 then
            qf('A_z177_walls.csv', CUR)
            save(s)
            return ('walls and doors: %d cells left'):format(n)
        end
        qf('D_z177_statues.csv', CUR)
        qf('B_z178_roof.csv', CUR_UP)
        qf('C_z178_machines.csv', CUR_UP, 'orders') -- parts made while the roof goes up
        s.phase = 'B'
        save(s)
        return 'walls done: roof, parapet and statues designated, machine parts ordered'
    elseif s.phase == 'B' then
        local n = left_B(d)
        if n > 0 then
            qf('B_z178_roof.csv', CUR_UP)
            qf('D_z177_statues.csv', CUR)
            -- the machines only place on finished floor: try them as sections complete
            qf('C_z178_machines.csv', CUR_UP)
            windmills()
            return ('roof and parapet: %d cells left'):format(n)
        end
        s.phase = 'C'
        save(s)
        return 'roof done'
    elseif s.phase == 'C' then
        qf('C_z178_machines.csv', CUR_UP)
        qf('D_z177_statues.csv', CUR)
        local n = left_C(d)
        local placed, built = windmills()
        if n > 0 or built < #WINDMILLS then
            return ('machines: %d parts left, windmills %d placed, %d built'):format(n, placed, built)
        end
        local cur, need = power()
        s.phase = 'ready'
        s.power = {cur, need}
        save(s)
        return ('built: power %d of %d needed; ready to prime'):format(cur, need)
    elseif s.phase == 'ready' then
        local cur, need = power()
        return ('ready to prime: power %d / %d'):format(cur, need)
    end
    return s.phase
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_mist_last = ok and res or ('error: ' .. tostring(res))
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick) -- twice a game day
    print('mist build: started')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('mist build: queued for the next game tick')
else
    print(('mist build: %s; last: %s'):format(load().phase, tostring(rawget(_G, 'dfai_mist_last'))))
end
