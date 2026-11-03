-- dfai-helpers: starts the df-ai helper scripts (the fort's priority list,
-- health checks, water, defences, big projects...) once df-ai is switched on
-- in this fort. If you play a fort yourself without df-ai, they stay off and
-- never touch it. Run from onMapLoad-dfai.init.
--   dfai-helpers          start watching (runs the helpers when df-ai is on)
--   dfai-helpers status   which helpers are running
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-helpers'

-- the fort helpers, in start order (each one is safe to start twice)
HELPERS = {
    'dfai-site-reset',
    'dfai-fps start',
    'dfai-fort-health start', 'dfai-watchdog start', 'dfai-verify start',
    'dfai-foreign-office start', 'dfai-war-office start',
    'dfai-deep-dig start', 'dfai-cavern-seal start', 'dfai-cavern-ore resume', 'dfai-ore-scrub resume',
    'dfai-armory start', 'dfai-archer-posts start', 'dfai-battle-report start',
    'dfai-bunker start', 'dfai-walls start', 'dfai-mist start', 'dfai-traffic start', 'dfai-pit start', 'dfai-wellshaft start', 'dfai-yardwatch start', 'dfai-toollabor start',
    'dfai-catacomb resume', 'dfai-ghost-watch start', 'dfai-instruments start',
    'dfai-holiday resume', 'dfai-build resume',
}

H = rawget(_G, 'dfai_helpers') or {}
rawset(_G, 'dfai_helpers', H)

local function dfai_on()
    local out = dfhack.run_command_silent('plug', 'df-ai') or ''
    return out:find('%senabled') ~= nil
end

local function site() local s = dfhack.world.getCurrentSite() return s and s.id or -1 end

local function check()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    if H.started == site() then return end
    if not dfai_on() then H.waiting = true return end
    H.waiting, H.started, H.ran, H.failed = false, site(), 0, {}
    for _, line in ipairs(HELPERS) do
        local words = {}
        for w in line:gmatch('%S+') do words[#words + 1] = w end
        local ok = pcall(dfhack.run_command_silent, table.unpack(words))
        if ok then H.ran = H.ran + 1 else H.failed[#H.failed + 1] = words[1] end
    end
    print(('dfai-helpers: df-ai is on - started %d helpers'):format(H.ran))
end

function status()
    if H.started and H.started == site() then
        return ('helpers running (%d)%s'):format(H.ran or 0, H.failed and #H.failed > 0 and ('; failed: ' .. table.concat(H.failed, ', ')) or '')
    end
    return H.waiting and 'waiting: the helpers start when df-ai is switched on ("enable df-ai")' or 'not started'
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'start'
if cmd == 'start' then
    H.started = nil
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', function() pcall(check) end)
    dfhack.timeout(1, 'ticks', function() pcall(check) end)
    print('dfai-helpers: ' .. (dfai_on() and 'starting' or 'waiting for df-ai to be switched on'))
else
    print('dfai-helpers: ' .. status())
end
