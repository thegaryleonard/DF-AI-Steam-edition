-- dfai-watchdog: catches the silent failures (lessons from five forts: parts
-- orders that "completed" and made nothing, stone all marked economic, a
-- caravan holding the fort at 12, ten dwarves dead of thirst beside 20,000
-- drinks). Checks outcomes, not actions. Once a game day:
--   stalled projects   a big project whose status hasn't moved in 5 days
--   stalled orders     a work order whose count hasn't moved in 10 days
--   deaths             who died in the last 30 days and of what; thirst
--                      deaths with drink in stock mean the wounded have no
--                      water, and are called out as such
--   young fort         in its first year: water reachable, a farm plot by
--                      day 60, beds, drink
-- Each new problem is announced once (in game, and queued for Discord).
--   dfai-watchdog start | now | status | json
--@module = true

local json = require('json')
local repeatUtil = require('repeat-util')
local KEY = 'dfai-watchdog'
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'
-- the builds that should finish (the cavern seal and deep dig are watchers:
-- their status swaps between two waiting lines forever, which read as a new
-- problem every few minutes on Discord)
local PROJECTS = {
    {'mist generator', 'dfai-mist'}, {'curtain wall', 'dfai-walls'}, {'bunkers', 'dfai-bunker'},
    {'execution pit', 'dfai-pit'},
}
-- the same problem is told again at most every REMIND real seconds. Game days
-- are no use for this: at 100 FPS sixty of them pass in twelve minutes, and the
-- same four stuck projects went to Discord all night.
local REMIND = 12 * 3600
local STALL_DAYS, ORDER_DAYS, DEATH_DAYS = 5, 10, 30
local DAY = 1200

W = rawget(_G, 'dfai_watchdog') or {problems = {}, last = 'not checked yet'}
rawset(_G, 'dfai_watchdog', W)

local function today() return df.global.cur_year * 336 + df.global.cur_year_tick // DAY end
local function load() return dfhack.persistent.getSiteData(KEY, {seen = {}, proj = {}, orders = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

local function status_of(mod)
    local ok, m = pcall(reqscript, mod)
    if not ok or not m.status then return nil end
    local ok2, st = pcall(m.status)
    if not ok2 or not st then return nil end
    -- numbers that tick (counts, days) are progress; strip nothing, compare whole
    return tostring(st)
end
local function idle_status(st)
    -- states where standing still is fine
    return st:find('on hold') or st:find('waits') or st:find('enough for now') or st:find('running') or st:find('idle')
        or st:find('not this fort') or st:find('no cavern outpost yet') or st:find('done') or st:find('standing,') or st:find('built, waiting for wind')
        or st:find('no open cavern breach') or st:find('sealed;') or st:find('no execution pit')
        or st:find('wait for') or st:find('waiting for %d+ citizens') or st:find('no well, but')
end

local function check(s, problems)
    local d = today()
    -- 1. projects
    for _, p in ipairs(PROJECTS) do
        local st = status_of(p[2])
        if st then
            local rec = s.proj[p[2]]
            if not rec or rec.st ~= st then s.proj[p[2]] = {st = st, since = d}
            elseif d - rec.since >= STALL_DAYS and not idle_status(st) then
                problems[#problems + 1] = {key = 'proj:' .. p[2], text = ('%s stuck for %d days: %s'):format(p[1], d - rec.since, st)}
            end
        end
    end
    -- 2. work orders: one line for all of them (df-ai keeps dozens of orders
    -- waiting on materials; listing each one buried everything else)
    local stuck_orders = {}
    local live = {}
    for _, mo in ipairs(df.global.world.manager_orders.all) do
        local k = tostring(mo.id)
        live[k] = true
        local rec = s.orders[k]
        if not rec or rec.left ~= mo.amount_left then s.orders[k] = {left = mo.amount_left, since = d}
        elseif d - rec.since >= ORDER_DAYS and mo.amount_left > 0 then
            stuck_orders[#stuck_orders + 1] = df.job_type.attrs[mo.job_type] and df.job_type.attrs[mo.job_type].caption or df.job_type[mo.job_type]
        end
    end
    W.stuck_orders = stuck_orders
    if #stuck_orders >= 5 then
        table.sort(stuck_orders)
        problems[#problems + 1] = {key = 'orders', quiet = true, text = ('%d work orders have not moved in %d+ days (%s%s)'):format(#stuck_orders, ORDER_DAYS,
            table.concat(stuck_orders, ', ', 1, math.min(6, #stuck_orders)), #stuck_orders > 6 and ', ...' or '')}
    end
    for k in pairs(s.orders) do if not live[k] then s.orders[k] = nil end end
    -- 2b. duplicate dig jobs: a script that re-marks a tile every step makes
    -- DF queue another job for it each time (890 piled up on one 5x5 pen and
    -- the miners stopped). Remove the unclaimed copies; report who.
    do
        local DIGJOB = {[df.job_type.Dig] = true, [df.job_type.DigChannel] = true, [df.job_type.CarveUpwardStaircase] = true,
            [df.job_type.CarveDownwardStaircase] = true, [df.job_type.CarveUpDownStaircase] = true, [df.job_type.CarveRamp] = true}
        local seen, extra = {}, {}
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j and DIGJOB[j.job_type] then
                local k = j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z
                if seen[k] then if not dfhack.job.getWorker(j) then extra[#extra + 1] = j end else seen[k] = true end
            end
            l = l.next
        end
        local n = 0
        for _, j in ipairs(extra) do if dfhack.job.removeJob(j) then n = n + 1 end end
        W.dup_jobs = n
        if n >= 20 then
            problems[#problems + 1] = {key = 'dupjobs', quiet = true, text = ('cleared %d duplicate dig jobs (a script is re-marking tiles that already have a job)'):format(n)}
        end
    end
    -- 3. deaths in the last 30 days
    local causes, thirst, total = {}, 0, 0
    for _, u in ipairs(df.global.world.units.all) do
        if dfhack.units.isDead(u) and u.civ_id == df.global.plotinfo.civ_id and dfhack.units.isDwarf(u) then
            local inc = df.incident.find(u.counters.death_id)
            if inc and (df.global.cur_year - inc.event_year) * 336 * DAY + (df.global.cur_year_tick - inc.event_time) <= DEATH_DAYS * DAY then
                total = total + 1
                local c = df.death_type[inc.death_cause] or '?'
                causes[c] = (causes[c] or 0) + 1
                if inc.death_cause == df.death_type.THIRST then thirst = thirst + 1 end
            end
        end
    end
    local parts = {}
    for c, n in pairs(causes) do parts[#parts + 1] = n .. ' ' .. c:lower():gsub('_', ' ') end
    W.deaths = total > 0 and ('%d died in the last %d days (%s)'):format(total, DEATH_DAYS, table.concat(parts, ', ')) or ('nobody died in the last %d days'):format(DEATH_DAYS)
    if thirst > 0 then
        local drinks = 0
        for _, i in ipairs(df.global.world.items.other.DRINK) do if not i.flags.forbid then drinks = drinks + i.stack_size end end
        problems[#problems + 1] = {key = 'thirst', text = drinks > 0
            and ('%d dwarves died of THIRST with %d drinks in stock: the wounded in bed only get water - the fort needs a reachable water source'):format(thirst, drinks)
            or ('%d dwarves died of thirst: no drink and no water'):format(thirst)}
    end
    if total >= 10 then problems[#problems + 1] = {key = 'deaths', text = W.deaths} end
    -- 4. a young fort's basics
    -- the fort's age, from the first day the watchdog saw it (site data is per
    -- fort; a fort older than a year when first seen is just "old"). The
    -- game year starts before the embark, so year/tick alone said "day 90"
    -- on the day Boardghosts was founded.
    local site = dfhack.world.getCurrentSite()
    if not s.born then
        -- new if its site was founded this year, or if hardly anything is
        -- built yet (Channelevened's site was older than its fort: it read
        -- as a 999-day-old fort and its walls as "stuck for 21 days")
        local fresh = (site and site.created_year == df.global.cur_year) or #df.global.world.buildings.all < 50
        s.born = fresh and d or (d - 999)
    end
    local age = d - s.born
    if age <= 336 then
        local okp, pri = pcall(reqscript, 'dfai-priorities')
        if okp and pri.no_water() then problems[#problems + 1] = {key = 'young:water', text = ('day %d of the fort: no water anyone can reach (fort health looks for some daily)'):format(age)} end
        if age >= 60 and #df.global.world.buildings.other.FARM_PLOT == 0 then problems[#problems + 1] = {key = 'young:farm', text = ('day %d of the fort and still no farm plot'):format(age)} end
    end
end

local function step()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local s = load()
    local problems = {}
    check(s, problems)
    -- announce the new ones once
    local site = dfhack.world.getCurrentSite()
    local fort = site and dfhack.df2utf(dfhack.translation.translateName(site.name, true)) or 'the fort'
    local now, day = os.time(), os.date('%Y-%m-%d')
    for _, p in ipairs(problems) do
        local last = tonumber(s.seen[p.key])
        if last and last < 1e9 then s.seen[p.key], last = now, now end   -- old saves kept game days: count as just told
        if not last or now - last >= REMIND then
            s.seen[p.key] = now
            dfhack.gui.showAnnouncement('Watchdog: ' .. p.text, COLOR_LIGHTRED, false)
            -- Discord only hears about the big ones, at most 3 a real day
            s.sent = (s.sent_day == day) and (s.sent or 0) or 0
            s.sent_day = day
            if not p.quiet and s.sent < 3 then
                local f = io.open(NOTIFY, 'a')
                if f then f:write(('[watchdog] %s: %s\n'):format(fort, p.text)) f:close() end
                s.sent = s.sent + 1
            end
        end
    end
    for k, v in pairs(s.seen) do if not tonumber(v) or tonumber(v) < 1e9 or now - tonumber(v) > 2 * REMIND then s.seen[k] = nil end end
    save(s)
    W.problems = problems
    W.last = #problems == 0 and ('all clear; ' .. (W.deaths or '')) or (('%d problem%s: '):format(#problems, #problems > 1 and 's' or '') .. table.concat((function()
        local t = {} for i, p in ipairs(problems) do if i <= 4 then t[#t + 1] = p.text end end return t end)(), ' | '))
end

function status() return 'watchdog: ' .. W.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, DAY, 'ticks', function() local ok, e = pcall(step) if not ok then W.last = 'error: ' .. tostring(e) end end)
    dfhack.timeout(1, 'ticks', function() pcall(step) end)
    print('watchdog: daily')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then W.last = 'error: ' .. tostring(e) end end)
    print('watchdog: checking on the next tick')
elseif cmd == 'json' then
    print(json.encode({problems = W.problems, deaths = W.deaths, last = W.last}))
else
    print(status())
end
