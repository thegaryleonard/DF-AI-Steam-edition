-- dfai-foreign-office: the fort's messengers make contact and keep trade sweet.
--
--   dfai-foreign-office start|stop|status|now|list
--
-- Once a game month (and on fort load) it looks for a free messenger and
-- sends ONE diplomatic mission through the dfai_missions plugin (no screens,
-- no mouse):
--   * a peaceful human, elven or dwarven civilization we have no contact with
--     gets "open trade" (first contact: they start sending caravans);
--   * a contacted foreign civilization gets "improve trade" once a year
--     (bigger caravans, better moods); our own Mountainhome can't be improved.
-- Nearest civilizations first. Goblins don't trade; at-war civs are skipped
-- (war is for later: 200+ citizens and metal armor, and only after they
-- offend us first).
-- Record kept in the save (dfhack.persistent) and mirrored to
-- dfhack-config/dfai-foreign.json for the Herald.

local json = require('json')
local repeatUtil = require('repeat-util')

local KEY = 'dfai-foreign-office'
local TOPIC_OPEN, TOPIC_IMPROVE = 15, 16
local TRADING_RACES = {HUMAN = true, ELF = true, DWARF = true}

local function plugin()
    local t = {}
    if pcall(dfhack.open_plugin, t, 'dfai_missions') and t.status and t.status() == 'ok' then return t end
end

local function load_state()
    local s = dfhack.persistent.getSiteData(KEY, {})
    s.contact = s.contact or {}
    s.improved = s.improved or {}
    s.sent = s.sent or {}
    s.log = s.log or {}
    s.scanned = s.scanned or false
    s.badsite = s.badsite or {}
    return s
end

local function save_state(s)
    dfhack.persistent.saveSiteData(KEY, s)
    local site = dfhack.world.getCurrentSite()
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/dfai-foreign.json', 'w')
    if f then
        f:write(json.encode({site_id = site and site.id or -1, year = df.global.cur_year, log = s.log, contact = s.contact}))
        f:close()
    end
end

local function name_of(e) return dfhack.df2utf(dfhack.translation.translateName(e.name, true)) end   -- utf-8: these go into the saved JSON (cp437 there broke the reader)

-- first contacts already in the world history (one bounded scan per fort)
local function scan_contacts(s)
    local civ = df.global.plotinfo.civ_id
    local ev = df.global.world.history.events
    local t0 = os.clock()
    for i = #ev - 1, math.max(0, #ev - 400000), -1 do
        local e = ev[i]
        if e:getType() == df.history_event_type.FIRST_CONTACT then
            if e.contactor == civ then s.contact[tostring(e.contacted)] = e.year
            elseif e.contacted == civ then s.contact[tostring(e.contactor)] = e.year end
        end
        if os.clock() - t0 > 3 then break end
    end
    s.scanned = true
end

-- outcomes: "<messenger> has returned. ... made contact with <civ> ... The proposal was ..."
local function read_reports(s)
    local reports = df.global.world.status.reports
    local last = s.last_report or -1
    local newest = last
    for i = #reports - 1, math.max(0, #reports - 4000), -1 do
        local r = reports[i]
        if r.id <= last then break end
        newest = math.max(newest, r.id)
        local txt = dfhack.df2utf(r.text)
        if txt:find('messenger has returned') or txt:find('The proposal was') then
            table.insert(s.log, {year = r.year, text = txt})
            local bad = txt:match('no suitable representatives in (.-)%.')
            if bad then s.badsite[bad] = r.year end
            for cid, sent in pairs(s.sent) do
                local e = df.historical_entity.find(tonumber(cid))
                if e and txt:find(name_of(e), 1, true) then
                    if txt:find('made contact') then s.contact[cid] = r.year end
                    if sent.topic == TOPIC_IMPROVE then s.improved[cid] = r.year end
                    s.sent[cid] = nil
                end
            end
        end
    end
    s.last_report = newest
    while #s.log > 20 do table.remove(s.log, 1) end
end

local function nearest_site(e, me, bad)
    local best, bd
    for _, l in ipairs(e.site_links) do
        local site = df.world_site.find(l.target)
        -- skip sites where an envoy found nobody to talk to (within 3 years)
        local b = site and bad[name_of(site)]
        if site and (l.flags.residence or l.flags.capital) and not (b and df.global.cur_year - b < 3) then
            local d = math.abs(site.pos.x - me.pos.x) + math.abs(site.pos.y - me.pos.y)
            if not bd or d < bd then best, bd = site, d end
        end
    end
    return best, bd
end

local function free_messenger()
    local fe = df.global.plotinfo.main.fortress_entity
    if not fe then return end
    for _, epp in ipairs(fe.assignments_by_type.DELIVER_MESSAGES) do
        if epp.histfig ~= -1 and epp.assigned_army_controller_id == -1 then
            local hf = df.historical_figure.find(epp.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u and dfhack.units.isActive(u) and not u.flags1.left and u.mood == -1 then return epp, hf end
        end
    end
end

function step(force)
    local p = plugin()
    if not p then return 'dfai_missions not ready' end
    local s = load_state()
    if not s.scanned then scan_contacts(s) end
    read_reports(s)

    local me = dfhack.world.getCurrentSite()
    local ourciv = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not me or not ourciv then save_state(s) return 'no fort' end
    local okp_, pri_ = pcall(reqscript, 'dfai-priorities')
    if okp_ then
        local go_, why_ = pri_.allowed('outreach')
        if not go_ then save_state(s) return 'on hold: ' .. tostring(why_) end
    end
    -- user: "no messenger dispatch until 100 population. give the fort time
    -- to grow before announcing your presence" (returning messengers'
    -- reports above are still read)
    local pop = #dfhack.units.getCitizens(true)
    if pop < 100 then save_state(s) return ('no messengers until the fort has 100 citizens (%d now)'):format(pop) end
    local epp, hf = free_messenger()
    if not epp then save_state(s) return 'no free messenger' end

    local year = df.global.cur_year
    local choices = {}
    for _, st in ipairs(ourciv.relations.diplomacy.state) do
        local e = df.historical_entity.find(st.group_id)
        local race = e and df.creature_raw.find(e.race)
        if e and e.type == df.historical_entity_type.Civilization and e.id ~= ourciv.id and race
                and TRADING_RACES[race.creature_id] and st.relation == df.diplomacy_state_type.Peace then
            local cid = tostring(e.id)
            local sent = s.sent[cid]
            if not (sent and year - sent.year < 2) then -- one outstanding mission per civ (2 years grace)
                local site, dist = nearest_site(e, me, s.badsite)
                if site then
                    if not s.contact[cid] then
                        table.insert(choices, {e = e, site = site, dist = dist, topic = TOPIC_OPEN})
                    elseif (s.improved[cid] or -1) < year then
                        table.insert(choices, {e = e, site = site, dist = dist + 1000, topic = TOPIC_IMPROVE})
                    end
                end
            end
        end
    end
    table.sort(choices, function(a, b) return a.dist < b.dist end)
    local c = choices[1]
    if not c then save_state(s) return 'nothing to do' end

    local id = p.messenger(c.site.id, epp.id, tostring(c.topic))
    if not id or id < 0 then save_state(s) return 'mission refused for ' .. name_of(c.e) end
    s.sent[tostring(c.e.id)] = {year = year, topic = c.topic, ac = id}
    local what = (c.topic == TOPIC_OPEN and 'open trade with ' or 'improve trade with ') .. name_of(c.e)
    table.insert(s.log, {year = year, text = ('%s set out for %s to %s.'):format(
        dfhack.df2utf(dfhack.translation.translateName(hf.name, true)), dfhack.df2utf(dfhack.translation.translateName(c.site.name, true)), what)})
    save_state(s)
    return 'sent: ' .. what
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_foreign_last = ok and res or ('error: ' .. tostring(res))
end

local args = {...}
local cmd = args[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 28 * 1200, 'ticks', tick) -- monthly
    tick()
    print('foreign office: ' .. tostring(_G.dfai_foreign_last))
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    print('foreign office stopped')
elseif cmd == 'now' then
    tick()
    print('foreign office: ' .. tostring(_G.dfai_foreign_last))
elseif cmd == 'list' then
    local s = load_state()
    print('contacts:') for k, v in pairs(s.contact) do local e = df.historical_entity.find(tonumber(k)) print('  ' .. (e and name_of(e) or k), v) end
    print('outstanding:') for k, v in pairs(s.sent) do print('  ', k, v.year, v.topic) end
    for _, l in ipairs(s.log) do print('  log', l.year, l.text) end
else
    print('foreign office last: ' .. tostring(_G.dfai_foreign_last))
end
