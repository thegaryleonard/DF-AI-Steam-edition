-- dfai-mist-keeper: keep a pump-ring mist generator primed.
-- The ring's open corners let sunlight in, and the thin water that lands under
-- them evaporates; the loop slowly dries out (28 units -> 7 in half an hour).
-- Every CHECK_FRAMES this tops the water back up under the pump intakes when
-- the ring holds less than LOW units. (Spawning water is a small cheat; a
-- bucket-filled pond zone does the same in a normal fort.)
--   dfai-mist-keeper start | stop | status
local CHECK_FRAMES = 2000
local LOW = 21

mistkeeper = rawget(_G, 'dfai_mistkeeper') or {running = false, added = 0, last = nil}
rawset(_G, 'dfai_mistkeeper', mistkeeper)

local function intake(b)
    local d = b.direction
    if d == df.screw_pump_direction.FromWest then return b.x1, b.centery end
    if d == df.screw_pump_direction.FromEast then return b.x2, b.centery end
    if d == df.screw_pump_direction.FromNorth then return b.centerx, b.y1 end
    return b.centerx, b.y2
end

local function check()
    local pumps, z = {}, nil
    for _, b in ipairs(df.global.world.buildings.other.SCREW_PUMP) do
        if b:getBuildStage() == b:getMaxBuildStage() and (not z or b.z == z) then
            z = b.z
            pumps[#pumps + 1] = b
        end
    end
    if #pumps < 3 then return 'no pump ring' end
    local x1, y1, x2, y2 = 1e9, 1e9, -1e9, -1e9
    for _, b in ipairs(pumps) do
        x1, y1 = math.min(x1, b.x1), math.min(y1, b.y1)
        x2, y2 = math.max(x2, b.x2), math.max(y2, b.y2)
    end
    local water = 0
    for x = x1 - 2, x2 + 2 do
        for y = y1 - 2, y2 + 2 do
            for zz = z - 1, z do
                local f = dfhack.maps.getTileFlags(x, y, zz)
                if f and f.liquid_type == df.tile_liquid.Water then water = water + f.flow_size end
            end
        end
    end
    if water >= LOW then return ('ring holds %d water'):format(water) end
    local added = 0
    for _, b in ipairs(pumps) do
        local ix, iy = intake(b)
        local p = xyz2pos(ix, iy, z - 1)
        local f = dfhack.maps.getTileFlags(p)
        if f and f.flow_size < 7 and f.liquid_type ~= df.tile_liquid.Magma then
            added = added + (7 - f.flow_size)
            f.liquid_type = df.tile_liquid.Water
            f.flow_size = 7
            dfhack.maps.enableBlockUpdates(dfhack.maps.getTileBlock(p), true, true)
        end
    end
    mistkeeper.added = mistkeeper.added + added
    return ('ring was low (%d); added %d water'):format(water, added)
end

local function tick()
    if not mistkeeper.running then return end
    dfhack.timeout(CHECK_FRAMES, 'frames', tick)
    if not dfhack.isMapLoaded() then return end
    local ok, msg = pcall(check)
    mistkeeper.last = ok and msg or ('error: ' .. tostring(msg))
end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    if not mistkeeper.running then mistkeeper.running = true; tick() end
    print('dfai-mist-keeper: running; ' .. tostring(mistkeeper.last))
elseif cmd == 'stop' then
    mistkeeper.running = false
    print('dfai-mist-keeper: stopped')
elseif cmd == 'now' then
    print(check())
else
    print(('dfai-mist-keeper: %s; last: %s; water added so far: %d'):format(mistkeeper.running and 'running' or 'stopped', tostring(mistkeeper.last), mistkeeper.added))
end
