-- aiscan-designs: find player-built water/mist machinery and garbage dumps in the loaded fort
-- and dump each one as an exact per-tile map. Read-only: changes nothing in the game.
-- usage: aiscan-designs <output_dir>
local args = {...}
local outdir = args[1] or '.'
local json = require('json')

local B = df.building_type
local MACHINE = {
    [B.ScrewPump] = 'P', [B.Floodgate] = 'G', [B.GrateWall] = 'g', [B.GrateFloor] = 'g',
    [B.BarsVertical] = '=', [B.BarsFloor] = '=', [B.Hatch] = 'H', [B.GearAssembly] = '*',
    [B.AxleHorizontal] = '-', [B.AxleVertical] = '|', [B.WaterWheel] = 'W', [B.Windmill] = 'M',
    [B.Rollers] = 'R', [B.Well] = 'O', [B.Bridge] = 'B',
}
local OTHER = {
    [B.Door] = 'D', [B.Table] = 't', [B.Chair] = 'c', [B.Bed] = 'b', [B.Statue] = 's',
    [B.Workshop] = 'w', [B.Furnace] = 'f', [B.Stockpile] = nil, [B.Coffin] = 'C',
    [B.Cabinet] = 'k', [B.Box] = 'x', [B.Trap] = 'T', [B.Support] = 'S',
}

local function trap_char(b)
    if b.trap_type == df.trap_type.Lever then return 'L' end
    if b.trap_type == df.trap_type.PressurePlate then return '_' end
    return 'T'
end

local function bchar(b)
    local t = b:getType()
    if t == B.Trap then return trap_char(b) end
    return MACHINE[t] or OTHER[t]
end

-- 1. seeds: machinery buildings, mist flows, garbage dump zones
local seeds = {}
for _, b in ipairs(df.global.world.buildings.all) do
    local t = b:getType()
    if MACHINE[t] and t ~= B.Well and t ~= B.Bridge then
        table.insert(seeds, {x=b.centerx, y=b.centery, z=b.z, why=df.building_type[t]})
    elseif t == B.Trap and b.trap_type == df.trap_type.Lever then
        table.insert(seeds, {x=b.centerx, y=b.centery, z=b.z, why='Lever', weak=true})
    elseif t == B.Civzone and b.type == df.civzone_type.Dump then
        table.insert(seeds, {x=b.centerx, y=b.centery, z=b.z, why='GarbageDump', x1=b.x1, x2=b.x2, y1=b.y1, y2=b.y2})
    end
end
local mist = 0
for _, f in ipairs(df.global.flows) do
    if f.type == df.flow_type.Mist and f.density > 0 then
        mist = mist + 1
        table.insert(seeds, {x=f.pos.x, y=f.pos.y, z=f.pos.z, why='MistFlow'})
    end
end

-- 2. cluster seeds that are close together (machines of one device)
local R = 8
local clusters = {}
for _, s in ipairs(seeds) do
    local hit
    for _, c in ipairs(clusters) do
        if s.x >= c.x1 - R and s.x <= c.x2 + R and s.y >= c.y1 - R and s.y <= c.y2 + R and s.z >= c.z1 - 3 and s.z <= c.z2 + 3 then
            hit = c; break
        end
    end
    if not hit then
        hit = {x1=s.x, x2=s.x, y1=s.y, y2=s.y, z1=s.z, z2=s.z, why={}}
        table.insert(clusters, hit)
    end
    hit.x1 = math.min(hit.x1, s.x1 or s.x); hit.x2 = math.max(hit.x2, s.x2 or s.x)
    hit.y1 = math.min(hit.y1, s.y1 or s.y); hit.y2 = math.max(hit.y2, s.y2 or s.y)
    hit.z1 = math.min(hit.z1, s.z); hit.z2 = math.max(hit.z2, s.z)
    hit.why[s.why] = (hit.why[s.why] or 0) + 1
end

-- 3. dump each cluster (padded) tile by tile
local mx, my, mz = df.global.world.map.x_count, df.global.world.map.y_count, df.global.world.map.z_count
local function shape_char(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return '?' end
    local shape = df.tiletype.attrs[tt].shape
    local mat = df.tiletype.attrs[tt].material
    local S = df.tiletype_shape
    if shape == S.WALL then
        if mat == df.tiletype_material.CONSTRUCTION then return 'C' end
        return '#'
    elseif shape == S.FORTIFICATION then return '%'
    elseif shape == S.EMPTY or shape == S.NONE then return ' '
    elseif shape == S.RAMP then return '^'
    elseif shape == S.RAMP_TOP then return 'v'
    elseif shape == S.STAIR_UP then return '<'
    elseif shape == S.STAIR_DOWN then return '>'
    elseif shape == S.STAIR_UPDOWN then return 'X'
    elseif shape == S.BROOK_BED or shape == S.BROOK_TOP then return '~'
    elseif shape == S.TREE or shape == S.TRUNK_BRANCH or shape == S.BRANCH or shape == S.TWIG then return 'Y'
    end
    return '.'
end

local results = {map={x=mx, y=my, z=mz}, mist_flows=mist, save=df.global.world.cur_savegame.save_dir,
                 year=df.global.cur_year, clusters={}}
for i, c in ipairs(clusters) do
    local strong = false
    for k, _ in pairs(c.why) do if k ~= 'Lever' then strong = true end end
    if strong then
        local P = 6
        local x1, x2 = math.max(0, c.x1 - P), math.min(mx - 1, c.x2 + P)
        local y1, y2 = math.max(0, c.y1 - P), math.min(my - 1, c.y2 + P)
        local z1, z2 = math.max(0, c.z1 - 2), math.min(mz - 1, c.z2 + 2)
        if (x2 - x1) <= 120 and (y2 - y1) <= 120 then
            local layers = {}
            local water_tiles, magma_tiles = 0, 0
            for z = z2, z1, -1 do
                local rows = {}
                for y = y1, y2 do
                    local row = {}
                    for x = x1, x2 do
                        local ch = shape_char(x, y, z)
                        local d = dfhack.maps.getTileFlags(x, y, z)
                        if d and d.flow_size > 0 then
                            if d.liquid_type == df.tile_liquid.Magma then
                                ch = string.char(string.byte('a') + d.flow_size - 1); magma_tiles = magma_tiles + 1
                            else
                                ch = tostring(d.flow_size); water_tiles = water_tiles + 1
                            end
                        end
                        local bld = dfhack.buildings.findAtTile(x, y, z)
                        if bld then
                            local bc = bchar(bld)
                            if bc then ch = bc end
                        end
                        table.insert(row, ch)
                    end
                    table.insert(rows, table.concat(row))
                end
                table.insert(layers, {z=z, rows=rows})
            end
            -- buildings with their links (levers -> targets) and pump directions
            local blds = {}
            for _, b in ipairs(df.global.world.buildings.all) do
                if b.z >= z1 and b.z <= z2 and b.centerx >= x1 and b.centerx <= x2 and b.centery >= y1 and b.centery <= y2 then
                    local t = b:getType()
                    if MACHINE[t] or t == B.Trap or t == B.Door or t == B.Civzone then
                        local e = {type=df.building_type[t], id=b.id, x1=b.x1 - x1, y1=b.y1 - y1, x2=b.x2 - x1, y2=b.y2 - y1, z=b.z}
                        if t == B.ScrewPump then e.direction = df.screw_pump_direction[b.direction] end
                        if t == B.Civzone then e.zone = df.civzone_type[b.type] end
                        if t == B.Trap then
                            e.trap = df.trap_type[b.trap_type]
                            e.targets = {}
                                                        for _, ref in ipairs(b.general_refs) do
                                if df.general_ref_building_triggertargetst:is_instance(ref) then
                                    local tb = df.building.find(ref.building_id)
                                    if tb then table.insert(e.targets, {id=tb.id, type=df.building_type[tb:getType()], x=tb.centerx - x1, y=tb.centery - y1, z=tb.z}) end
                                end
                            end
                        end
                        if t == B.Floodgate or t == B.Hatch or t == B.GrateFloor or t == B.GrateWall or t == B.BarsFloor or t == B.BarsVertical or t == B.Door then
                            for _, fld in ipairs({'gate_flags', 'door_flags'}) do
                                local ok, v = pcall(function() return b[fld] end)
                                if ok and v then e.closed = v.closed end
                            end
                        end
                        table.insert(blds, e)
                    end
                end
            end
            table.insert(results.clusters, {id=i, why=c.why, origin={x=x1, y=y1, z=z1}, size={x=x2 - x1 + 1, y=y2 - y1 + 1, z=z2 - z1 + 1},
                                            water_tiles=water_tiles, magma_tiles=magma_tiles, layers=layers, buildings=blds})
        end
    end
end
local name = (df.global.world.cur_savegame.save_dir or 'unknown'):gsub('[^%w%-_]', '_')
local f = io.open(outdir .. '/' .. name .. '.json', 'w')
f:write(json.encode(results))
f:close()
print(('aiscan-designs: %s year %d, %d seeds, %d clusters dumped, %d mist flows -> %s/%s.json'):format(
    results.save, results.year, #seeds, #results.clusters, mist, outdir, name))
