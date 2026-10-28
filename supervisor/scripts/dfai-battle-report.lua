-- Battle report (user: "a battle report about the last battle had in the fort
-- in the broadsheet... see those stats for a bit after a siege").
--
-- Once a game day (and on 'now') it reads the world's own history: every
-- historical-figure death at this site in the last two years, grouped into
-- battles (deaths no more than two days apart). The most recent battle with
-- at least two deaths and an enemy involved is written, with its stats, to
-- dfhack-config/dfai-battle.json for the Herald (herald_trade.py -> overlay).
-- Also the fort's deadliest living dwarves (lifetime kills), for the ledger.
--
--   dfai-battle-report start | now | status
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-battle-report'
local GAP = 2 * 1200            -- deaths further apart than this are separate battles
local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
    'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}

local function T(y, s) return y * 403200 + s end
local function now_abs() return T(df.global.cur_year, df.global.cur_year_tick) end
local function date(y, s)
    local m = s // 33600
    return ('%d %s, year %d'):format((s % 33600) // 1200 + 1, MONTHS[m + 1] or '?', y)
end
local function hf_name(hf)
    if not hf then return nil end
    local n = dfhack.translation.translateName(hf.name, true)
    if n == '' then
        local raw = df.creature_raw.find(hf.race)
        n = raw and raw.name[0] or 'someone'
    end
    return (dfhack.df2utf(n):gsub(' the .*$', ''))   -- drop long epithets
end
local function race_of(race, plural)
    local raw = df.creature_raw.find(race)
    return raw and raw.name[plural and 1 or 0] or 'creature'
end
local function is_beast(race)
    local raw = df.creature_raw.find(race)
    return raw and (raw.flags.HAS_ANY_FEATURE_BEAST or raw.flags.HAS_ANY_TITAN or raw.flags.HAS_ANY_MEGABEAST or raw.flags.HAS_ANY_DEMON) or false
end
local function profession(hf)
    local u = hf and hf.unit_id ~= -1 and df.unit.find(hf.unit_id)
    if u then return dfhack.df2utf(dfhack.units.getProfessionName(u)) end
    return hf and hf.profession ~= -1 and df.profession.attrs[hf.profession].caption or ''
end

local function deaths()
    local site, civ = df.global.plotinfo.site_id, df.global.plotinfo.civ_id
    local out = {}
    local ev = df.global.world.history.events
    local stop = df.global.cur_year - 2
    for i = #ev - 1, 0, -1 do
        local e = ev[i]
        if e.year < stop then break end
        if e:getType() == df.history_event_type.HIST_FIGURE_DIED and e.site == site then
            local v = df.historical_figure.find(e.victim_hf)
            local k = e.slayer_hf ~= -1 and df.historical_figure.find(e.slayer_hf) or nil
            local cause = df.death_type[e.death_cause] or ''
            -- butchered livestock, old age and the execution pit are not battles
            local skip = cause == 'SLAUGHTER' or cause == 'OLD_AGE' or (v and v.civ_id ~= civ and e.slayer_hf == -1)
            if v and not skip then
                out[#out + 1] = {t = T(e.year, e.seconds), year = e.year, sec = e.seconds, v = v, k = k,
                    ours = v.civ_id == civ, k_ours = k and k.civ_id == civ or false,
                    k_race = e.slayer_race, cause = df.death_type[e.death_cause] or ''}
            end
        end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
    return out
end

local function battles(d)
    local list, cur = {}, nil
    for _, x in ipairs(d) do
        if cur and x.t - cur[#cur].t <= GAP then cur[#cur + 1] = x
        else cur = {x} list[#list + 1] = cur end
    end
    return list
end

local function report_of(b)
    local first, last = b[1], b[#b]
    local ours, enemies, by_race, beasts, slayers, enemy_civs = {}, 0, {}, {}, {}, {}
    for _, x in ipairs(b) do
        if x.ours then
            local by = x.k and (x.k_ours and hf_name(x.k) or (is_beast(x.k.race) and hf_name(x.k):match('^[^,]+') or race_of(x.k.race)))
                or (x.k_race ~= -1 and race_of(x.k_race)) or nil
            ours[#ours + 1] = {name = hf_name(x.v), job = profession(x.v), by = by, cause = x.cause:lower()}
        else
            enemies = enemies + 1
            local r = race_of(x.v.race, true)
            by_race[r] = (by_race[r] or 0) + 1
            if is_beast(x.v.race) then beasts[#beasts + 1] = hf_name(x.v):match('^[^,]+') end
            local ent = x.v.civ_id ~= -1 and df.historical_entity.find(x.v.civ_id)
            if ent then
                local n = dfhack.df2utf(dfhack.translation.translateName(ent.name, true))
                if n ~= '' then enemy_civs[n] = true end
            end
            if x.k and x.k_ours then
                local id = tostring(x.k.id)
                slayers[id] = slayers[id] or {name = hf_name(x.k), job = profession(x.k), kills = 0,
                    alive = x.k.died_year < 0}
                slayers[id].kills = slayers[id].kills + 1
            end
        end
    end
    local races = {}
    for r, n in pairs(by_race) do races[#races + 1] = {race = r, n = n} end
    table.sort(races, function(a, b) return a.n > b.n end)
    local top = {}
    for _, s in pairs(slayers) do top[#top + 1] = s end
    table.sort(top, function(a, b) return a.kills > b.kills end)
    local civs = {}
    for n in pairs(enemy_civs) do civs[#civs + 1] = n end
    local wounded = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        for _, w in ipairs(u.body.wounds) do
            local live = false
            for _, wp in ipairs(w.parts) do if (wp.bleeding or 0) > 0 or (wp.pain or 0) > 0 then live = true end end
            if live then wounded = wounded + 1 break end
        end
    end
    local span = last.t - first.t
    return {
        id = first.t,
        began = date(first.year, first.sec), ended = date(last.year, last.sec), year = first.year,
        hours = math.floor(span / 50 + 0.5),
        days_ago = math.floor((now_abs() - last.t) / 1200),
        enemy_dead = enemies, enemy_races = races, beasts = beasts, enemy_civs = civs,
        our_dead = ours, slayers = {table.unpack(top, 1, math.min(5, #top))},
        wounded_now = wounded,
    }
end

-- the fort's deadliest living citizens, lifetime kills
local function deadliest()
    local out = {}
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        local hf = u.hist_figure_id ~= -1 and df.historical_figure.find(u.hist_figure_id)
        local k = hf and hf.info and hf.info.kills
        if k then
            local n = #k.events
            for _, c in ipairs(k.killed_count) do n = n + c end
            if n > 0 then out[#out + 1] = {name = hf_name(hf), job = dfhack.df2utf(dfhack.units.getProfessionName(u)), kills = n} end
        end
    end
    table.sort(out, function(a, b) return a.kills > b.kills end)
    return {table.unpack(out, 1, math.min(6, #out))}
end

function run()
    local list = battles(deaths())
    local last
    for i = #list, 1, -1 do
        local b = list[i]
        local enemy = false
        for _, x in ipairs(b) do if not x.ours or (x.k and not x.k_ours) then enemy = true end end
        local slain = false
        for _, x in ipairs(b) do if x.k then slain = true end end
        if #b >= 2 and enemy and slain then last = b break end
    end
    local out = {ok = true, year = df.global.cur_year, deadliest = deadliest(), last = last and report_of(last) or nil}
    local f = io.open('dfhack-config/dfai-battle.json', 'w')
    if f then f:write(require('json').encode(out)) f:close() end
    return out
end

if dfhack_flags and dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() pcall(run) end)
    dfhack.timeout(1, 'ticks', function() pcall(run) end)
    print('battle report: started')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function()
        local ok, r = pcall(run)
        _G.dfai_battle_last = ok and (r.last and ('last battle %s: %d enemies dead, %d of ours'):format(r.last.began, r.last.enemy_dead, #r.last.our_dead) or 'no battle found') or ('error: ' .. tostring(r))
    end)
    print('battle report: queued')
else
    print('battle report: ' .. tostring(rawget(_G, 'dfai_battle_last') or 'not run yet'))
end
