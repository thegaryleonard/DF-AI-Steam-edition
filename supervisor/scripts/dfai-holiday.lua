-- Holiday party mode (user: "holiday party mode (no jobs no masters)").
--
--   dfai-holiday start [days]   everyone downs tools for N game days (default 7)
--   dfai-holiday stop           back to work now
--   dfai-holiday                status
--
-- Every citizen's labors are saved and cleared (autolabor is paused so it
-- can't hand them back); with nothing to do, dwarves drink, eat, talk and
-- dance in the taverns. Squads are left alone, so the fort is still defended.
-- At the end every labor goes back exactly as it was and autolabor resumes.
-- The state lives in the save, so a reload mid-holiday still restores it.
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-holiday'
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function now_abs() return df.global.cur_year * 403200 + df.global.cur_year_tick end
local function notify(msg)
    local f = io.open(NOTIFY, 'a')
    if f then f:write(msg .. '\n') f:close() end
end
local function announce(msg)
    dfhack.gui.showAnnouncement(msg, COLOR_LIGHTMAGENTA, true)
    print('[holiday] ' .. msg)
end

local function autolabor_on()
    local out = dfhack.run_command_silent('enable') or ''
    return out:match('autolabor:%s*on') ~= nil
end

local function begin(days)
    local s = load()
    if s.active then return 'already on holiday' end
    s.active, s.until_tick, s.days = true, now_abs() + days * 1200, days
    s.autolabor = autolabor_on()
    if s.autolabor then dfhack.run_command_silent('disable', 'autolabor') end
    s.labors = {}
    local n = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        local on = {}
        for i, v in ipairs(u.status.labors) do
            if v then on[#on + 1] = i u.status.labors[i] = false end
        end
        s.labors[tostring(u.id)] = on
        n = n + 1
    end
    s.people = n
    save(s)
    announce(('HOLIDAY! The overseer has declared %d day%s of rest. No jobs, no masters: to the taverns!'):format(days, days == 1 and '' or 's'))
    notify(('**Holiday!** The overseer declared %d day%s off: all %d dwarves have downed tools and gone partying. (Squads stay on guard.)'):format(days, days == 1 and '' or 's', n))
    return ('holiday for %d days: %d dwarves off work'):format(days, n)
end

local function finish(why)
    local s = load()
    if not s.active then return 'not on holiday' end
    local back = 0
    for id, on in pairs(s.labors or {}) do
        local u = df.unit.find(tonumber(id))
        if u and not dfhack.units.isDead(u) then
            for _, i in ipairs(on) do u.status.labors[i] = true end
            back = back + 1
        end
    end
    if s.autolabor then dfhack.run_command_silent('enable', 'autolabor') end
    s.active, s.labors = false, nil
    s.last = {ended = now_abs(), people = back, why = why}
    save(s)
    announce('The holiday is over. Back to work!')
    notify(('**The holiday is over** (%s). %d dwarves are back at work.'):format(why, back))
    return ('holiday over: %d dwarves back at work'):format(back)
end

local function tick()
    local s = load()
    if not s.active then return end
    -- citizens who arrived during the holiday join the party too
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if not s.labors[tostring(u.id)] then
            local on = {}
            for i, v in ipairs(u.status.labors) do
                if v then on[#on + 1] = i u.status.labors[i] = false end
            end
            s.labors[tostring(u.id)] = on
            save(s)
        else
            -- something handed a labor back (autolabor, a noble): take it off again
            for i, v in ipairs(u.status.labors) do if v then u.status.labors[i] = false end end
        end
    end
    if now_abs() >= s.until_tick then finish(('%d days are up'):format(s.days)) end
end

function status()
    local s = load()
    if s.active then
        return ('on holiday: %d dwarves partying, %.1f days left'):format(s.people or 0, math.max(0, (s.until_tick - now_abs()) / 1200))
    end
    return 'at work' .. (s.last and (' (last holiday: %d dwarves came back)'):format(s.last.people or 0) or '')
end

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local cmd = args[1] or 'status'
if cmd == 'start' then
    local days = math.max(1, math.min(28, tonumber(args[2]) or 7))
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    dfhack.timeout(1, 'ticks', function() _G.dfai_holiday_last = begin(days) end)
    print(('holiday: %d days, starting on the next tick'):format(days))
elseif cmd == 'stop' then
    dfhack.timeout(1, 'ticks', function() _G.dfai_holiday_last = finish('the overseer called it off') end)
    print('holiday: ending on the next tick')
elseif cmd == 'resume' then
    -- onMapLoad: keep watching a holiday that was running when the game saved
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    print('holiday watch: ' .. status())
else
    print('holiday: ' .. status())
end
