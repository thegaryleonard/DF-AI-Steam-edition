-- dfai-cavern-ore: mine the ore showing in the caverns' walls (user: "theres
-- all sorts of ore in the caverns too"). Once a game day it looks through the
-- cavern blocks for metal-ore vein tiles that are exposed (next to open,
-- seen, reachable cavern floor), and marks them for mining; as each is dug the
-- next tile of the vein is exposed and marked on the following pass, so veins
-- get followed into the rock. No tile next to water or magma is marked.
-- The scan runs a few dozen blocks per tick so the game never stalls.
--   dfai-cavern-ore start | stop | now | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-cavern-ore'
local PER_TICK = 40

local function load() return dfhack.persistent.getSiteData(KEY, {marked = {}, total = 0}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local inorg = df.global.world.raws.inorganics.all
local function is_ore(i)
    local r = inorg[i]
    return r and #r.metal_ore.mat_index > 0
end
local function shape(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape
end
local function walkable(sh)
    return sh == df.tiletype_shape.FLOOR or sh == df.tiletype_shape.RAMP or sh == df.tiletype_shape.STAIR_UP
        or sh == df.tiletype_shape.STAIR_DOWN or sh == df.tiletype_shape.STAIR_UPDOWN or sh == df.tiletype_shape.BOULDER
        or sh == df.tiletype_shape.PEBBLES or sh == df.tiletype_shape.SAPLING or sh == df.tiletype_shape.SHRUB
end
local function wet(x, y, z)
    for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
        local f = dfhack.maps.getTileFlags(x + dx, y + dy, z + dz)
        if f and (f.flow_size > 0 or f.water_table) then return true end
    end end end
end
local function designate(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    f.dig = df.tile_dig_designation.Default
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = 3000
    b.flags.designated = true
end

-- beasts: no ore is worth a miner. A forgotten beast (titan, demon...) that's
-- been seen keeps ore mining 15 tiles and 5 levels away from it; marks already
-- made there are taken back (a beast by the deep shaft picked off the miners
-- the ore marks had sent past it).
local BEAST_R, BEAST_Z = 15, 5
local function beasts()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if (dfhack.units.isForgottenBeast(u) or dfhack.units.isMegabeast(u) or dfhack.units.isSemiMegabeast(u) or dfhack.units.isTitan(u)
            or dfhack.units.isDemon(u)) and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.caged
            and not dfhack.maps.getTileFlags(u.pos).hidden then
            out[#out + 1] = {pos = copyall(u.pos), name = dfhack.df2utf(dfhack.units.getReadableName(u)):gsub(',.*$', '')}
        end
    end
    return out
end
local function near_beast(B, x, y, z)
    for _, b in ipairs(B) do
        if math.abs(b.pos.z - z) <= BEAST_Z and math.abs(b.pos.x - x) <= BEAST_R and math.abs(b.pos.y - y) <= BEAST_R then return b end
    end
end
local function our_priority(x, y, z)
    local blk = dfhack.maps.getTileBlock(x, y, z)
    for _, e in ipairs(blk and blk.block_events or {}) do
        if e:getType() == df.block_square_event_type.designation_priority then return e.priority[x % 16][y % 16] == 3000 end
    end
end
-- take back our marks (and their dig jobs) near a beast
local function clear_near(B)
    if #B == 0 then return 0 end
    local n, kill = 0, {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.Dig and near_beast(B, j.pos.x, j.pos.y, j.pos.z) and our_priority(j.pos.x, j.pos.y, j.pos.z) then kill[#kill + 1] = j end
        l = l.next
    end
    for _, j in ipairs(kill) do
        local p = copyall(j.pos)
        dfhack.job.removeJob(j)
        local f = dfhack.maps.getTileFlags(p.x, p.y, p.z)
        if f then f.dig = df.tile_dig_designation.No end
        n = n + 1
    end
    -- marks not yet turned into jobs
    for _, b in ipairs(B) do
        for z = b.pos.z - BEAST_Z, b.pos.z + BEAST_Z do
            for x = b.pos.x - BEAST_R, b.pos.x + BEAST_R do for y = b.pos.y - BEAST_R, b.pos.y + BEAST_R do
                local f = dfhack.maps.getTileFlags(x, y, z)
                if f and f.dig == df.tile_dig_designation.Default and our_priority(x, y, z) then f.dig = df.tile_dig_designation.No n = n + 1 end
            end end
        end
    end
    return n
end

local scan = {busy = false}
local function finish(s, found)
    s.last_pass = os.time()
    local parts = {}
    for id, n in pairs(found) do parts[#parts + 1] = ('%s %d'):format(id:lower():gsub('_', ' '), n) end
    s.last = #parts > 0 and ('marked ' .. table.concat(parts, ', ')) or 'no newly exposed ore this pass'
    save(s)
    scan.busy = false
end

local function pass()
    if scan.busy or df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local okp_, pri_ = pcall(reqscript, 'dfai-priorities')
    if okp_ then
        local go_, why_ = pri_.allowed('mining')
        if not go_ then local s0 = load() s0.last = 'on hold: ' .. tostring(why_) save(s0) return end
    end
    scan.busy = true
    local s = load()
    local cit = dfhack.units.getCitizens(true)[1]
    -- the cavern blocks (DF marks them with a local feature), one level per tick
    local m = df.global.world.map
    local blocks, found, i, z = {}, {}, 0, 0
    local B = beasts()
    local took = clear_near(B)
    s.beast = #B > 0 and ('%s nearby: no ore mining within %d tiles of it%s'):format(B[1].name, BEAST_R,
        took > 0 and (' (took back %d marks)'):format(took) or '') or nil
    -- a marked tile turns into a Dig job and its flag clears: skip those
    local jobs = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.Dig then jobs[(j.pos.z * 1000 + j.pos.x) * 1000 + j.pos.y] = true end
        l = l.next
    end
    local chunk
    local function gather()
        for bx = 0, m.x_count_block - 1 do for by = 0, m.y_count_block - 1 do
            local b = dfhack.maps.getTileBlock(bx * 16, by * 16, z)
            if b and b.local_feature ~= -1 then blocks[#blocks + 1] = {bx * 16, by * 16, z} end
        end end
        z = z + 1
        if z < m.z_count then dfhack.timeout(1, 'ticks', gather) else dfhack.timeout(1, 'ticks', chunk) end
    end
    function chunk()
        local ok, err = pcall(function()
            for _ = 1, PER_TICK do
                i = i + 1
                local bp = blocks[i]
                if not bp then return end
                local b = dfhack.maps.getTileBlock(bp[1], bp[2], bp[3])
                for _, e in ipairs(b.block_events) do
                    if df.block_square_event_mineralst:is_instance(e) and is_ore(e.inorganic_mat) then
                        for y = 0, 15 do
                            local row = e.tile_bitmask.bits[y]
                            if row ~= 0 then
                                for x = 0, 15 do
                                    if row & (1 << x) ~= 0 and b.designation[x][y].dig == df.tile_dig_designation.No
                                        and not jobs[(bp[3] * 1000 + bp[1] + x) * 1000 + bp[2] + y]
                                        and shape(bp[1] + x, bp[2] + y, bp[3]) == df.tiletype_shape.WALL
                                        and not near_beast(B, bp[1] + x, bp[2] + y, bp[3]) then
                                        local X, Y, Z = bp[1] + x, bp[2] + y, bp[3]
                                        -- exposed: a seen, walkable, reachable neighbour
                                        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                                            local nf = dfhack.maps.getTileFlags(X + d[1], Y + d[2], Z)
                                            if nf and not nf.hidden and walkable(shape(X + d[1], Y + d[2], Z))
                                                and (not cit or dfhack.maps.canWalkBetween(cit.pos, xyz2pos(X + d[1], Y + d[2], Z))) then
                                                if not wet(X, Y, Z) then
                                                    designate(X, Y, Z)
                                                    local id = inorg[e.inorganic_mat].id
                                                    found[id] = (found[id] or 0) + 1
                                                    s.marked[id] = (s.marked[id] or 0) + 1
                                                    s.total = (s.total or 0) + 1
                                                end
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
        if not ok then s.last = 'error: ' .. tostring(err) save(s) scan.busy = false return end
        if i < #blocks then dfhack.timeout(1, 'ticks', chunk) else finish(s, found) end
    end
    dfhack.timeout(1, 'ticks', gather)
end

function status()
    local s = load()
    local parts = {}
    for id, n in pairs(s.marked or {}) do parts[#parts + 1] = ('%s %d'):format(id:lower():gsub('_', ' '), n) end
    table.sort(parts)
    return ('cavern ore: %s%s%s; %d tiles marked so far%s'):format(repeatUtil.isScheduled and repeatUtil.isScheduled(KEY) and 'watching' or (s.on and 'on' or 'off'),
        s.last and ('; last pass: ' .. s.last) or '', s.beast and ('; ' .. s.beast) or '', s.total or 0, #parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1]
if cmd == 'start' then
    local s = load() s.on = true save(s)
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', pass)   -- a game day
    pass()
    print('cavern ore: watching the cavern walls')
elseif cmd == 'resume' then
    if load().on then repeatUtil.scheduleEvery(KEY, 1200, 'ticks', pass) end
elseif cmd == 'stop' then
    local s = load() s.on = false save(s)
    repeatUtil.cancel(KEY)
    print('cavern ore: stopped (what is marked stays marked)')
elseif cmd == 'now' then
    pass()
    print('cavern ore: a pass is running')
else
    print(status())
end
