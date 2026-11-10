-- dfai-tantrum-guard: a soldier who loses it is taken out of his squad at
-- once, before he turns his weapon on the fort (user, after Ast Orangelance
-- "the Creative Champion" killed 6 citizens in one day with an iron mace:
-- "take any soldier in a tantrum/berserk/insane state off duty").
--
-- Every 50 ticks: any citizen in a fort squad who is throwing a tantrum or
-- enraged (unit.counters.soldier_mood), berserk, raving, or otherwise insane
-- leaves the squad (dfhack.military.removeFromSquad: no kill orders, the
-- uniform goes back). df-ai's draft skips anyone in such a state, so he is
-- only drafted again once he has calmed down. Martial trance is a fighting
-- state, not a breakdown, and is left alone.
--   dfai-tantrum-guard start | stop | status | test
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-tantrum-guard'
local SM = df.soldier_mood_type
local BAD_SOLDIER_MOOD = {[SM.Tantrum] = 'throwing a tantrum', [SM.Enraged] = 'enraged'}
local BAD_MOOD = {[df.mood_type.Berserk] = 'berserk', [df.mood_type.Raving] = 'raving mad',
    [df.mood_type.Melancholy] = 'stricken by melancholy', [df.mood_type.Traumatized] = 'traumatized'}

G = rawget(_G, 'dfai_tantrum_guard') or {last = 'watching', benched = 0}
rawset(_G, 'dfai_tantrum_guard', G)

local function name(u) return dfhack.df2utf(dfhack.units.getReadableName(u)) end

-- why this soldier must come off duty now, or nil
function breakdown(u)
    local sm = u.counters.soldier_mood
    if BAD_SOLDIER_MOOD[sm] then return BAD_SOLDIER_MOOD[sm] end
    if BAD_MOOD[u.mood] then return BAD_MOOD[u.mood] end
    if not dfhack.units.isSane(u) then return 'not in his right mind' end
end

local function step(dry)
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local out = {}
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if u.military.squad_id ~= -1 then
            local why = breakdown(u)
            if why then
                out[#out + 1] = ('%s (%s)'):format(name(u), why)
                if not dry then
                    local sq = df.squad.find(u.military.squad_id)
                    if dfhack.military.removeFromSquad(u.id) then
                        G.benched = G.benched + 1
                        local s = dfhack.persistent.getSiteData(KEY, {log = {}})
                        table.insert(s.log, 1, {unit = u.id, name = name(u), why = why, squad = sq and sq.id or -1,
                            year = df.global.cur_year, tick = df.global.cur_year_tick})
                        while #s.log > 20 do table.remove(s.log) end
                        dfhack.persistent.saveSiteData(KEY, s)
                        dfhack.gui.showAnnouncement(dfhack.utf2df(('%s is %s and has been taken off duty.'):format(name(u):gsub(',.*$', ''), why)), COLOR_YELLOW, false)
                        G.last = ('took %s off duty: %s'):format(name(u):gsub(',.*$', ''), why)
                    end
                end
            end
        end
    end
    return out
end

function status()
    local s = dfhack.persistent.getSiteData(KEY, {log = {}})
    local l = s.log[1]
    return ('tantrum guard: %s; %d off duty since load%s'):format(G.on and 'watching the squads' or 'off', G.benched,
        l and ('; last: %s (%s) in %d'):format(l.name:gsub(',.*$', ''), l.why, l.year) or '; nobody taken off duty yet')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    G.on = true
    repeatUtil.scheduleEvery(KEY, 50, 'ticks', function() local ok, e = pcall(step) if not ok then G.last = 'error: ' .. tostring(e) end end)
    print('tantrum guard: watching the squads')
elseif cmd == 'stop' then
    G.on = false
    repeatUtil.cancel(KEY)
    print('tantrum guard: stopped')
elseif cmd == 'test' then
    -- dry run: who would come off duty now, and every soldier's state
    local n = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if u.military.squad_id ~= -1 then
            n = n + 1
            local why = breakdown(u)
            if why then print(dfhack.df2console(name(u)), 'WOULD COME OFF DUTY:', why) end
        end
    end
    print(('%d soldiers checked'):format(n))
else
    print(status())
end
