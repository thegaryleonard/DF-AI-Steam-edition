-- dfai-atom-smasher: the refuse goes down the execution pit, and a drawbridge
-- at the bottom of each drop wipes it out (user: "an atom smasher in dwarf
-- fortress slang"). Showerwheels' pit is the 3-tile shaft at x11 y126..128,
-- z168 down to the floor at z157: the hatch drop (execution pit) at y126, a
-- stair at y127 and the refuse chute at y128.
--
-- Phases (one check twice a game day):
--   open    remove the constructed floor over the refuse chute (11,128,168)
--           so the dump zone throws into the shaft, and over the stair
--           (11,127,168) so builders can get down
--   stair   a down stair at 11,127,168 into the shaft
--   bridges a 1x1 drawbridge on the bottom floor of each drop (11,126,157 and
--           11,128,157). Items land on the lowered bridge; raising a 1-tile
--           bridge brings its whole deck up onto that tile: gone.
--   seal    the stair top floored over again (nothing climbs out)
--   running when anything lies on a bridge, raise it, then lower it 50 ticks
--           later ("ai bridge <id> 1|0" in the df-ai plugin, as a lever would)
--@module = true
--[====[
dfai-atom-smasher
=================
    dfai-atom-smasher start | now | smash | status
]====]

local repeatUtil = require('repeat-util')
local KEY = 'dfai-atom-smasher'
local X, Y_PIT, Y_STAIR, Y_DUMP, Z_TOP, Z_BOT = 11, 126, 127, 128, 168, 157
local SITE = 350

local function load() return dfhack.persistent.getSiteData(KEY, {phase = 'open', smashed = 0}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function shape(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape
end
local function is_construction(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].material == df.tiletype_material.CONSTRUCTION
end
local function bridge_at(y)
    local b = dfhack.buildings.findAtTile(xyz2pos(X, y, Z_BOT))
    if b and b:getType() == df.building_type.Bridge then return b end
end
local function built(b) return b and b:getBuildStage() >= b:getMaxBuildStage() end
local function items_on(y)
    local n = 0
    local blk = dfhack.maps.getTileBlock(X, y, Z_BOT)
    if not blk then return 0 end
    for _, id in ipairs(blk.items) do
        local it = df.item.find(id)
        if it and it.pos.x == X and it.pos.y == y and it.pos.z == Z_BOT and it.flags.on_ground then n = n + 1 end
    end
    return n
end
local function citizen_on(y)
    for _, u in ipairs(df.global.world.units.active) do
        if u.pos.x == X and u.pos.y == y and u.pos.z == Z_BOT and dfhack.units.isCitizen(u) and not dfhack.units.isDead(u) then return true end
    end
end
local function removing(y)
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.RemoveConstruction and j.pos.x == X and j.pos.y == y and j.pos.z == Z_TOP then return true end
        l = l.next
    end
    return dfhack.maps.getTileFlags(X, y, Z_TOP).dig ~= df.tile_dig_designation.No
end
local function remove_floor(y)
    if is_construction(X, y, Z_TOP) and shape(X, y, Z_TOP) == df.tiletype_shape.FLOOR then
        if not removing(y) then dfhack.constructions.designateRemove(xyz2pos(X, y, Z_TOP)) end
        return false
    end
    return shape(X, y, Z_TOP) ~= df.tiletype_shape.FLOOR
end
local function construct(y, z, ctype)
    if not dfhack.buildings.findAtTile(xyz2pos(X, y, z)) then
        pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = ctype, pos = xyz2pos(X, y, z)})
    end
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or df.global.plotinfo.site_id ~= SITE then return end
    local s = load()
    if s.phase == 'open' then
        local a, b = remove_floor(Y_DUMP), remove_floor(Y_STAIR)
        if a and b then s.phase = 'stair' end
        s.last = 'opening the refuse chute and the stair top'
    elseif s.phase == 'stair' then
        if shape(X, Y_STAIR, Z_TOP) == df.tiletype_shape.STAIR_DOWN then
            s.phase = 'bridges'
        else
            construct(Y_STAIR, Z_TOP, df.construction_type.DownStair)
        end
        s.last = 'a stair down into the shaft'
    elseif s.phase == 'bridges' then
        local done = 0
        for i, y in ipairs({Y_PIT, Y_DUMP}) do
            local b = bridge_at(y)
            if built(b) then
                done = done + 1
                s['bridge' .. i] = b.id
            elseif not b then
                -- drawbridge raising north (pit) / south (chute), into the shaft walls
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Bridge, pos = xyz2pos(X, y, Z_BOT),
                    width = 1, height = 1, direction = (y == Y_PIT) and df.building_bridgest.T_direction.Up or df.building_bridgest.T_direction.Down})
            end
        end
        if done == 2 then s.phase = 'seal' end
        s.last = ('building the smashers: %d of 2 done'):format(done)
    elseif s.phase == 'seal' then
        local sh = shape(X, Y_STAIR, Z_TOP)
        if sh == df.tiletype_shape.FLOOR then
            s.phase = 'running'
            s.last = 'sealed; smashing'
        elseif sh == df.tiletype_shape.STAIR_DOWN and is_construction(X, Y_STAIR, Z_TOP) then
            if not removing(Y_STAIR) then dfhack.constructions.designateRemove(xyz2pos(X, Y_STAIR, Z_TOP)) end
            s.last = 'taking the stair out'
        elseif sh == df.tiletype_shape.EMPTY then
            construct(Y_STAIR, Z_TOP, df.construction_type.Floor)
            s.last = 'flooring over the stair'
        end
    elseif s.phase == 'running' then
        for i, y in ipairs({Y_PIT, Y_DUMP}) do
            local id = s['bridge' .. i]
            local n = items_on(y)
            if id and n > 0 and not citizen_on(y) then
                dfhack.run_command_silent('ai', 'bridge', tostring(id), '1')
                dfhack.timeout(50, 'ticks', function() dfhack.run_command_silent('ai', 'bridge', tostring(id), '0') end)
                s.smashed = (s.smashed or 0) + n
                s.last = ('smashed %d item(s) at the %s'):format(n, y == Y_PIT and 'execution pit' or 'refuse chute')
            end
        end
    end
    save(s)
end

local function status()
    local s = load()
    return ('atom smasher: %s; %s; %d items smashed so far'):format(s.phase, s.last or 'starting', s.smashed or 0)
end

if dfhack_flags.module then return end
local cmd = ({...})[1]
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    print('atom smasher: started')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('atom smasher: queued for the next game tick')
else
    print(status())
end
