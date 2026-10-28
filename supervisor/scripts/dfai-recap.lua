-- dfai-recap <since_abs_tick>: what happened at the fort since a game time,
-- for the Herald's "While You Slept" (overlay.py remembers the game time of
-- each real-world half hour). One JSON line.

local json = require('json')
local since = tonumber(({...})[1]) or 0
local site, civ = df.global.plotinfo.site_id, df.global.plotinfo.civ_id
local function T(y, s) return y * 403200 + s end
local function nm(hf)
    if not hf then return '?' end
    local n = dfhack.translation.translateName(hf.name, true)
    if n == '' then local r = df.creature_raw.find(hf.race) n = r and r.name[0] or '?' end
    return dfhack.df2utf((n:gsub(' the .*$', '')))
end
local out = {deaths = {}, enemy_dead = 0, beasts = {}, artifacts = {}, births = 0, raids = {}, now = T(df.global.cur_year, df.global.cur_year_tick)}
local ev = df.global.world.history.events
local stop_year = math.floor(since / 403200)
for i = #ev - 1, 0, -1 do
    local e = ev[i]
    if e.year < stop_year then break end
    if T(e.year, e.seconds) >= since then
        local t = e:getType()
        if t == df.history_event_type.HIST_FIGURE_DIED and e.site == site then
            local v = df.historical_figure.find(e.victim_hf)
            local cause = df.death_type[e.death_cause] or ''
            if v and v.civ_id == civ and v.race == df.global.plotinfo.race_id and cause ~= 'OLD_AGE' and cause ~= 'MEMORIALIZE' then
                local k = e.slayer_hf ~= -1 and df.historical_figure.find(e.slayer_hf)
                local kr = e.slayer_race ~= -1 and df.creature_raw.find(e.slayer_race)
                out.deaths[#out.deaths + 1] = {name = nm(v), by = k and nm(k) or (kr and dfhack.df2utf(kr.name[0])) or nil, cause = cause:lower()}
            elseif v and v.civ_id ~= civ and e.slayer_hf ~= -1 then
                out.enemy_dead = out.enemy_dead + 1
                local r = df.creature_raw.find(v.race)
                if r and (r.flags.HAS_ANY_FEATURE_BEAST or r.flags.HAS_ANY_MEGABEAST or r.flags.HAS_ANY_TITAN) then out.beasts[#out.beasts + 1] = nm(v) end
            end
        elseif t == df.history_event_type.ARTIFACT_CREATED and e.site == site then
            local a = df.artifact_record.find(e.artifact_id)
            if a then out.artifacts[#out.artifacts + 1] = dfhack.df2utf(dfhack.translation.translateName(a.name, true)) end
        end
    end
end
-- births: citizens younger than the window
for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if T(u.birth_year, u.birth_time) >= since then out.births = out.births + 1 end
end
-- raids sent in the window: the war office notes when each squad last set out
local W = dfhack.persistent.getSiteData('dfai-war-office', {})
for sid, at in pairs(W.turn or {}) do
    if at >= since then
        local sq = df.squad.find(tonumber(sid))
        local nm = sq and (sq.alias ~= '' and sq.alias or dfhack.df2utf(dfhack.translation.translateName(sq.name, true))) or ''
        out.raids[#out.raids + 1] = nm ~= '' and nm or ('squad ' .. sid)
    end
end
out.pop = #dfhack.units.getCitizens(true)
print(json.encode(out))
