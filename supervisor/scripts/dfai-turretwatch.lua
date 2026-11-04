-- dfai-turretwatch: notices when a bolt thrower kills something, and tells
-- the owner (a line in the supervisor's Discord relay file, with "{owner}"
-- for the relay to turn into the owner's mention).
-- It watches bolts in flight from every bolt thrower's tile, remembers who
-- fired them, and on a death checks whether one of those operators (or a
-- bolt shot moments before) was the killer.
--   dfai-turretwatch start | stop | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-turretwatch'
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'

state = state or {shots = {}, firers = {}, last_shot = -1, last_shot_engine = nil}

local function load() return dfhack.persistent.getSiteData(KEY, {shots = 0, kills = 0, log = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

local function engines()
    local list = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.SiegeEngine and b.type == df.siegeengine_type.BoltThrower
            and b:getBuildStage() >= b:getMaxBuildStage() then
            list[#list + 1] = b
        end
    end
    return list
end

local function engine_at(pos, list)
    for _, b in ipairs(list) do
        if pos.z == b.z and math.abs(pos.x - b.centerx) <= 1 and math.abs(pos.y - b.centery) <= 1 then return b end
    end
end

local function where(b)
    -- a bunker's roof engine stands on open sky; the other is under the roof
    if not b then return 'a bolt thrower' end
    local up = dfhack.maps.getTileType(b.centerx, b.centery, b.z + 1)
    local open = up and df.tiletype.attrs[up].shape == df.tiletype_shape.EMPTY
    return open and 'the bolt thrower on the bunker roof' or 'the bolt thrower inside the bunker'
end

local function notify(text)
    local f = io.open(NOTIFY, 'a')
    if f then f:write(text .. '\n') f:close() end
end

-- bolts in flight from an engine's tile
local function scan()
    local now = df.global.world.frame_counter
    local list = engines()
    if #list == 0 then return end
    local s
    local link = df.global.world.projectiles.all.next
    while link do
        local p = link.item
        if p and df.proj_itemst:is_instance(p) and not state.shots[p.id] then
            local b = engine_at(p.origin_pos, list)
            if b then
                state.shots[p.id] = now
                state.last_shot, state.last_shot_engine = now, b.id
                if p.firer then state.firers[p.firer.id] = {t = now, engine = b.id} end
                s = s or load()
                s.shots = (s.shots or 0) + 1
            end
        end
        link = link.next
    end
    if s then save(s) end
    -- forget old shots
    for id, t in pairs(state.shots) do if now - t > 4800 then state.shots[id] = nil end end
end

local function flier(u)
    local r = df.creature_raw.find(u.race)
    local c = r and r.caste[u.caste]
    return c and c.flags.FLIER
end

local function on_death(unit_id)
    local u = df.unit.find(unit_id)
    if not u or dfhack.units.isCitizen(u) then return end
    local now = df.global.world.frame_counter
    local inc = df.incident.find(u.counters.death_id)
    local killer = inc and inc.criminal or -1
    local cause = inc and inc.death_cause
    local f = state.firers[killer]
    local engine
    if f and now - f.t < 2400 then
        engine = f.engine
    elseif cause == df.death_type.SHOT and state.last_shot ~= -1 and now - state.last_shot < 600 then
        engine = state.last_shot_engine
    end
    if not engine then return end
    local b = df.building.find(engine)
    local name = dfhack.df2utf(dfhack.units.getReadableName(u))
    local s = load()
    s.kills = (s.kills or 0) + 1
    table.insert(s.log, {t = now, victim = name, flier = flier(u) and true or false, where = where(b)})
    while #s.log > 20 do table.remove(s.log, 1) end
    save(s)
    local fort = 'The fort'
    pcall(function()
        local n = df.global.world.world_data.active_site[0].name
        fort = (dfhack.translation and dfhack.translation.translateName or dfhack.TranslateName)(n, true)
    end)
    notify(('{owner} **%s:** %s shot down %s%s! (bolt-thrower kills so far: %d)'):format(
        fort, where(b), name, flier(u) and ', a flier' or '', s.kills))
    dfhack.gui.showAnnouncement(('%s shot down %s.'):format(where(b), name), COLOR_LIGHTGREEN, false)
end

function status()
    local s = load()
    local last = s.log and s.log[#s.log]
    return ('turret watch: %d bolts fired, %d kills%s'):format(s.shots or 0, s.kills or 0,
        last and ('; last: ' .. last.victim .. ' by ' .. last.where) or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    local eventful = require('plugins.eventful')
    eventful.enableEvent(eventful.eventType.UNIT_DEATH, 5)
    eventful.onUnitDeath[KEY] = on_death
    repeatUtil.scheduleEvery(KEY, 3, 'ticks', function() pcall(scan) end)
    print('turret watch: on')
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    pcall(function() require('plugins.eventful').onUnitDeath[KEY] = nil end)
    print('turret watch: off')
else
    print(status())
end
