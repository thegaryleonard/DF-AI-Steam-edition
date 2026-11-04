-- dfai-gateturret: a bolt thrower on the curtain wall beside each gate
-- (user: "will need one for each fort wall gate"; the bunker's roof bolt
-- thrower shot down an agitated buzzard, so open-sky engines do engage fliers).
--
-- For each gate dfai-walls built: the wall a few tiles along from the gate's
-- post carries the engine on its top, facing out; a built stair just inside
-- the wall takes the operator up. Parts come from the siege workshop. Built by
-- the dwarves like everything else (no instant building).
--   dfai-gateturret start | status | find (where it would go)
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-gateturret'
local OUT = {N = {0, -1}, S = {0, 1}, W = {-1, 0}, E = {1, 0}}
local FACE = {N = 0, E = 2, S = 4, W = 6}

local function load() return dfhack.persistent.getSiteData(KEY, {gates = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end
local function shape(x, y, z) local a = attrs(x, y, z) return a and a.shape end

-- the gates of the curtain wall (one today; a list if dfai-walls grows more)
local function gates()
    local w = dfhack.persistent.getSiteData('dfai-walls', {})
    local list = {}
    for _, g in ipairs(w.gates or {}) do list[#list + 1] = g end
    if #list == 0 and w.gate and w.side then list[1] = {x = w.gate[1], y = w.gate[2], z = w.z, side = w.side} end
    return list
end

local function gate_key(g) return ('%d,%d,%d'):format(g.x, g.y, g.z) end

-- the engine's wall tile T (its top carries the engine) and the stair tile I
-- inside it, or nil and why
local function site(g)
    local o = OUT[g.side]
    if not o then return nil, 'unknown gate side' end
    local along = (g.side == 'N' or g.side == 'S') and {1, 0} or {0, 1}
    local S = df.tiletype_shape
    local why = 'no built wall beside the gate yet'
    for _, d in ipairs({-3, 3, -4, 4, -5, 5}) do
        local tx, ty = g.x + along[1] * d, g.y + along[2] * d
        local ix, iy = tx - o[1], ty - o[2]
        local wall = attrs(tx, ty, g.z)
        if wall and wall.shape == S.WALL then
            local top, inside, above = shape(tx, ty, g.z + 1), attrs(ix, iy, g.z), shape(ix, iy, g.z + 1)
            local ifree = not dfhack.buildings.findAtTile(xyz2pos(ix, iy, g.z))
            if top == S.FLOOR and inside and (inside.shape == S.FLOOR or inside.shape == S.STAIR_UP or inside.shape == S.STAIR_UPDOWN)
                and (above == S.EMPTY or above == S.STAIR_DOWN or above == S.STAIR_UPDOWN)
                and (ifree or inside.shape ~= S.FLOOR) then
                return {tx = tx, ty = ty, ix = ix, iy = iy, z = g.z}
            end
            why = 'no room for a stair inside the wall beside the gate'
        end
    end
    return nil, why
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
local function siege_workshop()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
        if b.type == df.workshop_type.Siege and b:getBuildStage() >= b:getMaxBuildStage() then return true end
    end
end

local function building_at(x, y, z, t)
    local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
    if b and b:getType() == t then return b end
end
local function construct(kind, x, y, z)
    if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return true end
    local b, err = dfhack.buildings.constructBuilding{type = df.building_type.Construction, subtype = kind, pos = xyz2pos(x, y, z)}
    return b ~= nil, err
end

local function step(s, g)
    local k = gate_key(g)
    local t = s.gates[k] or {phase = 'site'}
    s.gates[k] = t
    if t.phase == 'done' then
        local e = df.building.find(t.engine or -1)
        if e then return ('gate %s: bolt thrower on the wall, facing out'):format(g.side) end
        t.phase = 'engine'   -- gone (destroyed, deconstructed): build it again
    end
    if t.phase == 'site' then
        local p, why = site(g)
        if not p then return ('gate %s: waiting (%s)'):format(g.side, why) end
        t.tx, t.ty, t.ix, t.iy, t.z = p.tx, p.ty, p.ix, p.iy, p.z
        t.phase = 'stair'
    end
    -- parts while the stair goes in
    dfhack.run_command_silent('autolabor', 'SIEGECRAFT', '1', '3')
    if not siege_workshop() then
        if not s.ws_ordered then dfhack.run_command_silent('dfai-build', 'new', 'workshop-ws') s.ws_ordered = true end
    elseif t.phase ~= 'done' and parts_free() == 0 and orders_for(df.job_type.ConstructBoltThrowerParts) == 0 then
        dfhack.run_command_silent('workorder', '{"job":"ConstructBoltThrowerParts","amount_total":1,"material_category":["wood"]}')
    end
    local S = df.tiletype_shape
    -- the wall's top: walls here may be two levels high (a pillar on top)
    local top = t.z + 1
    while shape(t.tx, t.ty, top) == S.WALL and top < t.z + 4 do top = top + 1 end
    t.top = top
    if t.phase == 'stair' then
        -- a stair column just inside the wall from the ground to the top:
        -- up at the bottom, up/down between, down at the top
        for z = t.z, top do
            local want = z == t.z and df.construction_type.UpStair or z == top and df.construction_type.DownStair or df.construction_type.UpDownStair
            local ok_shape = z == t.z and {[S.STAIR_UP] = true, [S.STAIR_UPDOWN] = true}
                or z == top and {[S.STAIR_DOWN] = true, [S.STAIR_UPDOWN] = true} or {[S.STAIR_UPDOWN] = true}
            local sh = shape(t.ix, t.iy, z)
            if not ok_shape[sh] then
                if sh == S.STAIR_DOWN or sh == S.STAIR_UP then
                    -- the wrong kind (the wall grew a level): take it down first
                    dfhack.constructions.designateRemove(xyz2pos(t.ix, t.iy, z))
                    return ('gate %s: replacing a stair piece at level %d (the wall is %d high)'):format(g.side, z, top - t.z)
                end
                construct(want, t.ix, t.iy, z)
                return ('gate %s: building the stair up to the wall top (level %d of %d)'):format(g.side, z - t.z + 1, top - t.z + 1)
            end
        end
        t.phase = 'engine'
    end
    if t.phase == 'engine' then
        local e = building_at(t.tx, t.ty, top, df.building_type.SiegeEngine)
        if not e then
            if parts_free() == 0 then return ('gate %s: stair built; waiting for bolt thrower parts'):format(g.side) end
            local b, err = dfhack.buildings.constructBuilding{type = df.building_type.SiegeEngine,
                subtype = df.siegeengine_type.BoltThrower, pos = xyz2pos(t.tx, t.ty, top), width = 1, height = 1}
            if not b then return ('gate %s: cannot place the bolt thrower (%s)'):format(g.side, tostring(err)) end
            return ('gate %s: bolt thrower placed on the wall'):format(g.side)
        end
        if e:getBuildStage() < e:getMaxBuildStage() then return ('gate %s: bolt thrower being built'):format(g.side) end
        local face = FACE[g.side]
        dfhack.timeout(1, 'ticks', function()
            e.facing, e.resting_orientation = face, face
            e.action = df.siegeengine_action.FireAtWill   -- enemies only; metal bolts are for killing
        end)
        dfhack.run_command_silent('autolabor', 'SIEGEOPERATE', '2', '6')
        t.engine, t.phase = e.id, 'done'
        dfhack.gui.showAnnouncement('A bolt thrower now stands on the wall beside the gate.', COLOR_LIGHTGREEN, true)
        return ('gate %s: bolt thrower ready on the wall'):format(g.side)
    end
end

-- where a guard stands for each turret: the top of its stair, beside the engine
function posts()
    local s, out = load(), {}
    for _, t in pairs(s.gates or {}) do
        if t.phase == 'done' and t.ix then out[#out + 1] = {t.ix, t.iy, t.top or t.z + 1} end
    end
    return out
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local lines = {}
    local ok, err = pcall(function()
        for _, g in ipairs(gates()) do lines[#lines + 1] = step(s, g) end
    end)
    s.last = ok and (#lines > 0 and table.concat(lines, '; ') or 'no gates yet (the curtain wall plans them)') or ('error: ' .. tostring(err))
    save(s)
end

function status() return 'gate turrets: ' .. (load().last or 'idle') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('gate turrets: watching')
elseif cmd == 'find' then
    for _, g in ipairs(gates()) do
        local p, why = site(g)
        print(p and ('gate %s at %d,%d,%d: engine on the wall at %d,%d,%d, stair at %d,%d'):format(g.side, g.x, g.y, g.z, p.tx, p.ty, p.z + 1, p.ix, p.iy)
            or ('gate %s: %s'):format(g.side, why))
    end
else
    print(status())
end
