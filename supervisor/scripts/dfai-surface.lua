-- dfai-surface: shared ground rules for surface projects (bunkers, the mist
-- generator, the exterior wall) so they all pick their own spot near the gate
-- and never land on each other. Any fort, any map: nothing here is per-fort.
--@module = true

local json = require('json')

-- the fort entrance (dfai-poi writes it), or nil
function entrance()
    local ok, d = pcall(json.decode_file, dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json')
    if ok and type(d) == 'table' and d.site_id == df.global.plotinfo.site_id then
        for _, p in ipairs(d.pois or {}) do if p.kind == 'Entrance' then return p end end
    end
end

function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end

-- open ground a construction can go on (shrubs, pebbles and saplings get cleared)
-- the walkable area the fort's dwarves are in (a tile with another group
-- number can't be reached on foot: rooftops, ledges, the far side of a
-- chasm). Topcloister's curtain wall went on constructed floors three levels
-- up that nobody could reach: 106 walls waited for years.
local group_cache = {tick = -1, g = 0}
function fort_group()
    local t = df.global.cur_year_tick
    if group_cache.tick ~= t then
        local counts, best, bn = {}, 0, 0
        for i, u in ipairs(dfhack.units.getCitizens(true)) do
            if i > 30 then break end
            local g = dfhack.maps.getWalkableGroup(u.pos)
            if g ~= 0 then counts[g] = (counts[g] or 0) + 1 if counts[g] > bn then best, bn = g, counts[g] end end
        end
        group_cache.tick, group_cache.g = t, best
    end
    return group_cache.g
end
function walkable(x, y, z)
    local g = fort_group()
    return g ~= 0 and dfhack.maps.getWalkableGroup(xyz2pos(x, y, z)) == g
end
-- can a builder stand next to x,y,z (same level) to build there?
function reachable_beside(x, y, z)
    for dx = -1, 1 do for dy = -1, 1 do
        if (dx ~= 0 or dy ~= 0) and walkable(x + dx, y + dy, z) then return true end
    end end
    return false
end
-- unbuilt constructions/buildings nobody can get to: take them down so their
-- materials go back (they hold them forever otherwise). Returns how many.
-- only: optional set of tiles (x*10000+y) the caller placed; anything else is
-- left alone. Without it this took df-ai's own unbuilt stairs and floors and
-- the watch post's stair top too (154 at once at Cloisterbolt).
function drop_unreachable(x1, y1, x2, y2, z1, z2, only)
    -- collect first: deconstructing while walking buildings.all shrinks the
    -- vector under the loop ("index out of bounds"), which crashed every
    -- dfai-walls pass at Cloisterbolt for 187 days with the wall 40 short
    local drop = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Construction   -- only the walls these projects place, never df-ai's own rooms
            and b.z >= z1 and b.z <= z2 and b.x1 >= x1 and b.x1 <= x2 and b.y1 >= y1 and b.y1 <= y2
            and b:getBuildStage() < b:getMaxBuildStage() and not reachable_beside(b.x1, b.y1, b.z)
            and (not only or only[b.x1 * 10000 + b.y1]) then
            drop[#drop + 1] = b.id
        end
    end
    local n = 0
    for _, id in ipairs(drop) do
        local b = df.building.find(id)
        if b and pcall(dfhack.buildings.deconstruct, b) then n = n + 1 end
    end
    return n
end

function buildable(x, y, z)
    if not walkable(x, y, z) then return false end
    local a = attrs(x, y, z)
    if not a or a.material == df.tiletype_material.TREE then return false end
    local S = df.tiletype_shape
    if not (a.shape == S.FLOOR or a.shape == S.PEBBLES or a.shape == S.SHRUB or a.shape == S.SAPLING or a.shape == S.TWIG) then return false end
    local f = dfhack.maps.getTileFlags(x, y, z)
    if f.hidden or f.flow_size > 0 then return false end
    return not dfhack.buildings.findAtTile(xyz2pos(x, y, z))
end
function open_air(x, y, z)
    local a = attrs(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    return a and a.shape == df.tiletype_shape.EMPTY and f and f.outside
end

-- boxes already spoken for: every project box (dfai-projects), bunkers, and
-- the exterior wall's ring. reserved() reads them once; taken() tests a box.
function reserved()
    local boxes, ring = {}, {}
    local okp, P = pcall(reqscript, 'dfai-projects')
    for _, p in ipairs(okp and P.list() or {}) do
        if not p.done and p.x1 then
            boxes[#boxes + 1] = {x1 = math.min(p.x1, p.x2), x2 = math.max(p.x1, p.x2), y1 = math.min(p.y1, p.y2), y2 = math.max(p.y1, p.y2), z1 = math.min(p.z1, p.z2), z2 = math.max(p.z1, p.z2)}
        end
    end
    local bk = dfhack.persistent.getSiteData('dfai-bunker', {built = {}})
    for _, b in ipairs(bk.built or {}) do if b.z then boxes[#boxes + 1] = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z1 = b.z, z2 = b.z + 1} end end
    local c = bk.current
    if c and c.x1 and c.z then boxes[#boxes + 1] = {x1 = c.x1, y1 = c.y1, x2 = c.x2, y2 = c.y2, z1 = c.z, z2 = c.z + 1} end
    local mi = dfhack.persistent.getSiteData('dfai-mist', {})
    -- (only a planned generator's box: an old or half-written one has no level)
    if (mi.plan or mi.surface) and mi.box and mi.box.z then local b = mi.box boxes[#boxes + 1] = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z1 = b.z, z2 = b.z + 1} end
    local w = dfhack.persistent.getSiteData('dfai-walls', {})
    for _, t in ipairs(w.ring or {}) do ring[t[1] * 10000 + t[2]] = true end
    return {boxes = boxes, ring = ring}
end
function taken(x1, y1, x2, y2, z, margin, res)
    margin = margin or 2
    res = res or reserved()
    for _, b in ipairs(res.boxes) do
        if z >= b.z1 - 1 and z <= b.z2 + 1 and x1 <= b.x2 + margin and x2 >= b.x1 - margin and y1 <= b.y2 + margin and y2 >= b.y1 - margin then return true end
    end
    if next(res.ring) then
        for x = x1 - 1, x2 + 1 do for y = y1 - 1, y2 + 1 do if res.ring[x * 10000 + y] then return true end end end
    end
    return false
end

-- a w x h spot near the gate where every tile passes tile_ok(x, y, z), walking
-- out from the gate; nil, why if there's none
function find_near_gate(w, h, tile_ok, opts)
    opts = opts or {}
    local e = entrance()
    if not e then return nil, 'no fort entrance known yet' end
    local mx, my = dfhack.maps.getTileSize()
    local cit = dfhack.units.getCitizens(true)[1]
    local res = reserved()
    for _, dz in ipairs(opts.levels or {0, 1, -1, 2, -2}) do
        local z = e.z + dz
        for r = opts.min_dist or 4, opts.max_dist or 30 do
            -- every box whose centre is r tiles (chebyshev) from the gate
            local cands = {}
            for cx = e.x - r, e.x + r do cands[#cands + 1] = {cx, e.y - r} cands[#cands + 1] = {cx, e.y + r} end
            for cy = e.y - r + 1, e.y + r - 1 do cands[#cands + 1] = {e.x - r, cy} cands[#cands + 1] = {e.x + r, cy} end
            for _, c in ipairs(cands) do
                local x1, y1 = c[1] - w // 2, c[2] - h // 2
                local x2, y2 = x1 + w - 1, y1 + h - 1
                if x1 > 2 and y1 > 2 and x2 < mx - 3 and y2 < my - 3 and not taken(x1, y1, x2, y2, z, 2, res) then
                    local ok = true
                    for x = x1, x2 do
                        for y = y1, y2 do if not tile_ok(x, y, z, x - x1, y - y1) then ok = false break end end
                        if not ok then break end
                    end
                    if ok and cit then
                        -- walkable from the fort: some tile just outside the box
                        local reach = false
                        for _, p in ipairs({{x1 - 1, y1 + h // 2}, {x2 + 1, y1 + h // 2}, {x1 + w // 2, y1 - 1}, {x1 + w // 2, y2 + 1}}) do
                            if dfhack.maps.isValidTilePos(p[1], p[2], z) and dfhack.maps.canWalkBetween(cit.pos, xyz2pos(p[1], p[2], z)) then reach = true break end
                        end
                        ok = reach
                    end
                    if ok then return {x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z} end
                end
            end
        end
    end
    return nil, ('no open %dx%d ground near the gate'):format(w, h)
end

-- standing orders while a big build runs: enough builders that the walls don't
-- queue behind one dwarf (autolabor's minimum), handed back after
function builders(on, who)
    _G.dfai_surface_builders = _G.dfai_surface_builders or {}
    local B = _G.dfai_surface_builders
    B[who] = on or nil
    dfhack.run_command_silent('autolabor', 'BUILD_CONSTRUCTION', next(B) and '6' or '1', '200')
end

if dfhack_flags.module then return end
local e = entrance()
print(e and ('entrance %d,%d,%d'):format(e.x, e.y, e.z) or 'no entrance known')
