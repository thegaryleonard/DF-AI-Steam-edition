-- dfai-wellshaft: water for a fort whose water lies below it.
--
-- A cistern only fills by gravity (df-ai taps water at or above it). Most
-- forts' water is a lake or cavern below the halls (Topcloister: a lake 11
-- levels under its cistern). A well needs only an open column down to water,
-- so dig one:
--
--   fort level   . T S .     T  the well (built over the open shaft)
--                # C S #     S  a stair down beside the shaft, for the diggers
--                # C S #     C  the shaft: channelled out level by level
--                # C S #        from the stair
--   lake air       ~           shaft breaks through the ceiling over the water
--   water        ~ ~ ~ ~
--
-- Then the stairhead is walled up (nothing climbs up from the lake) and the
-- well goes on. Only when the fort has no well that reaches water. Every
-- tile of the shaft and stair has solid rock all round, so it opens into
-- nothing but the air over the lake. Shallow lakes (open space 1-4 levels
-- under the floor) are dfai-fort-health's job: it builds the well directly.
--   dfai-wellshaft start | status | find (dry run) | now
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-wellshaft'
local SURF = reqscript('dfai-surface')

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end
local Sh, Mat = df.tiletype_shape, df.tiletype_material
scanning = scanning or false   -- a search is running (module global: survives reloads of the loop)

local function rock(x, y, z)
    local a = attrs(x, y, z)
    if not a or a.shape ~= Sh.WALL then return false end
    if a.material ~= Mat.STONE and a.material ~= Mat.MINERAL and a.material ~= Mat.SOIL then return false end
    local f = dfhack.maps.getTileFlags(x, y, z)
    return f and not f.water_table
end
local function open_air(x, y, z)
    local a = attrs(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    return a and f and a.shape == Sh.EMPTY and f.flow_size == 0
end
local function water(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    return f and f.flow_size >= 4 and not f.liquid_type
end
local function fort_floor(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == Sh.FLOOR and SURF.walkable(x, y, z) and not dfhack.buildings.findAtTile(xyz2pos(x, y, z))
end

-- does any well already reach water?
local function working_well()
    for _, b in ipairs(df.global.world.buildings.other.WELL) do
        if b:getBuildStage() >= b:getMaxBuildStage() then
            for z = b.z, math.max(0, b.z - 80), -1 do
                local f = dfhack.maps.getTileFlags(b.x1, b.y1, z)
                if not f then break end
                if f.flow_size >= 1 and not f.liquid_type then return b end
                local a = attrs(b.x1, b.y1, z)
                if z < b.z and not (a and (a.shape == Sh.EMPTY or a.shape == Sh.RAMP_TOP)) then break end
            end
        end
    end
end

local D4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

WELL_FILTERS = {
    {flags2 = {building_material = true, non_economic = true}},
    {flags2 = {lye_milk_free = true}, item_type = df.item_type.BUCKET, vector_id = df.job_item_vector_id.BUCKET},
    {item_type = df.item_type.CHAIN, vector_id = df.job_item_vector_id.CHAIN},
    {item_type = df.item_type.TRAPPARTS, vector_id = df.job_item_vector_id.TRAPPARTS},
}

-- all tiles round the shaft and stair, level by level, are rock
local function sealed(cx, cy, sx, sy, zlo, zhi)
    for z = zlo, zhi do
        for x = math.min(cx, sx) - 1, math.max(cx, sx) + 1 do
            for y = math.min(cy, sy) - 1, math.max(cy, sy) + 1 do
                if not ((x == cx and y == cy) or (x == sx and y == sy)) and not rock(x, y, z) then return false end
            end
        end
        if not rock(cx, cy, z) or not rock(sx, sy, z) then return false end
    end
    return true
end

-- a site: T (well, fort floor) over rock over open air over real water
-- the search box round the entrance
local function box()
    local cit = dfhack.units.getCitizens(true)[1]
    if not cit then return nil end
    local e = SURF.entrance() or cit.pos
    local mx, my = dfhack.maps.getTileSize()
    return {e = {x = e.x, y = e.y, z = e.z}, x1 = math.max(2, e.x - 50), x2 = math.min(mx - 3, e.x + 50)}
end

-- scan columns x1..x2 (all of them if not given), keeping the best in `best`
function find_site(xa, xb, best)
    local bx = box()
    if not bx then return nil, 'no citizens' end
    local e = bx.e
    local mx, my = dfhack.maps.getTileSize()
    for x = xa or bx.x1, xb or bx.x2 do
        for y = math.max(2, e.y - 50), math.min(my - 3, e.y + 50) do
            -- walk down the column: floor, rock (>=1), air (>=0), water
            local top, rocks, airs = nil, 0, 0
            for z = e.z + 3, math.max(1, e.z - 45), -1 do
                if top and airs == 0 and rock(x, y, z) then
                    rocks = rocks + 1
                elseif top and rocks > 0 and open_air(x, y, z) then
                    airs = airs + 1
                elseif top and rocks > 0 and water(x, y, z) then
                    local wz = z
                    local cost = rocks * 3 + math.abs(x - e.x) + math.abs(y - e.y) + math.abs(top - e.z)
                    if not best or cost < best.cost then
                        -- a real body of water, not a puddle
                        local n = 0
                        for dx = -3, 3 do for dy = -3, 3 do
                            local f = dfhack.maps.getTileFlags(x + dx, y + dy, wz)
                            if f and f.flow_size >= 3 and not f.liquid_type then n = n + 1 end
                        end end
                        if n >= 12 then
                            local zlo = top - rocks   -- lowest rock level of the shaft
                            for _, d in ipairs(D4) do
                                local sx, sy = x + d[1], y + d[2]
                                if fort_floor(sx, sy, top) and sealed(x, y, sx, sy, zlo, top - 1) then
                                    -- someone can still reach the well, and the stairhead, once walled
                                    local t_ok, s_ok = false, false
                                    for _, d2 in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
                                        local ax, ay = x + d2[1], y + d2[2]
                                        if not (ax == sx and ay == sy) and fort_floor(ax, ay, top) then t_ok = true end
                                        local bx, by = sx + d2[1], sy + d2[2]
                                        if not (bx == x and by == y) and fort_floor(bx, by, top) then s_ok = true end
                                    end
                                    if t_ok and s_ok then
                                        best = {x = x, y = y, sx = sx, sy = sy, top = top, zlo = zlo, wz = wz, cost = cost}
                                        break
                                    end
                                end
                            end
                        end
                    end
                    break
                elseif fort_floor(x, y, z) then
                    top, rocks, airs = z, 0, 0
                else
                    if top and rocks > 0 then break end   -- something else in the way
                    top, rocks, airs = nil, 0, 0
                end
            end
        end
    end
    if not best then return nil, 'no spot where a shaft from the fort floor goes through solid rock to water' end
    return best
end

-- the same search spread over game ticks, 3 columns of the box at a time
-- (all at once is ~300,000 tiles: the game would stall)
local function scan_async(done)
    local bx = box()
    if not bx then done(nil, 'no citizens') return end
    local best
    local function slice(x)
        if x > bx.x2 then
            if best then done(best) else done(nil, 'no spot where a shaft from the fort floor goes through solid rock to water') end
            return
        end
        local ok, b = pcall(find_site, x, math.min(bx.x2, x + 2), best)
        if ok and b then best = b end
        dfhack.timeout(2, 'ticks', function() slice(x + 3) end)
    end
    slice(bx.x1)
end

-- dig designations (only where there's no dig job yet)
local function designate(p)
    local jobs = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and (j.job_type == df.job_type.Dig or j.job_type == df.job_type.DigChannel or j.job_type == df.job_type.CarveUpwardStaircase
            or j.job_type == df.job_type.CarveDownwardStaircase or j.job_type == df.job_type.CarveUpDownStaircase) then
            jobs[j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z] = true
        end
        l = l.next
    end
    local function set(x, y, z, how)
        if jobs[x .. ',' .. y .. ',' .. z] then return end
        local f, occ = dfhack.maps.getTileFlags(x, y, z)
        if f and f.dig ~= how then
            f.dig = how
            dfhack.maps.getTileBlock(x, y, z).flags.designated = true
        end
    end
    local DD = df.tile_dig_designation
    -- 1. the whole stair first
    local stairs_done = true
    for z = p.zlo, p.top do
        local sa = attrs(p.sx, p.sy, z)
        local want = (z == p.top and Sh.STAIR_DOWN) or (z == p.zlo and Sh.STAIR_UP) or Sh.STAIR_UPDOWN
        if sa and sa.shape ~= want then
            stairs_done = false
            set(p.sx, p.sy, z, (z == p.top and DD.DownStair) or (z == p.zlo and DD.UpStair) or DD.UpDownStair)
        end
    end
    if not stairs_done then return end
    -- 2. then the shaft from the BOTTOM up, one level at a time, each only
    -- once the level below is open. Channelling every level at once killed a
    -- miner at Channelevened: a level was cut out from above while he worked
    -- on it, and he fell 32 levels. Bottom-up, every channelled tile has open
    -- air under it, so nobody ever stands in the column.
    for z = p.zlo, p.top do
        if not open_air(p.x, p.y, z) then
            set(p.x, p.y, z, DD.Channel)
            return
        end
    end
end

local function shaft_open(p)
    for z = p.zlo, p.top do if not open_air(p.x, p.y, z) then return false end end
    return true
end

local function rope_ready()
    for _, i in ipairs(df.global.world.items.other.CHAIN) do
        if not (i.flags.forbid or i.flags.in_job or i.flags.in_building or i.flags.trader) then return true end
    end
    local queued = false
    for _, mo in ipairs(df.global.world.manager_orders.all) do
        if mo.job_type == df.job_type.MakeChain and mo.amount_left > 0 then queued = true end
    end
    if not queued then
        local cloth = 0
        for _, i in ipairs(df.global.world.items.other.CLOTH) do if not (i.flags.forbid or i.flags.in_job) then cloth = cloth + 1 end end
        dfhack.run_command_silent('workorder', cloth > 0 and '{"job":"MakeChain","material_category":["cloth"],"amount_total":2}'
            or '{"job":"MakeChain","material_category":["metal"],"amount_total":2}')
    end
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and j.job_type == df.job_type.MakeChain then j.flags.do_now = true j.flags.suspend = false end
        l = l.next
    end
    -- water before restraints: Topcloister's only 4 ropes were all tied up in
    -- empty restraints, with no cloth to make another. Take one down that
    -- isn't holding anything; its rope comes free for the well.
    for _, b in ipairs(df.global.world.buildings.other.CHAIN) do
        if b:getBuildStage() >= b:getMaxBuildStage() and not b.chained and #b.jobs == 0 then
            if pcall(dfhack.buildings.deconstruct, b) then return false end
        end
    end
    return false
end

local function units_in_stair(p)
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and u.pos.x == p.sx and u.pos.y == p.sy and u.pos.z >= p.zlo and u.pos.z < p.top then return u end
    end
end

local function step(s)
    local p = s.current
    if p.phase == 'dig' then
        if shaft_open(p) then
            p.phase = 'seal'
        else
            designate(p)
            -- water comes first: enough miners to dig it even when half the
            -- fort is in bed (Topcloister: 24 of 56 resting, every miner
            -- resting or carrying water to them)
            if not p.labor then dfhack.run_command_silent('autolabor', 'MINE', '3', '8') p.labor = true end
            -- and to the front of the queue: this is the fort's water
            local l = df.global.world.jobs.list.next
            while l do
                local j = l.item
                if j and j.pos.z >= p.zlo and j.pos.z <= p.top and ((j.pos.x == p.x and j.pos.y == p.y) or (j.pos.x == p.sx and j.pos.y == p.sy)) then
                    j.flags.do_now = true
                end
                l = l.next
            end
            local left = 0
            for z = p.zlo, p.top do if not open_air(p.x, p.y, z) then left = left + 1 end end
            s.last = ('digging the well shaft at %d,%d: %d of %d levels to go, water %d levels down'):format(p.x, p.y, left, p.top - p.zlo + 1, p.top - p.wz)
            return
        end
    end
    if p.phase == 'seal' then
        local a = attrs(p.sx, p.sy, p.top)
        if a and a.shape == Sh.WALL then
            p.phase = 'well'
        else
            local u = units_in_stair(p)
            if u then s.last = 'waiting for everyone to climb out of the shaft stair before it is walled up' return end
            if not dfhack.buildings.findAtTile(xyz2pos(p.sx, p.sy, p.top)) then
                local ok, err = pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = df.construction_type.Wall, pos = xyz2pos(p.sx, p.sy, p.top)})
                if not ok then s.last = 'could not order the wall over the shaft stair: ' .. tostring(err) return end
            end
            s.last = 'shaft open to the water; walling up its stair so nothing climbs out'
            return
        end
    end
    if p.phase == 'well' then
        local b = dfhack.buildings.findAtTile(xyz2pos(p.x, p.y, p.top))
        if b and b:getType() == df.building_type.Well then
            if b:getBuildStage() >= b:getMaxBuildStage() then
                p.phase = 'done'
                p.well = b.id
                local occ = dfhack.maps.getTileBlock(p.x, p.y, p.top).occupancy[p.x % 16][p.y % 16]
                p.blocks = df.tile_building_occ[occ.building]
                s.done = p
                s.current = nil
                s.last = ('well built over the shaft at %d,%d level %d: water %d levels down'):format(p.x, p.y, p.top, p.top - p.wz)
                dfhack.gui.showAnnouncement('A well now draws water from the lake far below.', COLOR_LIGHTCYAN, true)
                pcall(function() reqscript('dfai-projects').done('wellshaft') end)
            else
                local has_rope = false
                for _, j in ipairs(b.jobs) do
                    j.flags.do_now = true j.flags.suspend = false
                    for _, ji in ipairs(j.items) do if ji.item:getType() == df.item_type.CHAIN then has_rope = true end end
                end
                if has_rope or rope_ready() then
                    s.last = 'the well is being built over the shaft'
                else
                    s.last = 'the well is waiting for a rope or chain (ordered; an empty restraint is taken down for one)'
                end
            end
            return
        end
        -- order the well first, so it is already waiting when a rope comes
        -- free (df-ai put a freed rope straight back into a new restraint)
        -- any plain stone, not just blocks: Topcloister had 495 blocks, none
        -- free (all in walls), and the well kept failing "unable to complete"
        local ok, err = pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Well, pos = xyz2pos(p.x, p.y, p.top), filters = WELL_FILTERS})
        if not ok then s.last = 'could not order the well: ' .. tostring(err) return end
        s.last = 'well ordered over the shaft'
        return
    end
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        if not s.current then
            local w = working_well()
            if w then s.last = ('the fort has a well with water (%d,%d level %d)'):format(w.x1, w.y1, w.z) return end
            -- only when the game itself says there's no water (a fresh fort has
            -- no well yet but usually drinks from a river or pond: Channelevened
            -- started a 32-level shaft on its first day)
            local okp, pri = pcall(reqscript, 'dfai-priorities')
            if okp and not pri.no_water() then s.last = 'no well, but the fort has water to drink' return end
            -- looking is not free: once a game month at most
            local now = df.global.cur_year * 403200 + df.global.cur_year_tick
            if s.looked and now - s.looked < 33600 then return end
            s.looked = now
            if scanning then return end
            scanning = true
            s.last = 'no well reaches water: looking for a place to sink a shaft'
            scan_async(function(p, why)
                scanning = false
                local s2 = load()
                if not p then s2.last = 'no well shaft possible: ' .. tostring(why) save(s2) return end
                p.phase = 'dig'
                s2.current = p
                s2.last = ('a well shaft is planned at %d,%d level %d, water %d levels down'):format(p.x, p.y, p.top, p.top - p.wz)
                pcall(function() reqscript('dfai-projects').add('wellshaft', 'A Well Shaft to the Lake', p.x, p.y, p.zlo, p.sx, p.sy, p.top, true) end)
                dfhack.gui.showAnnouncement('No well reaches water: the miners will sink a shaft to the lake below.', COLOR_LIGHTCYAN, true)
                save(s2)
            end)
            return
        end
        step(s)
    end)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
end

function status()
    local s = load()
    return 'well shaft: ' .. (s.last or 'idle')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('well shaft: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local s = load() s.looked = nil save(s) tick() end)
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('well shaft: checking on the next tick')
elseif cmd == 'find' then
    local w = working_well()
    if w then print(('a well already reaches water: %d,%d level %d'):format(w.x1, w.y1, w.z)) end
    local p, why = find_site()
    if not p then print('no site: ' .. tostring(why)) return end
    print(('well at %d,%d level %d, stair at %d,%d; shaft through rock to level %d, water at level %d (%d levels down)'):format(
        p.x, p.y, p.top, p.sx, p.sy, p.zlo, p.wz, p.top - p.wz))
else
    print(status())
end
