-- dfai-mist: the tavern mist generator, for any fort (user: "an underground
-- mist pump ring can be powered by surface windmills. the water will be
-- bucketed and then done when running. i used to put the statues in a big
-- tavern and the pump ring above it, and the windmills on top of the
-- entrance. straight shaft down to power things. elbow as necessary").
--
--   tavern (level z)     4 statues on the tavern floor, each under a hole in
--                        the ceiling: falling water = mist where the fort
--                        drinks, eats and dances
--   chamber (z+1)        dug out of the rock over the tavern: the 4-pump ring
--                        (the Showerwheels ring) lifts the water and drops it
--                        through the holes, round and round; a stair down
--                        into the tavern lets the builders in
--   tunnel (z+1)         axles from the ring to the foot of the shaft, a gear
--                        at every elbow
--   shaft                a straight column of vertical axles up through the
--                        rock, channelled level by level from a stair beside
--                        it that is dug up from below - the surface gets no
--                        new way in (the windmill's centre caps the shaft)
--   surface (top)        2-4 windmills in a row near the entrance, joined by
--                        gears; the first stands on the shaft
--
-- Then a priming pond on one hole: dwarves bucket water in; once ~3 buckets
-- are in the ring it's removed (no top-ups, no floods) and it runs on its own.
-- Waits on the Overseer's priority list ("mist") and needs water on the map.
--   dfai-mist start | status | find (dry run) | now
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-mist'
local S = reqscript('dfai-surface')
local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local Sh = df.tiletype_shape

-- the ring, relative to its origin (the Showerwheels layout)
local RING = {{4, 2, 'Msh'}, {4, 3, 'Mg'}, {2, 4, 'Msm'}, {3, 4, 'Mg'}, {4, 4, 'Mg'}, {5, 4, 'Msu'}, {6, 4, 'Mg'}, {4, 5, 'Msk'}}
local HOLES = {{2, 2}, {5, 2}, {2, 5}, {5, 5}}       -- holes in the chamber floor, statues under them
local CHAMBER = {1, 1, 7, 6}                         -- dug out at z+1 (local x1, y1, x2, y2)
local STAIR = {1, 1}                                 -- tavern up-stair / chamber down-stair
local OUT = {7, 4}                                   -- where the power comes in from the east (next to the ring's gear at 6,4)
local OUT_W = {0, 4}                                 -- ...or from the west: an extra gear at 1,4 beside the pump at 2,4
local GEAR_W = {1, 4}
-- the drive axle must never cross the ring: Cloisterbolt's shaft lay west
-- of the ring, the tunnel ran west from the east inlet straight along the
-- ring's middle row, one long axle took the pump and gear tiles, two pumps
-- were never built and the other two never joined the windmills (status
-- said 'waiting for wind' while the windmills made 80 power)
local function inlet(p) if p.inlet == 'W' then return OUT_W else return OUT end end
local function in_ring(r, x, y) return x >= r.x and x <= r.x + 7 and y >= r.y and y <= r.y + 7 end
local POND = {5, 2}
local PRIME_WATER = 21
local MAX_TUNNEL = 45

local function shape(x, y, z) local a = S.attrs(x, y, z) return a and a.shape end
local function rock(x, y, z)
    local a = S.attrs(x, y, z)
    if not a or a.shape ~= Sh.WALL or a.material == df.tiletype_material.TREE then return false end
    local f = dfhack.maps.getTileFlags(x, y, z)
    return f.flow_size == 0 and not f.water_table
end
local function free_floor(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    return shape(x, y, z) == Sh.FLOOR and f and not f.hidden and not dfhack.buildings.findAtTile(xyz2pos(x, y, z))
end

-- the public tavern's zones (dfai-build knows which is public)
local function tavern_zones()
    local ok, B = pcall(reqscript, 'dfai-build')
    if not ok then return {} end
    local _, zones = B.public_tavern()
    return zones or {}
end

-- a spot for the ring inside the tavern: statue tiles and the stair free,
-- solid rock above for the chamber; the busiest spot wins (dfai-traffic)
local function ring_site()
    local okt, TR = pcall(reqscript, 'dfai-traffic')
    local best
    for _, zn in ipairs(tavern_zones()) do
        local z = zn.z
        for ox = zn.x1 - 1, zn.x2 - 6 do
            for oy = zn.y1 - 1, zn.y2 - 5 do
                local ok = true
                for _, h in ipairs(HOLES) do if not free_floor(ox + h[1], oy + h[2], z) then ok = false break end end
                ok = ok and free_floor(ox + STAIR[1], oy + STAIR[2], z)
                if ok then
                    for x = ox + CHAMBER[1], ox + CHAMBER[3] do
                        for y = oy + CHAMBER[2], oy + CHAMBER[4] do if not rock(x, y, z + 1) then ok = false break end end
                        if not ok then break end
                    end
                end
                if ok then
                    local feet = okt and TR.box(ox + 1, oy + 1, ox + 6, oy + 6, z) or 0
                    if not best or feet > best.feet then best = {x = ox, y = oy, z = z, feet = feet} end
                end
            end
        end
    end
    return best
end

-- the surface level at x,y (an outdoor floor with open sky), searched hi..lo
local function surface_at(x, y, lo, hi)
    for z = hi, lo, -1 do
        local a = S.attrs(x, y, z)
        if a and a.shape ~= Sh.EMPTY then
            if S.buildable(x, y, z) and S.open_air(x, y, z + 1) and dfhack.maps.getTileFlags(x, y, z).outside then return z end
            return nil
        end
    end
end

local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
-- the windmill row from the shaft head along d: n windmill centres + gears between
local function row(sx, sy, d, n)
    local mills, gears = {}, {}
    for i = 0, n - 1 do
        mills[#mills + 1] = {sx + 4 * i * d[1], sy + 4 * i * d[2]}
        if i > 0 then gears[#gears + 1] = {sx + (4 * i - 2) * d[1], sy + (4 * i - 2) * d[2]} end
    end
    return mills, gears
end
local function row_ok(mills, gears, zs, res)
    for _, m in ipairs(mills) do
        for dx = -1, 1 do for dy = -1, 1 do
            local x, y = m[1] + dx, m[2] + dy
            if not (S.buildable(x, y, zs) and S.open_air(x, y, zs + 1)) then return false end
        end end
    end
    for _, g in ipairs(gears) do if not (S.buildable(g[1], g[2], zs) and S.open_air(g[1], g[2], zs + 1)) then return false end end
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, m in ipairs(mills) do x1, y1, x2, y2 = math.min(x1, m[1] - 1), math.min(y1, m[2] - 1), math.max(x2, m[1] + 1), math.max(y2, m[2] + 1) end
    if S.taken(x1, y1, x2, y2, zs, 1, res) then return false end
    return true, {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end

-- the tunnel at level z from the ring's power inlet to the shaft foot: an L
-- (either way round) through solid rock; tiles in order, or nil
local function tunnel(ax, ay, bx, by, z, ring)
    for _, xfirst in ipairs({true, false}) do
        local t, ok = {{ax, ay}}, rock(ax, ay, z)
        local x, y = ax, ay
        local function go(tx, ty)
            while ok and (x ~= tx or y ~= ty) do
                if x ~= tx then x = x + (tx > x and 1 or -1) else y = y + (ty > y and 1 or -1) end
                if not rock(x, y, z) or (ring and in_ring(ring, x, y)) then ok = false end
                t[#t + 1] = {x, y}
            end
        end
        if xfirst then go(bx, ay) go(bx, by) else go(ax, by) go(bx, by) end
        if ok and #t <= MAX_TUNNEL then return t end
    end
end

function find_site(keep_ring)
    local r = keep_ring or ring_site()
    if not r then return nil, 'no room for the pump ring over the public tavern (it needs 4 free floor tiles for statues, a free tile for a stair, and solid rock above)' end
    local e = S.entrance()
    if not e then return nil, 'no fort entrance known yet' end
    local res = S.reserved()
    local mx, my = dfhack.maps.getTileSize()
    local zc = r.z + 1
    local best
    for sx = math.max(4, e.x - 25), math.min(mx - 5, e.x + 25) do
        for sy = math.max(4, e.y - 25), math.min(my - 5, e.y + 25) do
            local zs = surface_at(sx, sy, zc + 3, e.z + 8)
            -- power comes in on the ring's side facing the shaft
            local side = sx < r.x + 4 and 'W' or 'E'
            local io = side == 'W' and OUT_W or OUT
            local ax, ay = r.x + io[1], r.y + io[2]
            local dist = zs and (math.abs(sx - ax) + math.abs(sy - ay) + math.abs(sx - e.x) + math.abs(sy - e.y))
            if zs and (not best or dist < best.dist) then
                -- the shaft and its stair through solid rock, all the way down
                local shaft_ok = true
                for z = zc, zs - 1 do if not rock(sx, sy, z) then shaft_ok = false break end end
                if shaft_ok then
                    local stair
                    for _, d in ipairs(DIRS) do
                        local ok = true
                        for z = zc, zs - 1 do if not rock(sx + d[1], sy + d[2], z) then ok = false break end end
                        if ok then stair = {sx + d[1], sy + d[2]} break end
                    end
                    local t = stair and tunnel(ax, ay, sx, sy, zc, r)
                    if t then
                        for _, p in ipairs(t) do if p[1] == stair[1] and p[2] == stair[2] then t = nil break end end
                    end
                    if t then
                        -- power: 4 pumps at 10 each, 1 per axle tile and per
                        -- gear; a windmill gives 40 in a good wind (20 in a
                        -- poor one): enough windmills for the whole train
                        local need = 40 + #t + (zs - zc - 1) + 8
                        local min_mills = math.ceil(need / 40)
                        for n = 4, min_mills, -1 do
                            local placed = false
                            for _, d in ipairs(DIRS) do
                                local mills, gears = row(sx, sy, d, n)
                                local ok, bb = row_ok(mills, gears, zs, res)
                                if ok then
                                    best = {need = need + (side == 'W' and 1 or 0), inlet = side, dist = dist, ring = r, zc = zc, zs = zs, shaft = {sx, sy}, stair = stair, tunnel = t,
                                        mills = mills, gears = gears, box = {x1 = bb.x1, y1 = bb.y1, x2 = bb.x2, y2 = bb.y2, z = zs}}
                                    placed = true
                                    break
                                end
                            end
                            if placed then break end
                        end
                    end
                end
            end
        end
    end
    if not best then return nil, 'no flat ground near the entrance for the windmills with solid rock under it down to the pump chamber' end
    return best
end

-- ---- blueprints: one small CSV per pass, placed at absolute coordinates ----
local DIR = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
local function place(mode, label, cells, z, verb)
    if #cells == 0 then return '' end
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(cells) do x1, y1, x2, y2 = math.min(x1, c[1]), math.min(y1, c[2]), math.max(x2, c[1]), math.max(y2, c[2]) end
    local grid = {}
    for _, c in ipairs(cells) do grid[c[2] * 10000 + c[1]] = c[3] end
    local rows = {}
    for y = y1, y2 do
        local r = {}
        for x = x1, x2 do r[#r + 1] = grid[y * 10000 + x] or '' end
        rows[#rows + 1] = table.concat(r, ',')
    end
    dfhack.filesystem.mkdir_recursive(DIR)
    local name = 'mist_' .. label .. '.csv'
    local f = io.open(DIR .. '/' .. name, 'w')
    f:write('#' .. mode .. ' label(' .. label .. ') start(1;1)\n' .. table.concat(rows, '\n') .. '\n')
    f:close()
    local args = {'quickfort', verb == 'dry' and 'run' or (verb or 'run'), 'dfai-gen/' .. name, '-c', ('%d,%d,%d'):format(x1, y1, z)}
    if verb == 'dry' then args[#args + 1] = '--dry-run' end
    return dfhack.run_command_silent(table.unpack(args))
end

local function cells_dig(p)
    local r, out = p.ring, {}
    for x = r.x + CHAMBER[1], r.x + CHAMBER[3] do
        for y = r.y + CHAMBER[2], r.y + CHAMBER[4] do
            out[#out + 1] = {x, y, (x == r.x + STAIR[1] and y == r.y + STAIR[2]) and 'j' or 'd'}
        end
    end
    -- the east inlet is a chamber tile; the west one is the first tunnel tile
    for i, t in ipairs(p.tunnel) do if i > 1 or p.inlet == 'W' then out[#out + 1] = {t[1], t[2], 'd'} end end
    out[#out + 1] = {p.stair[1], p.stair[2], 'u'}
    return out
end
-- straight runs get an axle along the run; elbows and the shaft foot a gear
local function axle_key(prev, cur, nxt)
    if not prev or not nxt then return 'Mg' end
    if prev[2] == cur[2] and nxt[2] == cur[2] then return 'Mh' end
    if prev[1] == cur[1] and nxt[1] == cur[1] then return 'Mhs' end
    return 'Mg'
end
local function cells_machines(p)
    local r, out = p.ring, {}
    for _, m in ipairs(RING) do out[#out + 1] = {r.x + m[1], r.y + m[2], m[3]} end
    if p.inlet == 'W' then out[#out + 1] = {r.x + GEAR_W[1], r.y + GEAR_W[2], 'Mg'} end
    local t = p.tunnel
    local io = inlet(p)
    for i, c in ipairs(t) do
        -- the ring's gear is beside the inlet: west of the east one, east of the west one
        local prev = i == 1 and {r.x + io[1] + (p.inlet == 'W' and 1 or -1), r.y + io[2]} or t[i - 1]
        out[#out + 1] = {c[1], c[2], axle_key(prev, c, t[i + 1])}
    end
    return out
end

-- ---- progress ----
local function open(x, y, z) local s = shape(x, y, z) return s and s ~= Sh.WALL end
local function built(x, y, z, t)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    return b and (not t or b:getType() == t) and b:getBuildStage() >= b:getMaxBuildStage() and b or nil
end
-- the building a machine cell's quickfort key makes (any building on the
-- tile used to count, so an axle lying over a pump tile passed as the pump)
local function key_type(k)
    if k == 'Mg' then return df.building_type.GearAssembly end
    if k == 'Mh' or k == 'Mhs' then return df.building_type.AxleHorizontal end
    if k:sub(1, 2) == 'Ms' then return df.building_type.ScrewPump end
end
local function cell_built(c, z) return built(c[1], c[2], z, key_type(c[3])) end
-- the windmills' own power (their machine), and whether the pumps share it
local function mill_power(p)
    local b = dfhack.buildings.findAtTile(xyz2pos(p.mills[1][1], p.mills[1][2], p.zs))
    if not (b and b:getType() == df.building_type.Windmill) then return 0, nil end
    local m = df.machine.find(b.machine.machine_id)
    return m and m.cur_power or 0, m and m.id
end
-- an older plan whose tunnel runs through the ring: re-route it in through
-- the side facing the shaft, take down whatever stands on the ring's machine
-- tiles that isn't the ring's own part, and go back to building machines
local function repair_inlet(p, dry)
    local r = p.ring
    local crosses = false
    for i, c in ipairs(p.tunnel) do if i > 1 and in_ring(r, c[1], c[2]) then crosses = true break end end
    if not crosses then return false end
    local side = p.shaft[1] < r.x + 4 and 'W' or 'E'
    local io = side == 'W' and OUT_W or OUT
    local t = {{r.x + io[1], r.y + io[2]}}
    for _, c in ipairs(p.tunnel) do if not in_ring(r, c[1], c[2]) then t[#t + 1] = {c[1], c[2]} end end
    if dry then p = {ring = r, inlet = side, tunnel = t, zc = p.zc} else p.inlet, p.tunnel = side, t end
    local drop = {}
    for _, c in ipairs(cells_machines(p)) do
        if in_ring(r, c[1], c[2]) then
            local b = dfhack.buildings.findAtTile(xyz2pos(c[1], c[2], p.zc))
            if b and b:getType() ~= key_type(c[3]) then drop[b.id] = true end
        end
    end
    if dry then
        local d, tt = {}, {}
        for id in pairs(drop) do local b = df.building.find(id) d[#d + 1] = ('%s#%d %d,%d..%d,%d'):format(df.building_type[b:getType()], id, b.x1, b.y1, b.x2, b.y2) end
        for _, c in ipairs(cells_machines(p)) do tt[#tt + 1] = ('%d,%d:%s'):format(c[1], c[2], c[3]) end
        return ('inlet %s; machine cells %s; take down %s'):format(side, table.concat(tt, ' '), table.concat(d, ', '))
    end
    for id in pairs(drop) do local b = df.building.find(id) if b then dfhack.buildings.deconstruct(b) end end
    -- parts for the cells still missing (pumps need a corkscrew and a pipe each)
    local miss = {}
    for _, c in ipairs(cells_machines(p)) do if not cell_built(c, p.zc) then miss[#miss + 1] = c end end
    place('build', 'machines', miss, p.zc, 'orders')
    p.phase = 'machines'
    p.repaired = (p.repaired or 0) + 1
    S.builders(true, KEY)
    return true
end
-- DF never makes a dig job for a HIDDEN designated tile whose only way in is
-- a stair below or above it: Cloisterbolt's mist shaft sat 22 days on its
-- last tile (the top of the stair column, still hidden soil, designated with
-- no job). A designated wall tile with an open, seen neighbour (the 4 sides,
-- or straight above/below) is uncovered so the job gets made.
local function reveal_stuck(cells)
    local n = 0
    for _, c in ipairs(cells) do
        local x, y, z = c[1], c[2], c[3]
        local f = dfhack.maps.getTileFlags(x, y, z)
        if f and f.hidden and f.dig ~= df.tile_dig_designation.No and shape(x, y, z) == Sh.WALL then
            for _, d in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) do
                local nf = dfhack.maps.getTileFlags(x + d[1], y + d[2], z + d[3])
                local ns = shape(x + d[1], y + d[2], z + d[3])
                if nf and not nf.hidden and ns and ns ~= Sh.WALL then
                    f.hidden = false
                    local b = dfhack.maps.getTileBlock(x, y, z)
                    if b then b.flags.designated = true end
                    n = n + 1
                    break
                end
            end
        end
    end
    return n
end
local function dig_cells(p)
    local out = {}
    for _, c in ipairs(cells_dig(p)) do out[#out + 1] = {c[1], c[2], p.zc} end
    for z = p.zc + 1, p.zs - 1 do out[#out + 1] = {p.stair[1], p.stair[2], z} end
    return out
end

local function dug(p)
    local n = 0
    for _, c in ipairs(cells_dig(p)) do if not open(c[1], c[2], p.zc) then n = n + 1 end end
    local s = shape(p.ring.x + STAIR[1], p.ring.y + STAIR[2], p.ring.z)
    if s ~= Sh.STAIR_UP and s ~= Sh.STAIR_UPDOWN then n = n + 1 end
    for z = p.zc + 1, p.zs - 1 do if not open(p.stair[1], p.stair[2], z) then n = n + 1 end end
    return n
end
local function power(p)
    for _, m in ipairs(df.global.world.machines.all) do
        for _, c in ipairs(m.components) do
            local b = df.building.find(c.building_id)
            if b and b:getType() == df.building_type.ScrewPump and b.z == p.zc and b.x1 >= p.ring.x and b.x1 <= p.ring.x + 7 and b.y1 >= p.ring.y and b.y1 <= p.ring.y + 7 then
                return m.cur_power, m.min_power
            end
        end
    end
    return 0, 0
end
local function water_inside(p)
    local w = 0
    for z = p.ring.z, p.zc do
        for x = p.ring.x, p.ring.x + 7 do for y = p.ring.y, p.ring.y + 7 do
            local f = dfhack.maps.getTileFlags(x, y, z)
            if f and not f.liquid_type then w = w + f.flow_size end
        end end
    end
    return w
end
local function mist_near(p)
    local m = 0
    for _, fl in ipairs(df.global.flows) do
        if fl.type == df.flow_type.Mist and fl.density > 0 and math.abs(fl.pos.x - p.ring.x - 3) <= 10 and math.abs(fl.pos.y - p.ring.y - 3) <= 10 then m = m + 1 end
    end
    return m
end
local function pond_zone(p)
    local px, py = p.ring.x + POND[1], p.ring.y + POND[2]
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if z.type == df.civzone_type.Pond and z.z == p.zc and z.x1 <= px and z.x2 >= px and z.y1 <= py and z.y2 >= py then return z end
    end
end
local function statue_cells(p)
    local st = {}
    for _, h in ipairs(HOLES) do st[#st + 1] = {p.ring.x + h[1], p.ring.y + h[2], 's'} end
    return st
end

local function step(s)
    local p = s.plan
    if p.phase ~= 'dig' and p.phase ~= 'shaft' and repair_inlet(p) then
        s.tries = 0
        return 'mist generator: the drive axle crossed the pump ring; re-routing it in from the shaft side and rebuilding the ring'
    end
    local tries = s.tries or 0
    s.tries = tries + 1
    if not (pcall(function() return reqscript('dfai-yardwatch').holding() end) and reqscript('dfai-yardwatch').holding()) then dfhack.run_command_silent('unsuspend') end   -- not while the yard watch holds outdoor work
    if p.phase == 'dig' then
        S.builders(true, KEY)
        local n = dug(p)
        if n > 0 then
            if tries % 5 == 0 then
                place('dig', 'dig', cells_dig(p), p.zc)
                -- an up stair can't be dug out of open floor: it's built
                place('build', 'tavernstair', {{p.ring.x + STAIR[1], p.ring.y + STAIR[2], 'Cu'}}, p.ring.z)
                for z = p.zc + 1, p.zs - 1 do place('dig', 'stair', {{p.stair[1], p.stair[2], z == p.zs - 1 and 'j' or 'i'}}, z) end
            end
            reveal_stuck(dig_cells(p))
            return ('mist generator: digging the pump chamber over the tavern, the tunnel and the stair, %d tiles left'):format(n)
        end
        p.phase, s.tries, tries = 'shaft', 1, 0
        -- statues and machine parts get made while the shaft is dug
        place('build', 'statues', statue_cells(p), p.ring.z, 'orders')
        place('build', 'machines', cells_machines(p), p.zc, 'orders')
    end
    if p.phase == 'shaft' then
        -- channel every level from the chamber's ceiling to the surface (each
        -- from the stair beside it); then the holes over the statues
        local n = 0
        for z = p.zc + 1, p.zs do
            if shape(p.shaft[1], p.shaft[2], z) ~= Sh.EMPTY then
                n = n + 1
                if tries % 5 == 0 then place('dig', 'shaft', {{p.shaft[1], p.shaft[2], 'h'}}, z) end
            end
        end
        if tries % 5 == 0 then place('build', 'statues', statue_cells(p), p.ring.z) end
        local statues = 0
        for _, c in ipairs(statue_cells(p)) do if built(c[1], c[2], p.ring.z, df.building_type.Statue) then statues = statues + 1 end end
        if statues == #HOLES then
            for _, h in ipairs(HOLES) do
                local x, y = p.ring.x + h[1], p.ring.y + h[2]
                if shape(x, y, p.zc) ~= Sh.EMPTY then
                    n = n + 1
                    if tries % 5 == 0 then place('dig', 'hole', {{x, y, 'h'}}, p.zc) end
                end
            end
        else
            n = n + (#HOLES - statues)
        end
        if n > 0 then return ('mist generator: power shaft, statues and the holes over them: %d left (%d of 4 statues)'):format(n, statues) end
        p.phase, tries = 'machines', 0
    end
    if p.phase == 'machines' then
        if tries % 3 == 0 then place('build', 'machines', cells_machines(p), p.zc) end
        local left = 0
        for _, c in ipairs(cells_machines(p)) do if not cell_built(c, p.zc) then left = left + 1 end end
        -- vertical axles from the bottom up: only the lowest missing one, on the one below
        local vleft = 0
        for z = p.zc + 1, p.zs - 1 do
            if not built(p.shaft[1], p.shaft[2], z, df.building_type.AxleVertical) then
                vleft = vleft + 1
                if vleft == 1 and built(p.shaft[1], p.shaft[2], z - 1) and not dfhack.buildings.findAtTile(xyz2pos(p.shaft[1], p.shaft[2], z)) then
                    place('build', 'vaxle', {{p.shaft[1], p.shaft[2], 'Mv'}}, z)
                end
            end
        end
        -- the windmills: the first on the shaft head once the shaft is up
        local mills_built = 0
        for i, m in ipairs(p.mills) do
            local b = dfhack.buildings.findAtTile(xyz2pos(m[1], m[2], p.zs))
            if b and b:getType() == df.building_type.Windmill then
                if b:getBuildStage() >= b:getMaxBuildStage() then mills_built = mills_built + 1 end
            elseif not b and (i > 1 or vleft == 0) then
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Windmill, pos = xyz2pos(m[1] - 1, m[2] - 1, p.zs), width = 3, height = 3})
            end
        end
        local gl = {}
        for _, g in ipairs(p.gears) do if not built(g[1], g[2], p.zs) then gl[#gl + 1] = {g[1], g[2], 'Mg'} end end
        if #gl > 0 and tries % 3 == 0 then place('build', 'surfacegears', gl, p.zs) end
        if left + vleft + #gl > 0 or mills_built < #p.mills then
            return ('mist generator: machines %d left, shaft axles %d left, windmills %d of %d'):format(left + #gl, vleft, mills_built, #p.mills)
        end
        p.phase = 'ready'
        S.builders(false, KEY)
    end
    if p.phase == 'ready' then
        local cur, need = power(p)
        if cur > 0 and cur >= need then p.phase = 'priming'
        else
            -- say what's really wrong: no wind, or a break in the drive train
            local mp = mill_power(p)
            if mp > 0 then
                return ('mist generator: built, but the pumps are not joined to the windmills (windmills make %d power, the pumps get %d of %d): a break in the axles or gears'):format(mp, cur, need)
            end
            return ('mist generator: built, the windmills are still (no wind right now; pumps need %d power)'):format(need)
        end
    end
    if p.phase == 'priming' then
        local w = water_inside(p)
        if w >= PRIME_WATER or (w >= 7 and mist_near(p) > 0) then
            local z = pond_zone(p)
            if z then dfhack.buildings.deconstruct(z) end
            p.phase = 'running'
            pcall(function() reqscript('dfai-projects').done('mist') end)
            dfhack.gui.showAnnouncement('The mist generator over the tavern is running.', COLOR_LIGHTCYAN, true)
            return ('mist generator: primed with %d/7 of water, running on its own'):format(w)
        end
        if not pond_zone(p) then
            dfhack.filesystem.mkdir_recursive(DIR)
            local f = io.open(DIR .. '/mist_pond.csv', 'w') f:write('#zone label(pond)\np{name="Mist Generator Priming Pond"}\n') f:close()
            dfhack.run_command_silent('quickfort', 'run', 'dfai-gen/mist_pond.csv', '-c', ('%d,%d,%d'):format(p.ring.x + POND[1], p.ring.y + POND[2], p.zc))
            local z = pond_zone(p)
            if z then z.spec_sub_flag.active = true end
        end
        return ('mist generator: priming, %d/7 of water in, the pond is open'):format(w)
    end
    if p.phase == 'running' then
        local w = water_inside(p)
        if w < 3 then p.phase = 'priming' end
        return ('mist generator: running over the tavern, %d/7 water, %d mist clouds'):format(w, mist_near(p))
    end
    return 'mist generator: ' .. tostring(p.phase)
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        if not s.plan then
            if #dfhack.units.getCitizens(true) < 20 then s.last = 'mist generator: waits for 20 citizens' return end
            local okp, pri = pcall(reqscript, 'dfai-priorities')
            if okp then
                local go, why = pri.allowed('mist')
                if not go then s.last = 'mist generator: on hold, ' .. tostring(why) return end
                if pri.no_water() then s.last = 'mist generator: waits, there is no water on the map to prime it with' return end
            end
            local p, why = find_site(s.keep_ring)
            if not p then s.last = 'mist generator: ' .. tostring(why) return end
            s.keep_ring = nil
            p.phase = 'dig'
            s.plan, s.box, s.tries = p, p.box, 0
            local r = p.ring
            pcall(function() reqscript('dfai-projects').add('mist', 'The Mist Generator', r.x, r.y, r.z, r.x + 7, r.y + 7, r.z + 1, true) end)
        end
        s.last = step(s)
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
elseif cmd == 'replan' then
    dfhack.timeout(1, 'ticks', function()
        local st = load()
        local old = st.plan
        st.plan, st.box = nil, nil
        st.keep_ring = old and old.ring   -- its chamber is already being dug: keep it
        save(st)
        if old and old.tunnel then
            local keep = {}
            local function undesignate(x, y, z)
                local f = dfhack.maps.getTileFlags(x, y, z)
                if f and f.dig ~= df.tile_dig_designation.No and shape(x, y, z) == Sh.WALL then f.dig = df.tile_dig_designation.No end
            end
            for i, t in ipairs(old.tunnel) do if i > 1 then undesignate(t[1], t[2], old.zc) end end
            for z = old.zc, old.zs - 1 do undesignate(old.stair[1], old.stair[2], z) end
        end
        tick()
    end)
    print('mist generator: replanning')
elseif cmd == 'repair-check' then
    -- dry run of the drive-axle repair for the current plan
    local p = (load() or {}).plan
    if not p then print('no plan') return end
    print(repair_inlet(p, true) or 'the tunnel does not cross the ring: nothing to repair')
elseif cmd == 'missing' then
    -- which machine cells aren't built yet, and what's on each tile
    local p = (load() or {}).plan
    if not p or not p.ring then print('no plan') return end
    for _, c in ipairs(cells_machines(p)) do
        if not cell_built(c, p.zc) then
            local b = dfhack.buildings.findAtTile(xyz2pos(c[1], c[2], p.zc))
            local a = df.tiletype.attrs[dfhack.maps.getTileType(c[1], c[2], p.zc)]
            print(('%s at %d,%d,%d: tile %s/%s, building %s'):format(c[3], c[1], c[2], p.zc, df.tiletype_shape[a.shape], df.tiletype_material[a.material],
                b and (df.building_type[b:getType()] .. ' stage ' .. b:getBuildStage() .. '/' .. b:getMaxBuildStage()) or 'none'))
        end
    end
elseif cmd == 'find' then
    local p, why = find_site()
    if not p then print('no site: ' .. tostring(why)) return end
    print(('ring over the tavern at %d,%d level %d (chamber level %d, tavern traffic %d)'):format(p.ring.x, p.ring.y, p.ring.z, p.zc, p.ring.feet))
    print(('shaft at %d,%d from level %d up to the surface at %d (%d vertical axles), stair beside it at %d,%d'):format(p.shaft[1], p.shaft[2], p.zc, p.zs, p.zs - p.zc - 1, p.stair[1], p.stair[2]))
    print(('tunnel %d tiles; %d windmills at level %d from %d,%d; power needed about %d'):format(#p.tunnel, #p.mills, p.zs, p.mills[1][1], p.mills[1][2], p.need or 0))
    local keys = {}
    for _, c in ipairs(cells_machines(p)) do keys[#keys + 1] = c[3] end
    print('chamber + tunnel machines: ' .. table.concat(keys, ' '))
    print('dig (dry run): ' .. place('dig', 'dig', cells_dig(p), p.zc, 'dry'):gsub('%s+', ' '))
    print('tavern stair (dry run): ' .. place('build', 'tavernstair', {{p.ring.x + STAIR[1], p.ring.y + STAIR[2], 'Cu'}}, p.ring.z, 'dry'):gsub('%s+', ' '))
    print('machines (dry run, before the chamber is dug): ' .. place('build', 'machines', cells_machines(p), p.zc, 'dry'):gsub('%s+', ' '))
else
    print(status())
end
