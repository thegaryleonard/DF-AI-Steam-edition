-- dfai-war-office: the fort's squads raid the civilizations we are at war with.
--
--   dfai-war-office start|stop|status|now|list
--
-- Every squad raids once a month (SQUAD_EVERY days), one departure a day, HOME_GUARD squads stay home;
-- (now and then a pillage) against the nearest site governed by a civilization
-- targets rotate across every other civilization (ALL_CIVS), through the dfai_missions plugin.
-- squads abroad, never while a threat is on the map (the fort needs them), and
-- squads take turns. It does not declare wars by messenger; civs on the
-- antagonize list (user: "keep raiding them and antagonizing them") are raided
-- as if at war.
-- Runs on a game-tick timer, so it can never fire while the game is saving.
-- Record: dfhack.persistent (site) + dfhack-config/dfai-war.json for the Herald.

local json = require('json')
local repeatUtil = require('repeat-util')

local KEY = 'dfai-war-office'
-- user (end-of-fort phase): every squad raids once a month, targets rotate
-- round every civilization but our own, "make some enemies"
local SQUAD_EVERY = 28   -- game days between one squad's raids
local HOME_GUARD = 2     -- squads that always stay home
local ALL_CIVS = true    -- every other civilization is a target, not just enemies

local function plugin()
    local t = {}
    if pcall(dfhack.open_plugin, t, 'dfai_missions') and t.status and t.status() == 'ok' then return t end
end

local function name_of(x) return dfhack.df2utf(dfhack.translation.translateName(x.name, true)) end

local function members(sq)
    local out = {}
    for _, p in ipairs(sq.positions) do
        local hf = p.occupant ~= -1 and df.historical_figure.find(p.occupant)
        if hf then out[#out + 1] = {hf = hf.id, name = name_of(hf)} end
    end
    return out
end

local function civ_of(e)
    for _ = 1, 8 do
        if not e then return nil end
        if e.type == df.historical_entity_type.Civilization then return e end
        local up
        for _, l in ipairs(e.entity_links) do
            if l.type == 0 then up = df.historical_entity.find(l.target) if up then break end end
        end
        if not up then return e end
        e = up
    end
    return e
end

local function government(site)
    for _, l in ipairs(site.entity_links) do
        if l.flags.residence and l.type == 0 and l.start_hr == -1 then return df.historical_entity.find(l.entity_id) end
    end
end

local function enemies(s)
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    local out = {}
    if ALL_CIVS then
        for _, e in ipairs(df.global.world.entities.all) do
            if e.type == df.historical_entity_type.Civilization and e.id ~= civ.id and #e.site_links > 0 then
                out[e.id] = true
            end
        end
    end
    for cid in pairs((s and s.antagonize) or {}) do out[tonumber(cid)] = true end
    for _, st in ipairs(civ.relations.diplomacy.state) do
        if st.relation == df.diplomacy_state_type.TotalWar or st.relation == df.diplomacy_state_type.Skirmishing then
            out[st.group_id] = true
        end
    end
    return out
end

local function targets(foes)
    local me = dfhack.world.getCurrentSite()
    local list = {}
    for _, s in ipairs(df.global.world.world_data.sites) do
        local gov = government(s)
        local c = gov and civ_of(gov)
        if c and foes[c.id] and s.id ~= me.id then
            list[#list + 1] = {site = s, civ = c, dist = math.abs(s.pos.x - me.pos.x) + math.abs(s.pos.y - me.pos.y)}
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- the civ hit least recently, then its site hit least recently (nearest first on ties)
local function pick_target(s, tl)
    s.civ_turn = s.civ_turn or {}
    s.site_turn = s.site_turn or {}
    local best, bk
    for i, t in ipairs(tl) do
        local k = {s.civ_turn[tostring(t.civ.id)] or 0, s.site_turn[tostring(t.site.id)] or 0, i}
        if not best or k[1] < bk[1] or (k[1] == bk[1] and (k[2] < bk[2] or (k[2] == bk[2] and k[3] < bk[3]))) then
            best, bk = t, k
        end
    end
    return best
end

local function threat_on_map()
    local ok, tour = pcall(reqscript, 'dfai-room-tour')
    if not ok or not tour.is_threat_check then return false end
    for _, u in ipairs(df.global.world.units.active) do
        local ok2, th = pcall(tour.is_threat_check, u)
        if ok2 and th then return true end
    end
    return false
end

local function squad_ready(sq)
    if sq.entity_id ~= df.global.plotinfo.group_id or sq.assigned_army_controller_id ~= -1 then return false end
    local n = 0
    for _, p in ipairs(sq.positions) do
        if p.occupant ~= -1 then
            local hf = df.historical_figure.find(p.occupant)
            local u = hf and df.unit.find(hf.unit_id)
            if not u or not dfhack.units.isActive(u) or u.flags1.left or u.mood ~= -1 or u.health and u.health.flags.needs_healthcare then return false end
            n = n + 1
        end
    end
    return n >= 5
end

local function load_state()
    local s = dfhack.persistent.getSiteData(KEY, {})
    s.sent = s.sent or {}       -- squad id -> {year, tick, site, civ, mode}
    s.log = s.log or {}
    s.turn = s.turn or {}       -- squad id -> last year*403200+tick sent
    s.last_event = s.last_event or -1
    return s
end

local function now_abs() return df.global.cur_year * 403200 + df.global.cur_year_tick end

local function save_state(s)
    dfhack.persistent.saveSiteData(KEY, s)
    local site = dfhack.world.getCurrentSite()
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/dfai-war.json', 'w')
    if f then
        f:write(json.encode({site_id = site and site.id or -1, year = df.global.cur_year, log = s.log}))
        f:close()
    end
end

-- results: history events where our fort's group attacked
local function read_results(s)
    local fe = df.global.plotinfo.group_id
    local ev = df.global.world.history.events
    local newest = s.last_event
    for i = #ev - 1, math.max(0, #ev - 3000), -1 do
        local e = ev[i]
        if e.id <= s.last_event then break end
        newest = math.max(newest, e.id)
        local t = e:getType()
        local here = dfhack.world.getCurrentSite()
        if (t == df.history_event_type.WAR_ATTACKED_SITE or t == df.history_event_type.WAR_PLUNDERED_SITE)
                and here and e.site == here.id and e.attacker_civ ~= fe then
            local att = df.historical_entity.find(e.attacker_civ)
            local c = att and civ_of(att)
            table.insert(s.log, {year = e.year, kind = 'attacked_us', civ = c and name_of(c) or (att and name_of(att)) or '?',
                what = t == df.history_event_type.WAR_PLUNDERED_SITE and 'plundered' or 'attacked'})
        elseif (t == df.history_event_type.WAR_PLUNDERED_SITE or t == df.history_event_type.WAR_ATTACKED_SITE
                or t == df.history_event_type.WAR_FIELD_BATTLE or t == df.history_event_type.WAR_DESTROYED_SITE)
                and e.attacker_civ == fe then
            local site = df.world_site.find(e.site)
            local def = df.historical_entity.find(e.defender_civ)
            local what = ({[df.history_event_type.WAR_PLUNDERED_SITE] = 'plundered', [df.history_event_type.WAR_ATTACKED_SITE] = 'attacked',
                [df.history_event_type.WAR_FIELD_BATTLE] = 'fought a battle near', [df.history_event_type.WAR_DESTROYED_SITE] = 'destroyed'})[t]
            table.insert(s.log, {year = e.year, kind = 'result', what = what, site = site and name_of(site) or '?',
                civ = def and name_of(def) or '?'})
        end
    end
    s.last_event = newest
    -- squads home again
    for sid, m in pairs(s.sent) do
        local sq = df.squad.find(tonumber(sid))
        if not sq or sq.assigned_army_controller_id == -1 then
            s.sent[sid] = nil
            local alive, total, lost = 0, 0, {}
            for _, mem in ipairs(m.members or {}) do
                total = total + 1
                local hf = df.historical_figure.find(mem.hf)
                if hf and hf.died_year == -1 then alive = alive + 1 else lost[#lost + 1] = mem.name end
            end
            table.insert(s.log, {year = df.global.cur_year, kind = 'home', squad = m.squad, squad_id = tonumber(sid), site = m.site, civ = m.civ, mode = m.mode,
                alive = alive, total = total, lost = lost, leader = m.leader, members = m.names, at_war = m.at_war})
        end
    end
    while #s.log > 30 do table.remove(s.log, 1) end
end

function step(force)
    local p = plugin()
    if not p then return 'dfai_missions not ready' end
    local s = load_state()
    read_results(s)
    -- 'hold': every squad stays home (a beast fight coming); returns still logged
    if s.hold then save_state(s) return 'holding: the army stays home (' .. tostring(s.hold) .. ')' end
    local out, total = 0, 0
    for _ in pairs(s.sent) do out = out + 1 end
    for _, sq in ipairs(df.global.world.squads.all) do
        if sq.entity_id == df.global.plotinfo.group_id then total = total + 1 end
    end
    if out >= total - HOME_GUARD then save_state(s) return ('%d squads abroad, %d stay home'):format(out, HOME_GUARD) end
    if threat_on_map() then save_state(s) return 'threat on the map: squads stay home' end
    local foes = enemies(s)
    local tl = targets(foes)
    if #tl == 0 then save_state(s) return 'no enemy sites' end
    -- the squad that waited longest, if its month at home is up
    local best, bt
    for _, sq in ipairs(df.global.world.squads.all) do
        if squad_ready(sq) then
            local t = s.turn[tostring(sq.id)] or 0
            if (force or now_abs() - t >= SQUAD_EVERY * 1200) and (not best or t < bt) then best, bt = sq, t end
        end
    end
    if not best then save_state(s) return 'no squad due' end
    local tg = pick_target(s, tl)
    s.civ_turn[tostring(tg.civ.id)] = now_abs()
    s.site_turn[tostring(tg.site.id)] = now_abs()
    local mode = (math.random() < 0.25) and 'pillage' or 'raid'
    local id = p.invade(tg.site.id, tostring(best.id), mode)
    if not id or id < 0 then save_state(s) return 'mission refused for ' .. name_of(tg.site) end
    local sqname = name_of(best)
    if sqname == '' then
        local cap = best.positions[0] and best.positions[0].occupant ~= -1 and df.historical_figure.find(best.positions[0].occupant)
        sqname = cap and (dfhack.df2utf(dfhack.translation.translateName(cap.name, false)):match('^(%S+)') .. "'s Squad") or ('Squad ' .. best.id)
    end
    local mem = members(best)
    local names = {}
    for _, x in ipairs(mem) do names[#names + 1] = x.name end
    local at_war = not (s.antagonize or {})[tostring(tg.civ.id)]
    s.sent[tostring(best.id)] = {year = df.global.cur_year, site = name_of(tg.site), civ = name_of(tg.civ), mode = mode, squad = sqname, squad_id = best.id,
        members = mem, names = names, leader = names[1], at_war = at_war}
    s.turn[tostring(best.id)] = now_abs()
    table.insert(s.log, {year = df.global.cur_year, kind = 'left', squad = sqname, site = name_of(tg.site), civ = name_of(tg.civ), mode = mode,
        leader = names[1], members = names, at_war = at_war, site_type = df.world_site_type[tg.site.type], squad_id = best.id})
    save_state(s)
    return ('sent %s to %s %s (%s)'):format(sqname, mode, name_of(tg.site), name_of(tg.civ))
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_war_last = ok and res or ('error: ' .. tostring(res))
end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    -- first check on the next game day (never from the console: a save may be running)
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick) -- check daily
    print('war office: started')
elseif cmd == 'hold' then
    local why = table.concat({select(2, ...)}, ' ')
    dfhack.timeout(1, 'ticks', function()
        local st = load_state()
        st.hold = why ~= '' and why or 'held'
        save_state(st)
    end)
    print('war office: holding all squads at home')
elseif cmd == 'resume' then
    dfhack.timeout(1, 'ticks', function()
        local st = load_state()
        st.hold = nil
        save_state(st)
    end)
    print('war office: raids resume')
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    print('war office stopped')
elseif cmd == 'now' then
    -- run on the next game tick (never from the console thread mid-save); with
    -- 'follow', the camera follows the squad's first soldier for 4 minutes
    local follow = ({...})[2] == 'follow'
    dfhack.timeout(1, 'ticks', function()
        local ok, res = pcall(step, true)
        _G.dfai_war_last = ok and res or ('error: ' .. tostring(res))
        if not (ok and follow and tostring(res):find('^sent')) then return end
        for sid in pairs(load_state().sent) do
            local sq = df.squad.find(tonumber(sid))
            for _, p in ipairs(sq and sq.positions or {}) do
                local hf = p.occupant ~= -1 and df.historical_figure.find(p.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u and dfhack.units.isActive(u) then
                    dfhack.run_command_silent('disable', 'spectate')
                    df.global.plotinfo.follow_unit = u.id
                    _G.dfai_war_follow = u.id
                    dfhack.timeout(4800, 'frames', function() dfhack.run_command_silent('enable', 'spectate') end)
                    return
                end
            end
        end
    end)
    print('war office: queued for the next game tick')
elseif cmd == 'antagonize' then
    local s = load_state()
    s.antagonize = s.antagonize or {}
    local id = tonumber(({...})[2])
    local e = id and df.historical_entity.find(id)
    if not e then print('usage: dfai-war-office antagonize <civ id>') return end
    s.antagonize[tostring(id)] = df.global.cur_year
    save_state(s)
    print('antagonizing ' .. name_of(e))
elseif cmd == 'list' then
    for _, t in ipairs(targets(enemies(load_state()))) do print(t.site.id, name_of(t.site), df.world_site_type[t.site.type], name_of(t.civ), t.dist) end
    for _, l in ipairs(load_state().log) do print('log', json.encode(l)) end
else
    print('war office last: ' .. tostring(_G.dfai_war_last))
end
