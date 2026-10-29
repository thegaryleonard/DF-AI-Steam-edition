-- Holiday party mode (user: "holiday party mode (no jobs no masters)").
--
--   dfai-holiday start [days] [title...]   everyone downs tools for N game days (default 7)
--   dfai-holiday stop           back to work now
--   dfai-holiday                status
--
-- Every citizen's labors are saved and cleared (autolabor is paused so it
-- can't hand them back); with nothing to do, dwarves drink, eat, talk and
-- dance in the taverns. Squads are left alone, so the fort is still defended.
-- At the end every labor goes back exactly as it was and autolabor resumes.
-- The state lives in the save, so a reload mid-holiday still restores it.
--
-- Names and the fort calendar (user: "can i add custom titles to holidays?
-- or even better, have a calendar with fortwide holidays scheduled?"):
-- dfhack-config/dfai-holidays.json holds
--   {"calendar": [{"name": "Midwinter Revel", "month": "Opal", "day": 15, "days": 3}, ...],
--    "next_title": "..."}   (the desk's name for the next holiday it starts)
-- A calendar holiday starts on its day each year. If invaders are in the fort
-- that day it waits (up to a week) until they're gone.
--   dfai-holiday calendar     lists it
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-holiday'
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena', 'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}
local CAL_FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-holidays.json'
local DEFAULT_CAL = {calendar = {
    {name = 'The Feast of the First Pick', month = 'Granite', day = 1, days = 3},
    {name = 'Harvest Home', month = 'Sandstone', day = 14, days = 5},
    {name = 'The Midwinter Revel', month = 'Opal', day = 15, days = 3},
}}
local function read_cal()
    local f = io.open(CAL_FILE, 'r')
    if not f then
        local w = io.open(CAL_FILE, 'w')
        if w then w:write(require('json').encode(DEFAULT_CAL)) w:close() end
        return DEFAULT_CAL
    end
    local t = f:read('*a') f:close()
    local ok, c = pcall(require('json').decode, t)
    return ok and type(c) == 'table' and c or {calendar = {}}
end
local function write_cal(c)
    local w = io.open(CAL_FILE, 'w')
    if w then w:write(require('json').encode(c)) w:close() end
end
local function month_of(m)
    if type(m) == 'number' then return m end
    for i, n in ipairs(MONTHS) do if n:lower() == tostring(m):lower() then return i - 1 end end
end
local function ordinal(n) local x = ({'st', 'nd', 'rd'})[n % 10] if not x or (n % 100 >= 11 and n % 100 <= 13) then x = 'th' end return n .. x end
-- the calendar's next dates from today, soonest first
function upcoming(n)
    local yt = df.global.cur_year_tick
    local out = {}
    for _, h in ipairs(read_cal().calendar or {}) do
        local m = month_of(h.month)
        if m and h.day then
            local at = m * 33600 + (h.day - 1) * 1200
            local wait = at - (yt - yt % 1200)
            if wait < 0 then wait = wait + 403200 end
            out[#out + 1] = {name = h.name, days = h.days, date = ('%s %s'):format(ordinal(h.day), MONTHS[m + 1]), in_days = wait // 1200}
        end
    end
    table.sort(out, function(a, b) return a.in_days < b.in_days end)
    while n and #out > n do table.remove(out) end
    return out
end
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

local function begin(days, title)
    local s = load()
    if s.active then return 'already on holiday' end
    s.active, s.until_tick, s.days = true, now_abs() + days * 1200, days
    if not title then
        -- the desk's name for this one, used once
        local c = read_cal()
        if c.next_title and c.next_title ~= '' then title = c.next_title c.next_title = nil write_cal(c) end
    end
    s.title = title
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
    local named = title and (dfhack.utf2df(title) .. '! ') or 'HOLIDAY! '
    announce(('%sThe overseer has declared %d day%s of rest. No jobs, no masters: to the taverns!'):format(named, days, days == 1 and '' or 's'))
    notify(('**%s** The overseer declared %d day%s off: all %d dwarves have downed tools and gone partying. (Squads stay on guard.)'):format(title or 'Holiday!', days, days == 1 and '' or 's', n))
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
    s.last = {ended = now_abs(), people = back, why = why, days = s.days, started = P.started, title = s.title,
        drunk = P.drinks0 and math.max(0, P.drinks0 - drinks()) or nil, eaten = P.meals0 and math.max(0, P.meals0 - meals()) or nil,
        nshows = P.nshows, shows = P.shows, peak = P.peak}
    save(s)
    announce((s.last.title and (dfhack.utf2df(s.last.title) .. ' is over.') or 'The holiday is over.') .. ' Back to work!')
    notify(('**%s is over** (%s). %d dwarves are back at work.'):format(s.last.title or 'The holiday', why, back))
    return ('holiday over: %d dwarves back at work'):format(back)
end

-- the fort calendar: a holiday starts on its day (once a year); invaders in
-- the fort put it off until they're gone, for up to a week
local function invaders()
    for _, u in ipairs(df.global.world.units.active) do
        if (u.flags1.active_invader or u.flags2.visitor_uninvited) and not dfhack.units.isDead(u) and dfhack.units.isActive(u)
            and not dfhack.maps.getTileFlags(u.pos).hidden then return true end -- (sealed-off beasts don't count)
    end
end
local function calendar_check(s)
    local yt = df.global.cur_year_tick
    local month, day = yt // 33600, (yt % 33600) // 1200 + 1
    s.cal_done = s.cal_done or {}
    for _, h in ipairs(read_cal().calendar or {}) do
        local m = month_of(h.month)
        local key = ('%d:%s'):format(df.global.cur_year, tostring(h.name))
        if m == month and h.day and day >= h.day and day <= h.day + 6 and not s.cal_done[key] then
            if invaders() then
                if s.cal_wait ~= key then
                    s.cal_wait = key
                    save(s)
                    announce(('%s is put off: there are invaders in the fort.'):format(dfhack.utf2df(h.name or 'The holiday')))
                end
            else
                s.cal_done[key], s.cal_wait = true, nil
                save(s)
                begin(math.max(1, math.min(28, tonumber(h.days) or 3)), h.name)
            end
            return
        end
    end
end

local function tick()
    local s = load()
    if not s.active then
        if (s.cal_at or 0) ~= df.global.cur_year_tick // 1200 then   -- once a game day... or a bit more
            s.cal_at = df.global.cur_year_tick // 1200
            calendar_check(s)
        end
        return
    end
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
        r.days, r.until_tick, r.people, r.title = s.days, s.until_tick, s.people, s.title
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
    r.upcoming = upcoming(3)
    r.waiting = s.cal_wait
    return r
end

function status()
    local s = load()
    local nx = upcoming(1)[1]
    local next_line = nx and ('; next on the calendar: %s, the %s (in %d days)'):format(nx.name, nx.date, nx.in_days) or '; nothing on the calendar'
    if s.active then
        return ('on holiday%s: %d dwarves partying, %.1f days left'):format(s.title and (' (' .. s.title .. ')') or '', s.people or 0, math.max(0, (s.until_tick - now_abs()) / 1200))
    end
    return 'at work' .. (s.last and (' (last holiday: %d dwarves came back)'):format(s.last.people or 0) or '') .. next_line
end

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local cmd = args[1] or 'status'
if cmd == 'start' then
    local days = math.max(1, math.min(28, tonumber(args[2]) or 7))
    local title = #args >= 3 and table.concat(args, ' ', 3) or nil
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    dfhack.timeout(1, 'ticks', function() _G.dfai_holiday_last = begin(days, title) end)
    print(('holiday: %d days, starting on the next tick'):format(days))
elseif cmd == 'stop' then
    dfhack.timeout(1, 'ticks', function() _G.dfai_holiday_last = finish('the overseer called it off') end)
    print('holiday: ending on the next tick')
elseif cmd == 'calendar' then
    for _, h in ipairs(upcoming()) do print(('%-32s the %-16s %d days   (in %d days)'):format(h.name, h.date, h.days or 0, h.in_days)) end
elseif cmd == 'resume' then
    -- onMapLoad: keep watching a holiday that was running when the game saved
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    print('holiday watch: ' .. status())
else
    print('holiday: ' .. status())
end
