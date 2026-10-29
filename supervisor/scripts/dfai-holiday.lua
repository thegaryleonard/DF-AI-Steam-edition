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

-- the party in numbers, for the Herald (user: "definitely need a broadsheet
-- holiday article and timer")
local function stock(list)
    local n = 0
    for _, i in ipairs(list) do if not i.flags.rotten and not i.flags.garbage_collect then n = n + i.stack_size end end
    return n
end
local function drinks() return stock(df.global.world.items.other.DRINK) end
local function meals() return stock(df.global.world.items.other.FOOD) end
local PERF = {
    MUSIC_RECITAL = 'a music recital', STORYTELLING_EVENT = 'a story', POETRY_RECITAL = 'a poetry reading',
    DANCE_PERFORMANCE = 'a dance', DANCE = 'a dance', CHANT = 'a chant', SONG = 'a song', MUSIC = 'music',
}
local function hf_name(id)
    local hf = id and df.historical_figure.find(id)
    return hf and dfhack.df2utf(dfhack.translation.translateName(hf.name, false)) or nil
end
-- how many take part (each event type keeps its participants differently)
local function crowd(e)
    local ok, n = pcall(function() return #e.participants.units end)
    if ok and n then return n end
    ok, n = pcall(function() return #e.participants end)
    return ok and n or 0
end
-- who is doing what right now
local function party_now()
    local t = {talking = 0, performing = {}, playing = 0, praying = 0, serving = 0, dancing = 0}
    for _, a in ipairs(df.global.world.activities.all) do
        for _, e in ipairs(a.events) do
            local ty = e:getType()
            if ty == df.activity_event_type.Conversation or ty == df.activity_event_type.Socialize then t.talking = t.talking + crowd(e)
            elseif ty == df.activity_event_type.Play or ty == df.activity_event_type.PlayWithToy or ty == df.activity_event_type.MakeBelieve then t.playing = t.playing + crowd(e)
            elseif ty == df.activity_event_type.Prayer or ty == df.activity_event_type.Worship then t.praying = t.praying + crowd(e)
            elseif ty == df.activity_event_type.FillServiceOrder then t.serving = t.serving + 1
            elseif df.activity_event_performancest:is_instance(e) then
                local kind = df.performance_event_type[e.type] or 'PERFORMANCE'
                if kind:find('DANCE') then t.dancing = t.dancing + crowd(e) end
                t.performing[#t.performing + 1] = {id = e.event_id, kind = PERF[kind] or kind:lower():gsub('_event', ''):gsub('_', ' '),
                    by = hf_name(e.participants.histfigs[0]), crowd = crowd(e)}
            end
        end
    end
    return t
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
    s.party = {drinks0 = drinks(), meals0 = meals(), shows = {}, nshows = 0, peak = 0, started = now_abs()}
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
    local P = s.party or {}
    s.active, s.labors = false, nil
    s.last = {ended = now_abs(), people = back, why = why, days = s.days, started = P.started,
        drunk = P.drinks0 and math.max(0, P.drinks0 - drinks()) or nil, eaten = P.meals0 and math.max(0, P.meals0 - meals()) or nil,
        nshows = P.nshows, shows = P.shows, peak = P.peak}
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
    -- the tally: every performance once, and the biggest crowd
    local P = s.party
    if not P then P = {drinks0 = drinks(), meals0 = meals(), shows = {}, nshows = 0, peak = 0, started = s.until_tick - s.days * 1200, late = true} s.party = P save(s) end
    local okp, now = pcall(party_now)
    if not okp then now = {performing = {}, talking = 0, playing = 0, dancing = 0} end
    local changed = false
    P.seen = P.seen or {}
    for _, sh in ipairs(now.performing) do
        if not P.seen[tostring(sh.id)] then
            P.seen[tostring(sh.id)] = true
            P.nshows = (P.nshows or 0) + 1
            if #P.shows < 12 then P.shows[#P.shows + 1] = {kind = sh.kind, by = sh.by, crowd = sh.crowd} end
            changed = true
        end
    end
    local busy = now.talking + now.playing + now.dancing
    for _, sh in ipairs(now.performing) do busy = busy + sh.crowd end
    if busy > (P.peak or 0) then P.peak, changed = busy, true end
    if changed then save(s) end
    if now_abs() >= s.until_tick then finish(('%d days are up'):format(s.days)) end
end

-- for the Herald: the holiday now (or the last one), in numbers
function report()
    local s = load()
    local r = {active = s.active and true or false, now = now_abs()}
    if s.active then
        local P = s.party or {}
        local now = party_now()
        r.days, r.until_tick, r.people = s.days, s.until_tick, s.people
        r.started = s.until_tick - s.days * 1200
        r.left_ticks = math.max(0, s.until_tick - now_abs())
        r.drunk = P.drinks0 and math.max(0, P.drinks0 - drinks()) or 0
        r.eaten = P.meals0 and math.max(0, P.meals0 - meals()) or 0
        r.counted_from = P.late and 'late' or 'start'
        r.nshows, r.shows, r.peak = P.nshows or 0, P.shows or {}, P.peak or 0
        r.talking, r.playing, r.praying, r.dancing, r.serving = now.talking, now.playing, now.praying, now.dancing, now.serving
        r.performing = now.performing
        local sq = 0
        for _, u in ipairs(dfhack.units.getCitizens(true)) do if u.military.squad_id ~= -1 then sq = sq + 1 end end
        r.on_guard = sq
    elseif s.last then
        r.last = s.last
    end
    return r
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
