-- Ore scrub (user: overseer order "dig X levels down and scrub for ore").
--
--   dfai-ore-scrub start <levels> [x y z]   shaft down from a reachable floor
--   dfai-ore-scrub stop
--   dfai-ore-scrub                          status (and ore found so far)
--
-- A staircase goes down <levels> levels; on every level four galleries run
-- ARM tiles north, south, east and west. Whenever ore shows in a gallery wall,
-- the whole vein is marked for mining (like DFHack's digv). Every tile is
-- checked before it is marked: nothing next to water, magma, an aquifer, open
-- space or a cavern is ever dug, so the scrub can't flood the fort or open a
-- cavern. Without x y z it picks the reachable floor (near the fort's mining
-- shaft) with the most ore below it, the way a prospector would.
--@ module = true

local repeatUtil = require('repeat-util')
local tm = require('tile-material')
local KEY = 'dfai-ore-scrub'
local ARM = 12
local MAX_VEIN = 400          -- tiles per vein, a sanity cap
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'
local SEARCH = {30, 78, 68, 116, 159}   -- x1 y1 x2 y2 z of the default start search

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function notify(msg)
    local f = io.open(NOTIFY, 'a')
    if f then f:write(msg .. '\n') f:close() end
end

local function attrs(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt]
end
local function is_wall(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == df.tiletype_shape.WALL
end
local function ore_of(x, y, z)
    local m = tm.GetTileMat(x, y, z)
    if m and m.inorganic and #m.inorganic.metal_ore.mat_index > 0 then return m.inorganic.id end
end

-- safe to dig: a solid wall with nothing wet, open, outside or cavern around it
local function safe(x, y, z)
    if not dfhack.maps.isValidTilePos(x, y, z) or not is_wall(x, y, z) then return false end
    for dz = -1, 1 do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local f = dfhack.maps.getTileFlags(x + dx, y + dy, z + dz)
                if not f then return false end
                if f.flow_size > 0 or f.water_table or f.outside then return false end
                if f.feature_global or f.feature_local then return false end   -- caverns, magma sea
                local a = attrs(x + dx, y + dy, z + dz)
                if a and dz ~= 0 and a.shape == df.tiletype_shape.EMPTY and f.hidden then return false end
            end
        end
    end
    return true
end

local function designate(x, y, z, kind)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    f.dig = df.tile_dig_designation[kind]
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = 3000   -- after the fort's own urgent digging
    b.flags.designated = true
end

-- the reachable floor in SEARCH with the most ore in the levels below it
local function pick_start(levels)
    local c = dfhack.units.getCitizens(true)[1]
    local best, bs
    local x1, y1, x2, y2, z = table.unpack(SEARCH)
    for x = x1, x2, 3 do
        for y = y1, y2, 3 do
            local a = attrs(x, y, z)
            local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
            if bld and (df.building_stockpilest:is_instance(bld) or df.building_civzonest:is_instance(bld)) then bld = nil end
            if a and a.shape == df.tiletype_shape.FLOOR and not bld
                and c and dfhack.maps.canWalkBetween(c.pos, xyz2pos(x, y, z)) then
                local ok = true
                for d = 1, levels do if not safe(x, y, z - d) then ok = false break end end
                if ok then
                    local score = 0
                    for d = 1, levels do
                        for i = -ARM, ARM, 2 do
                            if ore_of(x + i, y, z - d) then score = score + 1 end
                            if ore_of(x, y + i, z - d) then score = score + 1 end
                        end
                    end
                    if not best or score > bs then best, bs = {x, y, z}, score end
                end
            end
        end
    end
    return best, bs
end

local function plan(s)
    local x, y, z = s.x, s.y, s.z
    local n = 0
    designate(x, y, z, 'DownStair')   -- the floor tile becomes the top of the stairs
    for d = 1, s.levels do
        local zz = z - d
        if not safe(x, y, zz) then s.levels = d - 1 break end
        designate(x, y, zz, d == s.levels and 'UpStair' or 'UpDownStair')
        n = n + 1
        for _, dir in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            for i = 1, ARM do
                local gx, gy = x + dir[1] * i, y + dir[2] * i
                if not safe(gx, gy, zz) then break end
                designate(gx, gy, zz, 'Default')
                n = n + 1
            end
        end
    end
    return n
end

-- ore showing in any wall next to a dug gallery tile: mark its vein
local function scrub(s)
    local found = 0
    s.ore = s.ore or {}
    s.veins = s.veins or {}
    for d = 1, s.levels do
        local zz = s.z - d
        for _, dir in ipairs({{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            for i = (dir[1] == 0 and dir[2] == 0) and 0 or 1, (dir[1] == 0 and dir[2] == 0) and 0 or ARM do
                local gx, gy = s.x + dir[1] * i, s.y + dir[2] * i
                if not is_wall(gx, gy, zz) then
                    for _, nb in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                        local ox, oy = gx + nb[1], gy + nb[2]
                        local f = dfhack.maps.getTileFlags(ox, oy, zz)
                        local ore = f and not f.hidden and is_wall(ox, oy, zz) and f.dig == df.tile_dig_designation.No and ore_of(ox, oy, zz)
                        local key = ('%d,%d,%d'):format(ox, oy, zz)
                        if ore and not s.veins[key] then
                            -- flood the vein (same ore, 3D, safe tiles only)
                            local seen, stack, n = {[key] = true}, {{ox, oy, zz}}, 0
                            while #stack > 0 and n < MAX_VEIN do
                                local p = table.remove(stack)
                                if safe(p[1], p[2], p[3]) and ore_of(p[1], p[2], p[3]) == ore then
                                    designate(p[1], p[2], p[3], 'Default')
                                    n = n + 1
                                    for _, q in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) do
                                        local k2 = ('%d,%d,%d'):format(p[1] + q[1], p[2] + q[2], p[3] + q[3])
                                        if not seen[k2] then seen[k2] = true stack[#stack + 1] = {p[1] + q[1], p[2] + q[2], p[3] + q[3]} end
                                    end
                                end
                            end
                            s.veins[key] = ore
                            s.ore[ore] = (s.ore[ore] or 0) + n
                            found = found + n
                        end
                    end
                end
            end
        end
    end
    return found
end

local function pretty(id) return (id:lower():gsub('_', ' ')) end
local function ore_text(s)
    local t = {}
    for k, v in pairs(s.ore or {}) do t[#t + 1] = {k, v} end
    table.sort(t, function(a, b) return a[2] > b[2] end)
    local out = {}
    for _, e in ipairs(t) do out[#out + 1] = ('%s %d'):format(pretty(e[1]), e[2]) end
    return #out > 0 and table.concat(out, ', ') or 'none yet'
end

local function remaining(s)
    local left = 0
    for d = 0, s.levels do
        local zz = s.z - d
        for i = -ARM, ARM do
            for _, p in ipairs({{s.x + i, s.y}, {s.x, s.y + i}}) do
                local f = dfhack.maps.getTileFlags(p[1], p[2], zz)
                if f and f.dig ~= df.tile_dig_designation.No then left = left + 1 end
            end
        end
    end
    return left
end

local function tick()
    local s = load()
    if not s.active then return end
    local okp_, pri_ = pcall(reqscript, 'dfai-priorities')
    if okp_ then
        local go_, why_ = pri_.allowed('mining')
        if not go_ then return end
    end
    local new = scrub(s)
    if new > 0 then print(('[ore scrub] %d more ore tiles marked'):format(new)) end
    local left = remaining(s)
    s.left = left
    if left == 0 then
        s.quiet = (s.quiet or 0) + 1
        if s.quiet >= 3 then   -- three quiet checks: galleries done, last veins marked
            s.active = false
            notify(('**Ore scrub done:** %d levels down from (%d,%d,%d). Veins marked for mining: %s.'):format(s.levels, s.x, s.y, s.z, ore_text(s)))
            pcall(function() reqscript('dfai-projects').done('orescrub') end)
        end
    else
        s.quiet = 0
    end
    save(s)
end

function status()
    local s = load()
    if not s.x then return 'no scrub yet' end
    return ('%s: %d levels from %d,%d,%d, %d gallery tiles left; ore marked: %s')
        :format(s.active and 'scrubbing' or 'done', s.levels, s.x, s.y, s.z, s.left or 0, ore_text(s))
end

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local cmd = args[1] or 'status'
if cmd == 'start' then
    local levels = math.max(1, math.min(20, tonumber(args[2]) or 10))
    local px, py, pz = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    dfhack.timeout(1, 'ticks', function()
        local s = load()
        if s.active then _G.dfai_ore_last = 'already scrubbing: ' .. status() return end
        local start, score = px and {px, py, pz}, nil
        if not start then start, score = pick_start(levels) end
        if not start then _G.dfai_ore_last = 'no safe spot found for a shaft' return end
        s = {active = true, x = start[1], y = start[2], z = start[3], levels = levels, ore = {}, veins = {}}
        local n = plan(s)
        save(s)
        pcall(function()
            local m = reqscript('dfai-projects')
            m.add('orescrub', 'Scrubbing For Ore', s.x - ARM, s.y - ARM, s.z - s.levels, s.x + ARM, s.y + ARM, s.z, true)
        end)
        _G.dfai_ore_last = ('scrub planned at %d,%d,%d: %d levels, %d tiles to dig%s')
            :format(s.x, s.y, s.z, s.levels, n, score and (' (prospect score ' .. score .. ')') or '')
        print('[ore scrub] ' .. _G.dfai_ore_last)
    end)
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    print(('ore scrub: %d levels, planning on the next tick'):format(levels))
elseif cmd == 'resume' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    print('ore scrub watch: ' .. status())
elseif cmd == 'stop' then
    dfhack.timeout(1, 'ticks', function() local s = load() s.active = false save(s) end)
    print('ore scrub: stopped (designations already made stay)')
else
    print('ore scrub: ' .. status() .. (rawget(_G, 'dfai_ore_last') and ('\nlast: ' .. _G.dfai_ore_last) or ''))
end
