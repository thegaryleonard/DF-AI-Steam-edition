-- dfai-mist-surface: the surface mist generator, for forts where the
-- underground one (dfai-mist: pump ring over the tavern, axle shaft to
-- windmills) finds no site. The user's Showerwheels design, generic:
--
--   ground level z   a walled 19x11 house on flat open ground near the gate:
--                    the west room (8x9) holds 4 statues, each under a hole
--                    in the roof; the east room is a sheltered hall; doors
--                    on every side, a stair up to the roof
--   roof (z+1)       a constructed floor on the walls with a fortification
--                    parapet; the 4-pump ring over the statues, an axle and
--                    gears to 4 windmills on the roof
--
-- Water lifted round the ring falls through the 4 holes onto the statues:
-- mist in the room below. Primed by bucket: a pond over one hole until ~3
-- buckets are in, then the pond is removed (no top-ups, no floods).
-- Blueprints: dfhack-config/blueprints/dfai-mist/{A_z177_walls, B_z178_roof,
-- C_z178_machines, D_z177_statues}.csv, replayed at the site's top-left
-- corner (A and D on the ground level, B and C on the roof).
-- The site: every tile buildable floor with open sky above, solid natural
-- rock right under it (a roof over dug ground caved in: the watch post),
-- on no room df-ai has planned, inside the curtain wall when there is one.
--   dfai-mist-surface status | find (dry run)   (dfai-mist drives it)
--@module = true

local KEY = 'dfai-mist-surface'
local S = reqscript('dfai-surface')
local W, H = 19, 11
local BP = 'dfai-mist/'
local FILES = {A = 'A_z177_walls.csv', B = 'B_z178_roof.csv', C = 'C_z178_machines.csv', D = 'D_z177_statues.csv'}
local PRIME_WATER = 21    -- three buckets, in 1/7 units

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

-- a blueprint's cells as {dx, dy, key} (0-based from the top-left)
local cache = {}
local function cells(which)
    if cache[which] then return cache[which] end
    local out = {}
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/blueprints/' .. BP .. FILES[which], 'r')
    if not f then return out end
    local dy = -1
    for line in f:lines() do
        line = line:gsub('\r', '')
        if not line:match('^#') then
            dy = dy + 1
            local dx = 0
            for cell in (line .. ','):gmatch('([^,]*),') do
                if cell ~= '' then out[#out + 1] = {dx, dy, cell} end
                dx = dx + 1
            end
        end
    end
    f:close()
    cache[which] = out
    return out
end

local function qf(p, which, verb)
    local z = (which == 'B' or which == 'C') and p.z + 1 or p.z
    local args = {'quickfort', verb == 'dry' and 'run' or (verb or 'run'), BP .. FILES[which], '-c', ('%d,%d,%d'):format(p.x, p.y, z)}
    if verb == 'dry' then args[#args + 1] = '--dry-run' end
    return dfhack.run_command_silent(table.unpack(args))
end

local function is_construction(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].material == df.tiletype_material.CONSTRUCTION
end
local function done_building(x, y, z, btype)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return b and (not btype or b:getType() == btype) and b:getBuildStage() >= b:getMaxBuildStage()
end

local function left(p, which)
    local n, z = 0, (which == 'B' or which == 'C') and p.z + 1 or p.z
    for _, c in ipairs(cells(which)) do
        local x, y, k = p.x + c[1], p.y + c[2], c[3]
        if which == 'C' then
            if k ~= 'Mm' and not done_building(x, y, z) then n = n + 1 end
        elseif k == 'd' then
            if not done_building(x, y, z, df.building_type.Door) then n = n + 1 end
        elseif k:sub(1, 1) == 'C' then
            if not is_construction(x, y, z) then n = n + 1 end
        end
    end
    return n
end

-- the roof's holes (empty cells in B inside the parapet), over the statues
local function holes(p)
    local filled, out = {}, {}
    for _, c in ipairs(cells('B')) do filled[c[1] * 100 + c[2]] = true end
    for dx = 1, W - 2 do for dy = 1, H - 2 do
        if not filled[dx * 100 + dy] then out[#out + 1] = {p.x + dx, p.y + dy, p.z + 1} end
    end end
    return out
end

local function windmills(p)
    local placed, built, total = 0, 0, 0
    for _, c in ipairs(cells('C')) do
        if c[3] == 'Mm' then
            total = total + 1
            local cx, cy, z = p.x + c[1], p.y + c[2], p.z + 1
            local b = dfhack.buildings.findAtTile(xyz2pos(cx, cy, z))
            if b and b:getType() == df.building_type.Windmill then
                placed = placed + 1
                if b:getBuildStage() >= b:getMaxBuildStage() then built = built + 1 end
            elseif not b then
                local floor = true
                for dx = -1, 1 do for dy = -1, 1 do if not is_construction(cx + dx, cy + dy, z) then floor = false end end end
                if floor and pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Windmill,
                    pos = xyz2pos(cx - 1, cy - 1, z), width = 3, height = 3}) then placed = placed + 1 end
            end
        end
    end
    return placed, built, total
end

local function power(p)
    local cur, need = 0, 0
    for _, m in ipairs(df.global.world.machines.all) do
        local mine = false
        for _, c in ipairs(m.components) do
            local b = df.building.find(c.building_id)
            if b and b.z == p.z + 1 and b.x1 >= p.x and b.x2 <= p.x + W - 1 and b.y1 >= p.y and b.y2 <= p.y + H - 1 then mine = true end
        end
        if mine then cur, need = cur + m.cur_power, need + m.min_power end
    end
    return cur, need
end

local function water_inside(p)
    local w = 0
    for z = p.z, p.z + 1 do for x = p.x, p.x + W - 1 do for y = p.y, p.y + H - 1 do
        local f = dfhack.maps.getTileFlags(x, y, z)
        if f and not f.liquid_type then w = w + f.flow_size end
    end end end
    return w
end
local function mist_near(p)
    local m = 0
    for _, fl in ipairs(df.global.flows) do
        if fl.type == df.flow_type.Mist and fl.density > 0 and fl.pos.x >= p.x - 6 and fl.pos.x <= p.x + W + 5 and fl.pos.y >= p.y - 6 and fl.pos.y <= p.y + H + 5 then m = m + 1 end
    end
    return m
end
local function pond_zone(p)
    local h = holes(p)[1]
    if not h then return end
    for _, b in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if b.type == df.civzone_type.Pond and b.z == h[3] and b.x1 <= h[1] and b.x2 >= h[1] and b.y1 <= h[2] and b.y2 >= h[2] then return b end
    end
end
local function make_pond(p)
    local h = holes(p)[1]
    if not h then return end
    local path = dfhack.getDFPath() .. '/dfhack-config/blueprints/' .. BP .. 'E_pond.csv'
    local f = io.open(path, 'w')
    f:write('#zone label(pond)\np{name="Mist Generator Priming Pond"}\n')
    f:close()
    dfhack.run_command_silent('quickfort', 'run', BP .. 'E_pond.csv', '-c', ('%d,%d,%d'):format(h[1], h[2], h[3]))
    local z = pond_zone(p)
    if z then z.spec_sub_flag.active = true end
end

-- open tiles inside the house (a dip, a ramp top) get a floor first, so the
-- room is sealed and the builders have something to stand on
local function floor_holes(p)
    local wall = {}
    for _, c in ipairs(cells('A')) do wall[c[1] * 100 + c[2]] = true end
    for dx = 1, W - 2 do for dy = 1, H - 2 do
        if not wall[dx * 100 + dy] then
            local x, y = p.x + dx, p.y + dy
            local a = S.attrs(x, y, p.z)
            if a and (a.shape == df.tiletype_shape.EMPTY or a.shape == df.tiletype_shape.RAMP_TOP) and not dfhack.buildings.findAtTile(xyz2pos(x, y, p.z)) then
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = df.construction_type.Floor, pos = xyz2pos(x, y, p.z)})
            end
        end
    end end
end

-- the curtain wall's box, if it has one
local function wall_box()
    local w = dfhack.persistent.getSiteData('dfai-walls', {})
    if not w.ring or #w.ring == 0 then return nil end
    local b = {x1 = math.huge, y1 = math.huge, x2 = -math.huge, y2 = -math.huge}
    for _, t in ipairs(w.ring) do
        b.x1, b.y1, b.x2, b.y2 = math.min(b.x1, t[1]), math.min(b.y1, t[2]), math.max(b.x2, t[1]), math.max(b.y2, t[2])
    end
    return b
end

function find_site()
    local okp, ai = pcall(require, 'plugins.df-ai')
    local planned = okp and ai.planned_room_at or function() return '' end
    local inside = wall_box()
    local wb = inside
    -- (a dry run reports the 5 doors as unsuitable until the walls beside
    -- them stand: stage A re-places them every pass)
    local function tile_ok(x, y, z)
        if wb and (x <= wb.x1 + 1 or x >= wb.x2 - 1 or y <= wb.y1 + 1 or y >= wb.y2 - 1) then return false end
        if not (S.buildable(x, y, z) and S.open_air(x, y, z + 1)) then return false end
        local a = S.attrs(x, y, z - 1)
        local f = dfhack.maps.getTileFlags(x, y, z - 1)
        if not a or a.shape ~= df.tiletype_shape.WALL or a.material == df.tiletype_material.CONSTRUCTION or not f or f.water_table then return false end
        for dz = -1, 1 do if planned(x, y, x, y, z + dz) ~= '' then return false end end
        return true
    end
    local site = S.find_near_gate(W, H, tile_ok, {min_dist = 6, max_dist = 40})
    -- a small curtain wall has no room for it: then just outside, by the
    -- gate (the house is walled itself; its doors can be locked)
    if not site and inside then
        wb = nil
        site = S.find_near_gate(W, H, tile_ok, {min_dist = 6, max_dist = 40})
    end
    if not site then return nil, 'no flat open 19x11 ground with rock under it near the gate' end
    return {x = site.x1, y = site.y1, z = site.z, phase = 'A'}
end

-- one pass; returns the status line
function step(p)
    local res
    if p.phase == 'A' then
        floor_holes(p)
        local n = left(p, 'A')
        if n > 0 then qf(p, 'A') return ('surface mist generator: walls and doors, %d left'):format(n) end
        qf(p, 'D') qf(p, 'B') qf(p, 'C', 'orders')
        p.phase = 'B'
        return 'surface mist generator: walls done; roof, parapet and statues designated, machine parts ordered'
    end
    if p.phase == 'B' then
        local n = left(p, 'B')
        if n > 0 then
            qf(p, 'B') qf(p, 'D') qf(p, 'C') windmills(p)
            return ('surface mist generator: roof and parapet, %d left'):format(n)
        end
        p.phase = 'C'
    end
    if p.phase == 'C' then
        qf(p, 'C') qf(p, 'D')
        local n = left(p, 'C')
        local placed, built, total = windmills(p)
        if n > 0 or built < total then
            return ('surface mist generator: machines, %d parts left, windmills %d of %d built'):format(n, built, total)
        end
        p.phase = 'priming'
    end
    if p.phase == 'priming' then
        local w = water_inside(p)
        if w >= PRIME_WATER or (w >= 7 and mist_near(p) > 0) then
            local z = pond_zone(p)
            if z then pcall(dfhack.buildings.deconstruct, z) end
            p.phase = 'running'
            return ('surface mist generator: primed with %d/7 of water, pond removed'):format(w)
        end
        if not pond_zone(p) then make_pond(p) end
        local cur, need = power(p)
        return ('surface mist generator: priming, %d/7 of water in (power %d of %d)'):format(w, cur, need)
    end
    if p.phase == 'running' then
        local w = water_inside(p)
        if w < 3 then p.phase = 'priming' end
        return ('surface mist generator: running, %d/7 water, %d mist clouds'):format(w, mist_near(p))
    end
    return 'surface mist generator: ' .. tostring(p.phase)
end

function box(p) return {x1 = p.x, y1 = p.y, x2 = p.x + W - 1, y2 = p.y + H - 1, z = p.z} end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'find' then
    local p, why = find_site()
    if not p then print('no site: ' .. tostring(why)) return end
    print(('site: top-left %d,%d level %d (roof %d); holes over the statues at:'):format(p.x, p.y, p.z, p.z + 1))
    for _, h in ipairs(holes(p)) do print(('  %d,%d,%d'):format(h[1], h[2], h[3])) end
    for _, w in ipairs({'A', 'D'}) do print(w .. ' (dry run): ' .. qf(p, w, 'dry'):gsub('%s+', ' '):sub(1, 200)) end
else
    local s = dfhack.persistent.getSiteData('dfai-mist', {})
    print(s.last or 'mist generator: idle')
end
