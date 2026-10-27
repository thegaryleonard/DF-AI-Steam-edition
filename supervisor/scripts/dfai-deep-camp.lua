-- The Deep Camp: a tavern, dormitory, still and stores beside the deep cavern
-- (user request: a cavern tavern, with what the deep crew needs so they don't
-- walk 130 levels up for a drink). Built from blueprints/dfai-deep-camp.csv
-- in two phases: dig the rock, then the furniture, stockpiles and zones.
--@module = true
--[====[
dfai-deep-camp
==============
    dfai-deep-camp start    -- check daily (onMapLoad.init)
    dfai-deep-camp now      -- check on the next game tick
    dfai-deep-camp status
]====]

local repeatUtil = require('repeat-util')
local KEY = 'dfai-deep-camp'
local BP = 'dfai-deep-camp.csv'
local X, Y, Z, W, H = 178, 147, 38, 10, 11   -- the block; the tunnel is (188..189, 150)
local SITE = 350                               -- Showerwheels only: the coordinates are this map's

local function load() return dfhack.persistent.getSiteData(KEY, {phase = 'new'}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

local function project(fn, ...)
    local args = {...}
    pcall(function() reqscript('dfai-projects')[fn](table.unpack(args)) end)
end

local function qf(label)
    local out = dfhack.run_command_silent('quickfort', 'run', BP, '-n', '/' .. label, '-c', ('%d,%d,%d'):format(X, Y, Z))
    return out
end

local function each_tile(fn)
    for y = Y, Y + H - 1 do for x = X, X + W - 1 do fn(x, y, Z) end end
    fn(X + W, Y + 3, Z); fn(X + W + 1, Y + 3, Z)
end

local function undug()
    local n = 0
    each_tile(function(x, y, z)
        local tt = dfhack.maps.getTileType(x, y, z)
        if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.WALL then n = n + 1 end
    end)
    return n
end

-- top dig priority: the camp is 130 levels below the fort and miners take the nearest job
local function prioritize()
    each_tile(function(x, y, z)
        local f, b = dfhack.maps.getTileFlags(x, y, z), dfhack.maps.getTileBlock(x, y, z)
        if f and b and f.dig ~= df.tile_dig_designation.No then
            local ev
            for _, v in ipairs(b.block_events) do
                if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
            end
            if not ev then
                b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
                ev = b.block_events[#b.block_events - 1]
            end
            ev.priority[x % 16][y % 16] = 1000
            b.flags.designated = true
        end
    end)
end

local function danger()
    -- never next to liquid (a magma lake lies a few tiles west of the camp)
    for y = Y - 1, Y + H do for x = X - 1, X + W + 2 do
        local f = dfhack.maps.getTileFlags(x, y, Z)
        if f and f.flow_size > 0 then return ('liquid at %d,%d,%d'):format(x, y, Z) end
    end end
end

local function built_count()
    local n = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        if b.z == Z and b.x1 >= X and b.x2 <= X + W - 1 and b.y1 >= Y and b.y2 <= Y + H - 1 then
            local t = b:getType()
            if (t == df.building_type.Table or t == df.building_type.Chair or t == df.building_type.Bed or t == df.building_type.Workshop)
                and b:getBuildStage() >= b:getMaxBuildStage() then n = n + 1 end
        end
    end
    return n
end
local FURNITURE = 17 -- 4 tables, 8 chairs, 4 beds, 1 still

function step()
    local s = load()
    local site = dfhack.world.getCurrentSite()
    if not site or site.id ~= SITE then return 'not this fort' end
    if s.phase == 'new' then
        local why = danger()
        if why then s.why = why; save(s) return 'not safe: ' .. why end
        qf('dig')
        prioritize()
        project('add', 'deepcamp', 'The Deep Tavern', X, Y, Z, X + W + 1, Y + H - 1, Z, true)
        s.phase, s.started = 'dig', os.time()
        save(s)
        return 'designated the dig'
    elseif s.phase == 'dig' then
        local n = undug()
        if n > 0 then prioritize() return ('digging: %d tiles left'):format(n) end
        -- the mist generator comes before cavern work (user rule): the masons
        -- and haulers furnish the camp only once it is built
        local mp = dfhack.persistent.getSiteData('dfai-mist-build', {}).phase
        if mp and mp ~= 'ready' then return 'dug out; furnishing waits for the mist generator (' .. mp .. ')' end
        qf('build'); qf('place'); qf('zone'); qf('dining')
        s.phase = 'build'
        save(s)
        return 'dug out: furniture, still, stockpiles and zones designated'
    elseif s.phase == 'build' then
        local n = built_count()
        if n < FURNITURE then
            -- re-run the build sheet now and then (an item shortage cancels jobs)
            if (s.checks or 0) % 5 == 4 then qf('build') end
            s.checks = (s.checks or 0) + 1
            save(s)
            return ('furnishing: %d of %d pieces in'):format(n, FURNITURE)
        end
        s.phase = 'done'
        save(s)
        project('done', 'deepcamp')
        return 'done'
    end
    return s.phase
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_deep_camp_last = ok and res or ('error: ' .. tostring(res))
end

if dfhack_flags.module then return end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick) -- daily
    print('deep camp: started')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('deep camp: queued for the next game tick')
else
    local s = load()
    print(('deep camp: %s; last: %s'):format(s.phase, tostring(rawget(_G, 'dfai_deep_camp_last'))))
end
