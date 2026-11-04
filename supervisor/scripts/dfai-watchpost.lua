-- dfai-watchpost: a roof over the fort entrance with bolt throwers on top, the
-- fort's watch post for fliers and anything coming at the gate (user: "modify
-- the entrance to have a roof and bolt throwers up top and thats the 'watch
-- post' for flyers and such"). Guard duty (dfai-guard) stations squads up here.
--
-- The roof (constructed floor, one level over the entrance yard, 7x7) goes
-- up one ring at a time from whatever already holds it (the hillside, a
-- bunker roof next to it): a roof tile is only placed beside a tile that is
-- already solid, so nothing is ever built unsupported (a floating floor
-- finished first would come down on whoever is below). A built stair in the
-- yard takes builders, the guards and the operators up. Then four bolt
-- throwers on the roof's edges, facing N, E, S and W, firing at enemies only.
--   dfai-watchpost start | status | find
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-watchpost'
local R = 3   -- the roof reaches R tiles out from the entrance

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end
local function shape(x, y, z) local a = attrs(x, y, z) return a and a.shape end
local S = df.tiletype_shape

local function entrance()
    local ok, d = pcall(require('json').decode_file, dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json')
    if ok and type(d) == 'table' and d.site_id == df.global.plotinfo.site_id then
        for _, p in ipairs(d.pois or {}) do if p.kind == 'Entrance' then return p end end
    end
end

-- solid enough to hold a roof tile beside it: a wall, or a floor that is
-- itself held (natural ground, a constructed floor, a stair top)
local function holds(x, y, z)
    local a = attrs(x, y, z)
    if not a then return false end
    if a.shape == S.WALL or a.shape == S.FORTIFICATION then return true end
    if a.shape == S.FLOOR or a.shape == S.STAIR_DOWN or a.shape == S.STAIR_UPDOWN or a.shape == S.RAMP_TOP then
        return a.material == df.tiletype_material.CONSTRUCTION or shape(x, y, z - 1) == S.WALL
    end
    return false
end

-- the plan for this entrance: the roof box, the stair tile, the engine tiles
local function plan(e)
    local p = {x1 = e.x - R, y1 = e.y - R, x2 = e.x + R, y2 = e.y + R, z = e.z, roof = e.z + 1}
    -- the stair: a free floor tile in the yard (not one of the fort's own stairs)
    for _, d in ipairs({{2, 0}, {-2, 0}, {0, 2}, {0, -2}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}) do
        local x, y = e.x + d[1], e.y + d[2]
        if shape(x, y, e.z) == S.FLOOR and not dfhack.buildings.findAtTile(xyz2pos(x, y, e.z))
            and (shape(x, y, e.z + 1) == S.EMPTY or shape(x, y, e.z + 1) == S.STAIR_DOWN) then
            p.sx, p.sy = x, y
            break
        end
    end
    if not p.sx then return nil, 'no free floor in the entrance yard for a stair' end
    p.engines = {
        {x = e.x, y = e.y - R, face = 0, name = 'N'}, {x = e.x + R, y = e.y, face = 2, name = 'E'},
        {x = e.x, y = e.y + R, face = 4, name = 'S'}, {x = e.x - R, y = e.y, face = 6, name = 'W'},
    }
    return p
end

local function parts_free()
    local n = 0
    for _, i in ipairs(df.global.world.items.other.BOLT_THROWER_PARTS or {}) do
        if not i.flags.in_building and not i.flags.forbid and not i.flags.in_job then n = n + 1 end
    end
    return n
end
local function orders_for(jt)
    local n = 0
    for _, mo in ipairs(df.global.world.manager_orders.all) do if mo.job_type == jt then n = n + mo.amount_left end end
    return n
end
local function engine_at(x, y, z)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    if b and b:getType() == df.building_type.SiegeEngine then return b end
end

local function step(s)
    local e = entrance()
    if not e then return 'no fort entrance known yet' end
    if not s.plan or s.plan.ex ~= e.x or s.plan.ey ~= e.y then
        local p, why = plan(e)
        if not p then return 'waiting: ' .. why end
        p.ex, p.ey = e.x, e.y
        s.plan = p
    end
    local p = s.plan
    -- parts for the four engines, from the start
    dfhack.run_command_silent('autolabor', 'SIEGECRAFT', '1', '3')
    local built = 0
    for _, g in ipairs(p.engines) do if engine_at(g.x, g.y, p.roof) then built = built + 1 end end
    local want = #p.engines - built
    if want > 0 and parts_free() + orders_for(df.job_type.ConstructBoltThrowerParts) < want then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructBoltThrowerParts","amount_total":%d,"material_category":["wood"]}')
            :format(want - parts_free() - orders_for(df.job_type.ConstructBoltThrowerParts)))
    end
    -- the stair
    local lo, hi = shape(p.sx, p.sy, p.z), shape(p.sx, p.sy, p.roof)
    if not (lo == S.STAIR_UP or lo == S.STAIR_UPDOWN) then
        if not dfhack.buildings.findAtTile(xyz2pos(p.sx, p.sy, p.z)) then
            dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.UpStair, pos = xyz2pos(p.sx, p.sy, p.z)}
        end
        return 'building the stair up from the entrance yard'
    end
    if not (hi == S.STAIR_DOWN or hi == S.STAIR_UPDOWN) then
        if not dfhack.buildings.findAtTile(xyz2pos(p.sx, p.sy, p.roof)) then
            dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.DownStair, pos = xyz2pos(p.sx, p.sy, p.roof)}
        end
        return 'building the top of the stair'
    end
    -- the roof, a ring at a time from what holds it
    local left, placed = 0, 0
    for x = p.x1, p.x2 do for y = p.y1, p.y2 do
        if not (x == p.sx and y == p.sy) and shape(x, y, p.roof) == S.EMPTY then
            left = left + 1
            if not dfhack.buildings.findAtTile(xyz2pos(x, y, p.roof)) then
                local held = false
                for dx = -1, 1 do for dy = -1, 1 do
                    if (dx ~= 0 or dy ~= 0) and holds(x + dx, y + dy, p.roof) then held = true end
                end end
                if held and placed < 12 then
                    if dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = df.construction_type.Floor, pos = xyz2pos(x, y, p.roof)} then
                        placed = placed + 1
                    end
                end
            end
        end
    end end
    if left > 0 then return ('roofing the entrance: %d tiles to go'):format(left) end
    -- the engines on the roof's edges
    local waiting = 0
    for _, g in ipairs(p.engines) do
        local b = engine_at(g.x, g.y, p.roof)
        if not b then
            if parts_free() > 0 then
                dfhack.buildings.constructBuilding{type = df.building_type.SiegeEngine, subtype = df.siegeengine_type.BoltThrower,
                    pos = xyz2pos(g.x, g.y, p.roof), width = 1, height = 1}
            end
            waiting = waiting + 1
        elseif b:getBuildStage() < b:getMaxBuildStage() then
            waiting = waiting + 1
        elseif not s['armed_' .. g.name] then
            local face = g.face
            dfhack.timeout(1, 'ticks', function()
                b.facing, b.resting_orientation = face, face
                b.action = df.siegeengine_action.FireAtWill   -- enemies only; metal bolts are for killing
            end)
            s['armed_' .. g.name] = true
        end
    end
    if waiting > 0 then return ('roof done; %d of 4 bolt throwers still to build'):format(waiting) end
    dfhack.run_command_silent('autolabor', 'SIEGEOPERATE', '2', '6')
    if not s.announced then
        s.announced = true
        dfhack.gui.showAnnouncement('The watch post over the fort entrance is ready: four bolt throwers on its roof.', COLOR_LIGHTGREEN, true)
    end
    return 'ready: roof over the entrance, four bolt throwers on top'
end

-- where the guards stand: the middle of the roof
function posts()
    local s = load()
    if s.plan and s.plan.ex and shape(s.plan.ex, s.plan.ey, s.plan.roof) == S.FLOOR then
        return {{s.plan.ex, s.plan.ey, s.plan.roof}}
    end
    return {}
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, msg = pcall(step, s)
    s.last = ok and msg or ('error: ' .. tostring(msg))
    save(s)
end

function status() return 'watch post: ' .. (load().last or 'idle') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('watch post: watching')
elseif cmd == 'find' then
    local e = entrance()
    if not e then print('no fort entrance known') return end
    local p, why = plan(e)
    if not p then print('no: ' .. why) return end
    print(('roof %d,%d..%d,%d on level %d; stair at %d,%d; engines at %s'):format(p.x1, p.y1, p.x2, p.y2, p.roof, p.sx, p.sy,
        table.concat((function() local t = {} for _, g in ipairs(p.engines) do t[#t + 1] = ('%s %d,%d'):format(g.name, g.x, g.y) end return t end)(), ', ')))
else
    print(status())
end
