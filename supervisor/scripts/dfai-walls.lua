-- dfai-walls: an exterior curtain wall round the fort's front yard, for any
-- fort (user: big projects - "exterior walls and things like that"; "be
-- creative and dont make anything for one specific fort").
--
-- A square ring of constructed walls round the fort entrance, sized so it cuts
-- through as little as possible (no buildings, no other projects, few trees).
-- It follows the ground: where the land steps up the wall is built on the
-- higher ground, where it drops the wall goes on the low ground; natural rock
-- already counts as wall. Trees on the line are felled first.
-- The gate: a 3-wide opening (wagons fit) on the side facing the nearest map
-- edge, where invaders come from - so the bolt-thrower bunkers, which also
-- face that edge, cover it. The gate's two posts are fortifications, so
-- marksdwarves inside can shoot through them.
-- Waits on the Overseer's priority list ("walls"); placed a few dozen
-- segments at a time so the masons aren't swamped.
--   dfai-walls start | status | find (dry run) | now
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-walls'
local S = reqscript('dfai-surface')

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

-- the ground at x,y near level z: the level a walker stands on, or nil
-- (cliff faces, water, the unknown)
local function ground(x, y, z)
    -- the outdoor walking surface nearest the gate's level: on a hill that's
    -- the hilltop (walkers cross it), in a hollow the low ground
    local A = df.tiletype_shape
    local rock = false
    for _, dz in ipairs({0, 1, -1, 2, -2, 3, -3}) do
        local a = S.attrs(x, y, z + dz)
        if a then
            local sh = a.shape
            local f = dfhack.maps.getTileFlags(x, y, z + dz)
            if f.outside and not f.hidden and f.flow_size == 0 and a.material ~= df.tiletype_material.TREE
                and (sh == A.FLOOR or sh == A.PEBBLES or sh == A.SHRUB or sh == A.SAPLING or sh == A.TWIG or sh == A.BOULDER or sh == A.RAMP) then
                local below = S.attrs(x, y, z + dz - 1)
                if (sh == A.RAMP or (below and below.shape ~= A.EMPTY)) and S.walkable(x, y, z + dz) then return z + dz, a end
            end
            if dz == 0 and sh == A.WALL and a.material ~= df.tiletype_material.TREE then rock = true end
        end
    end
    -- no surface within three levels: a mountain face is already a wall
    if rock then return nil, 'rock' end
end

-- the ring's tiles for half-size r around the gate
local function ring_tiles(e, r)
    local mx, my = dfhack.maps.getTileSize()
    local x1, y1, x2, y2 = math.max(3, e.x - r), math.max(3, e.y - r), math.min(mx - 4, e.x + r), math.min(my - 4, e.y + r)
    local t = {}
    for x = x1, x2 do t[#t + 1] = {x, y1, 'N'} t[#t + 1] = {x, y2, 'S'} end
    for y = y1 + 1, y2 - 1 do t[#t + 1] = {x1, y, 'W'} t[#t + 1] = {x2, y, 'E'} end
    return t, {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end

-- how good a ring is: (lower is better) tiles that can't take a wall
local function score(e, r, res)
    local tiles, box = ring_tiles(e, r)
    local bad, trees = 0, 0
    for _, b in ipairs(res.boxes) do   -- never cut through a project or bunker
        local cut = b.x1 <= box.x2 and b.x2 >= box.x1 and b.y1 <= box.y2 and b.y2 >= box.y1
            and not (b.x1 > box.x1 and b.x2 < box.x2 and b.y1 > box.y1 and b.y2 < box.y2)
        if cut and math.abs(b.z1 - e.z) <= 4 then return math.huge end
    end
    for _, t in ipairs(tiles) do
        local g = ground(t[1], t[2], e.z)
        if g then
            if dfhack.buildings.findAtTile(xyz2pos(t[1], t[2], g)) then bad = bad + 5 end
        else
            local a = S.attrs(t[1], t[2], e.z)
            if a and a.material == df.tiletype_material.TREE then trees = trees + 1 end
        end
    end
    return bad + trees, tiles, box
end

function plan_ring()
    local e = S.entrance()
    if not e then return nil, 'no fort entrance known yet' end
    local res = S.reserved()
    res.ring = {}
    local best
    for r = 10, 22 do
        local sc, tiles, box = score(e, r, res)
        if sc < math.huge and (not best or sc < best.score) then best = {score = sc, r = r, tiles = tiles, box = box} end
    end
    if not best then return nil, 'every ring would cut through a building or project' end
    -- the gate: middle of the side facing the nearest map edge
    local mx, my = dfhack.maps.getTileSize()
    local d = {N = e.y, S = my - 1 - e.y, W = e.x, E = mx - 1 - e.x}
    local side = 'N'
    for k, v in pairs(d) do if v < d[side] then side = k end end
    -- 3 neighbouring tiles on one side, all walkable, with walkable ground
    -- just outside and just inside that leads back to the fort, closest to the
    -- middle of the side; sides tried nearest map edge first
    local cit = dfhack.units.getCitizens(true)[1]
    local function gate_on(sd)
        local key = (sd == 'N' or sd == 'S') and 1 or 2
        local mid = key == 1 and e.x or e.y
        local out = ({N = {0, -1}, S = {0, 1}, W = {-1, 0}, E = {1, 0}})[sd]
        local along = {}
        for _, t in ipairs(best.tiles) do if t[3] == sd then along[#along + 1] = t end end
        local onside = {}
        for _, t in ipairs(along) do onside[t[1] * 10000 + t[2]] = true end
        table.sort(along, function(a, b) return math.abs(a[key] - mid) < math.abs(b[key] - mid) end)
        for _, t in ipairs(along) do
            local ok = true
            for o = -1, 1 do
                local x, y = t[1], t[2]
                if key == 1 then x = x + o else y = y + o end
                local g = ground(x, y, e.z)
                if not onside[x * 10000 + y] or not g then ok = false break end
                local go, gi = ground(x + out[1], y + out[2], g), ground(x - out[1], y - out[2], g)
                if not go or not gi then ok = false break end
                if o == 0 and cit and not dfhack.maps.canWalkBetween(cit.pos, xyz2pos(x - out[1], y - out[2], gi)) then ok = false break end
            end
            if ok then return t, key end
        end
    end
    local sides = {'N', 'S', 'W', 'E'}
    table.sort(sides, function(a, b) return d[a] < d[b] end)
    local gate, key
    for _, sd in ipairs(sides) do
        gate, key = gate_on(sd)
        if gate then side = sd break end
    end
    if not gate then return nil, 'no walkable spot for a gate on any side' end
    local ring = {}
    for _, t in ipairs(best.tiles) do
        local o = key == 1 and (t[1] - gate[1]) or (t[2] - gate[2])
        local kind = 'wall'
        if t[3] == side and math.abs(o) <= 1 then kind = 'gate'
        elseif t[3] == side and math.abs(o) == 2 then kind = 'post' end
        ring[#ring + 1] = {t[1], t[2], kind}
    end
    return {ring = ring, box = best.box, gate = {gate[1], gate[2]}, side = side, z = e.z, r = best.r}
end

local function is_wall_now(x, y, g)
    local a = S.attrs(x, y, g)
    return a and (a.shape == df.tiletype_shape.WALL or a.shape == df.tiletype_shape.FORTIFICATION)
end

-- one pass: place up to 'budget' segments, fell trees in the way; returns
-- done, total, gaps
local function work(s, budget)
    -- walls placed where nobody can stand beside them never get built and
    -- keep their blocks: take them down, the tile finds real ground instead
    local b = s.box
    if b then s.dropped = (s.dropped or 0) + S.drop_unreachable(b.x1, b.y1, b.x2, b.y2, s.z - 3, s.z + 3) end
    local done, total, gaps, placed, holes = 0, 0, 0, 0, 0
    for _, t in ipairs(s.ring) do
        local x, y, kind = t[1], t[2], t[3]
        if kind ~= 'gate' then
            total = total + 1
            local g, why = ground(x, y, s.z)
            if why == 'rock' or (g and is_wall_now(x, y, g)) then
                done = done + 1
            elseif not g then
                local a = S.attrs(x, y, s.z)
                if a and a.material == df.tiletype_material.TREE and placed < budget then
                    -- fell it: the wall goes in once it's down
                    local des, occ = dfhack.maps.getTileFlags(x, y, s.z)
                    if des and des.dig == df.tile_dig_designation.No then
                        des.dig = df.tile_dig_designation.Default
                        dfhack.maps.getTileBlock(x, y, s.z).flags.designated = true
                        placed = placed + 1
                    end
                    gaps = gaps + 1
                else
                    holes = holes + 1   -- cliff or water: nothing to stand a wall on
                end
            elseif not dfhack.buildings.findAtTile(xyz2pos(x, y, g)) and placed < budget and S.reachable_beside(x, y, g) then
                local sub = kind == 'post' and df.construction_type.Fortification or df.construction_type.Wall
                if pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = sub, pos = xyz2pos(x, y, g)}) then
                    placed = placed + 1
                end
            end
        end
    end
    return done, total, gaps, holes
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        if not s.ring then
            if #dfhack.units.getCitizens(true) < 20 then s.last = 'walls: wait for 20 citizens' return end
            local okp, pri = pcall(reqscript, 'dfai-priorities')
            if okp then
                local go, why = pri.allowed('walls')
                if not go then s.last = 'walls: on hold, ' .. tostring(why) return end
            end
            local p, why = plan_ring()
            if not p then s.last = 'walls: ' .. tostring(why) return end
            for k, v in pairs(p) do s[k] = v end
            pcall(function() reqscript('dfai-projects').add('walls', 'The Curtain Wall', p.box.x1, p.box.y1, p.z - 1, p.box.x2, p.box.y2, p.z + 1, true) end)
        end
        if s.finished then s.last = ('walls: standing, %d segments, gate on the %s side'):format(#s.ring - 3, s.side) return end
        S.builders(true, KEY)
        if not (pcall(function() return reqscript('dfai-yardwatch').holding() end) and reqscript('dfai-yardwatch').holding()) then dfhack.run_command_silent('unsuspend') end   -- not while the yard watch holds outdoor work
        local done, total, gaps, holes = work(s, 30)
        s.last = ('walls: %d of %d segments up%s, gate on the %s side'):format(done, total, gaps > 0 and (', ' .. gaps .. ' waiting on trees to be felled') or '', s.side)
        if done + holes >= total then
            s.finished = true
            S.builders(false, KEY)
            pcall(function() reqscript('dfai-projects').done('walls') end)
            dfhack.gui.showAnnouncement('The curtain wall is finished.', COLOR_LIGHTGREEN, true)
        end
    end)
    if not ok then s.last = 'walls error: ' .. tostring(err) end
    save(s)
end

function status() return load().last or 'walls: idle' end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('walls: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('walls: queued')
elseif cmd == 'find' then
    local p, why = plan_ring()
    if not p then print('no ring: ' .. tostring(why)) return end
    local n = {wall = 0, post = 0, gate = 0, rock = 0, tree = 0, cliff = 0, levels = {}}
    for _, t in ipairs(p.ring) do
        local g, w = ground(t[1], t[2], p.z)
        if w == 'rock' then n.rock = n.rock + 1
        elseif not g then
            local a = S.attrs(t[1], t[2], p.z)
            if a and a.material == df.tiletype_material.TREE then n.tree = n.tree + 1 else n.cliff = n.cliff + 1 end
        else n[t[3]] = n[t[3]] + 1 n.levels[g - p.z] = (n.levels[g - p.z] or 0) + 1 end
    end
    local lv = {} for k, v in pairs(n.levels) do lv[#lv + 1] = ('%+d:%d'):format(k, v) end
    print(('ring %d,%d..%d,%d (half-size %d), gate at %d,%d on the %s side'):format(p.box.x1, p.box.y1, p.box.x2, p.box.y2, p.r, p.gate[1], p.gate[2], p.side))
    print(('walls %d, gate posts %d, gate gap %d, natural rock %d, trees to fell %d, no ground %d; wall levels vs gate %s'):format(n.wall, n.post, n.gate, n.rock, n.tree, n.cliff, table.concat(lv, ' ')))
else
    print(status())
end
