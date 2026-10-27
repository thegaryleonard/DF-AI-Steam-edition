-- dfai-war-office: the fort's squads raid the civilizations we are at war with.
--
--   dfai-war-office start|stop|status|now|list
--
-- Every WAR_EVERY game days (and on start) it sends ONE free squad on a raid
-- (now and then a pillage) against the nearest site governed by a civilization
-- at war with us, through the dfai_missions plugin. Never more than MAX_OUT
-- squads abroad, never while a threat is on the map (the fort needs them), and
-- squads take turns. It does not declare wars by messenger; civs on the
-- antagonize list (user: "keep raiding them and antagonizing them") are raided
-- as if at war.
-- Runs on a game-tick timer, so it can never fire while the game is saving.
-- Record: dfhack.persistent (site) + dfhack-config/dfai-war.json for the Herald.

local json = require('json')
local repeatUtil = require('repeat-util')

local KEY = 'dfai-war-office'
local WAR_EVERY = 2 * 28 -- game days between new missions
local MAX_OUT = 1

local function plugin()
    local t = {}
    if pcall(dfhack.open_plugin, t, 'dfai_missions') and t.status and t.status() == 'ok' then return t end
end

local function name_of(x) return dfhack.df2utf(dfhack.translation.translateName(x.name, true)) end

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
        if (t == df.history_event_type.WAR_PLUNDERED_SITE or t == df.history_event_type.WAR_ATTACKED_SITE
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
            local alive, total = 0, 0
            if sq then
                for _, p in ipairs(sq.positions) do
                    if p.occupant ~= -1 then
                        total = total + 1
                        local hf = df.historical_figure.find(p.occupant)
                        if hf and hf.died_year == -1 then alive = alive + 1 end
                    end
                end
            end
            table.insert(s.log, {year = df.global.cur_year, kind = 'home', squad = m.squad, site = m.site, alive = alive, total = total})
        end
    end
    while #s.log > 30 do table.remove(s.log, 1) end
end

function step(force)
    local p = plugin()
    if not p then return 'dfai_missions not ready' end
    local s = load_state()
    read_results(s)
    local out = 0
    for _ in pairs(s.sent) do out = out + 1 end
    if out >= MAX_OUT then save_state(s) return 'squad already abroad' end
    if not force and s.next_at and now_abs() < s.next_at then save_state(s) return 'resting' end
    if threat_on_map() then save_state(s) return 'threat on the map: squads stay home' end
    local foes = enemies(s)
    local tl = targets(foes)
    if #tl == 0 then save_state(s) return 'no enemy sites' end
    -- the squad that waited longest
    local best, bt
    for _, sq in ipairs(df.global.world.squads.all) do
        if squad_ready(sq) then
            local t = s.turn[tostring(sq.id)] or 0
            if not best or t < bt then best, bt = sq, t end
        end
    end
    if not best then save_state(s) return 'no squad ready' end
    local tg = tl[1]
    local mode = (math.random() < 0.25) and 'pillage' or 'raid'
    local id = p.invade(tg.site.id, tostring(best.id), mode)
    if not id or id < 0 then save_state(s) return 'mission refused for ' .. name_of(tg.site) end
    local sqname = name_of(best)
    if sqname == '' then sqname = 'Squad ' .. best.id end
    s.sent[tostring(best.id)] = {year = df.global.cur_year, site = name_of(tg.site), civ = name_of(tg.civ), mode = mode, squad = sqname}
    s.turn[tostring(best.id)] = now_abs()
    s.next_at = now_abs() + WAR_EVERY * 1200
    table.insert(s.log, {year = df.global.cur_year, kind = 'left', squad = sqname, site = name_of(tg.site), civ = name_of(tg.civ), mode = mode})
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
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick) -- check daily; missions every WAR_EVERY days
    print('war office: started')
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
