-- dfai-recap <since_abs_tick>: what happened at the fort since a game time,
-- for the Herald's editions and the Recent News card (overlay.py remembers
-- the game time of each real-world half hour). One JSON line.
-- Every dated item carries {y, s} (year, season 0-3) so the Herald can tell
-- it as a story in order, not a pile.

local json = require('json')
local since = tonumber(({...})[1]) or 0
local site, civ = df.global.plotinfo.site_id, df.global.plotinfo.civ_id
local function T(y, s) return y * 403200 + s end
local function season(sec) return math.max(0, math.min(3, sec // 100800)) end
local function nm(hf)
    if not hf then return '?' end
    local n = dfhack.translation.translateName(hf.name, true)
    if n == '' then local r = df.creature_raw.find(hf.race) n = r and r.name[0] or '?' end
    return dfhack.df2utf((n:gsub(' the .*$', '')))
end
-- what a creature is, in a word or two: "forgotten beast", "goblin", "giant rat"
local function kind(race)
    local r = df.creature_raw.find(race)
    if not r then return nil end
    if r.flags.HAS_ANY_FEATURE_BEAST then return 'forgotten beast' end
    if r.flags.HAS_ANY_TITAN then return 'titan' end
    if r.flags.HAS_ANY_MEGABEAST then return dfhack.df2utf(r.name[0]) end
    if r.flags.HAS_ANY_DEMON then return 'demon' end
    if r.flags.HAS_ANY_NIGHT_CREATURE then return 'night creature' end
    return dfhack.df2utf(r.name[0])
end
local function job(hf)
    local u = hf and hf.unit_id ~= -1 and df.unit.find(hf.unit_id)
    if u then
        local ok, p = pcall(dfhack.units.getProfessionName, u)
        if ok and p and p ~= '' then return dfhack.df2utf(p:lower()) end
    end
end
local function mine(hf) return hf and hf.civ_id == civ and hf.race == df.global.plotinfo.race_id end
-- one of our animals with a name of its own: counted among the fort's dead
local function named_pet(hf)
    if not hf or hf.civ_id ~= civ or hf.race == df.global.plotinfo.race_id then return false end
    if dfhack.translation.translateName(hf.name, true) ~= '' then return true end
    local u = hf.unit_id ~= -1 and df.unit.find(hf.unit_id)
    return u and u.name.nickname ~= '' or false
end
local out = {deaths = {}, enemy_dead = 0, enemy_kinds = {}, beasts = {}, beast_kinds = {}, artifacts = {}, artifact_info = {}, births = 0, raids = {},
    marriages = {}, nobles = {}, masterpieces = 0, killers = {},
    now = T(df.global.cur_year, df.global.cur_year_tick),
    from = {y = since // 403200, s = season(since % 403200)}, to = {y = df.global.cur_year, s = season(df.global.cur_year_tick)}}
local ev = df.global.world.history.events
local stop_year = math.floor(since / 403200)
local enemy_kinds, killers = {}, {}
local HT = df.history_event_type
for i = #ev - 1, 0, -1 do
    local e = ev[i]
    if e.year < stop_year then break end
    if T(e.year, e.seconds) >= since then
        local t = e:getType()
        local when = {y = e.year, s = season(e.seconds)}
        if t == HT.HIST_FIGURE_DIED and e.site == site then
            local v = df.historical_figure.find(e.victim_hf)
            local cause = df.death_type[e.death_cause] or ''
            local pet = named_pet(v)
            if (mine(v) or pet) and cause ~= 'OLD_AGE' and cause ~= 'MEMORIALIZE' and cause ~= 'SLAUGHTER' then
                local k = e.slayer_hf ~= -1 and df.historical_figure.find(e.slayer_hf) or nil
                local krace = k and k.race or e.slayer_race
                local by = k and nm(k) or nil
                local bykind = krace ~= -1 and kind(krace) or nil
                if by and bykind and by:lower() == bykind:lower() then by = nil end
                local pu = pet and v.unit_id ~= -1 and df.unit.find(v.unit_id)
                out.deaths[#out.deaths + 1] = {name = (pu and pu.name.nickname ~= '') and dfhack.df2utf(pu.name.nickname) or nm(v),
                    job = pet and kind(v.race) or job(v), pet = pet or nil, by = by, by_kind = bykind,
                    friendly = (k and mine(k)) and true or nil, cause = cause:lower(), y = when.y, s = when.s}
                if by then
                    killers[by] = killers[by] or {name = by, kind = bykind, n = 0}
                    killers[by].n = killers[by].n + 1
                end
            elseif v and not mine(v) and e.slayer_hf ~= -1 then
                -- only our dwarves' kills are the defenders' (cave creatures
                -- kill forgotten beasts too: a gorlak got one at Fortresstome)
                local kd = kind(v.race) or '?'
                if mine(df.historical_figure.find(e.slayer_hf)) then
                    out.enemy_dead = out.enemy_dead + 1
                    enemy_kinds[kd] = (enemy_kinds[kd] or 0) + 1
                end
                local r = df.creature_raw.find(v.race)
                if r and (r.flags.HAS_ANY_FEATURE_BEAST or r.flags.HAS_ANY_MEGABEAST or r.flags.HAS_ANY_TITAN) then
                    local sl = df.historical_figure.find(e.slayer_hf)
                    out.beasts[#out.beasts + 1] = nm(v)
                    out.beast_kinds[#out.beast_kinds + 1] = {name = nm(v), kind = kd, by = sl and nm(sl) or nil, by_ours = (sl and mine(sl)) and true or nil,
                        by_kind = (sl and not mine(sl)) and kind(sl.race) or nil, y = when.y, s = when.s}
                end
            end
        elseif t == HT.ARTIFACT_CREATED and e.site == site then
            local a = df.artifact_record.find(e.artifact_id)
            if a then
                local name = dfhack.df2utf(dfhack.translation.translateName(a.name, true))
                out.artifacts[#out.artifacts + 1] = name
                local maker = df.historical_figure.find(e.creator_hfid)
                local okd, desc = pcall(function() return a.item and dfhack.df2utf(dfhack.items.getReadableDescription(a.item)) end)
                out.artifact_info[#out.artifact_info + 1] = {name = name, by = maker and nm(maker) or nil, item = okd and desc or nil, y = when.y, s = when.s}
            end
        elseif t == HT.ADD_HF_HF_LINK and e.type == df.histfig_hf_link_type.SPOUSE then
            local a, b = df.historical_figure.find(e.hf), df.historical_figure.find(e.hf_target)
            if mine(a) and mine(b) and #out.marriages < 6 then out.marriages[#out.marriages + 1] = {a = nm(a), b = nm(b), y = when.y, s = when.s} end
        elseif t == HT.ADD_HF_ENTITY_LINK and e.link_type == df.histfig_entity_link_type.POSITION then
            local h = df.historical_figure.find(e.histfig)
            local en = df.historical_entity.find(e.civ)
            if mine(h) and en and (en.id == civ or en.id == df.global.plotinfo.group_id) and #out.nobles < 6 then
                local pos
                for _, p in ipairs(en.positions.own) do if p.id == e.position_id then pos = p.name[0] break end end
                if pos and pos ~= '' then out.nobles[#out.nobles + 1] = {name = nm(h), title = dfhack.df2utf(pos), y = when.y, s = when.s} end
            end
        elseif t == HT.MASTERPIECE_CREATED_ITEM and e.site == site then
            out.masterpieces = out.masterpieces + 1
        end
    end
end
-- the events were read newest first; tell them oldest first
local function rev(t) local r = {} for i = #t, 1, -1 do r[#r + 1] = t[i] end return r end
for _, k in ipairs({'deaths', 'beasts', 'beast_kinds', 'artifacts', 'artifact_info', 'marriages', 'nobles'}) do out[k] = rev(out[k]) end
for k, n in pairs(enemy_kinds) do out.enemy_kinds[#out.enemy_kinds + 1] = {kind = k, n = n} end
table.sort(out.enemy_kinds, function(a, b) return a.n > b.n end)
for _, k in pairs(killers) do out.killers[#out.killers + 1] = k end
table.sort(out.killers, function(a, b) return a.n > b.n end)
-- births: citizens younger than the window
for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if T(u.birth_year, u.birth_time) >= since then out.births = out.births + 1 end
end
-- raids sent in the window: the war office notes when each squad last set out
local W = dfhack.persistent.getSiteData('dfai-war-office', {})
for sid, at in pairs(W.turn or {}) do
    if at >= since then
        local sq = df.squad.find(tonumber(sid))
        local n = sq and (sq.alias ~= '' and sq.alias or dfhack.df2utf(dfhack.translation.translateName(sq.name, true))) or ''
        out.raids[#out.raids + 1] = n ~= '' and n or ('squad ' .. sid)
    end
end
out.pop = #dfhack.units.getCitizens(true)
print(json.encode(out))
