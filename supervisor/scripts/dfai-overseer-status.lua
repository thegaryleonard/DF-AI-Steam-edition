-- dfai-overseer-status: one JSON line with the state behind every Overseer's
-- Desk order, so each card can say what is going on (user request).
-- Read-only; run from overseer.py every few seconds.

local json = require('json')
local function cmd(...)
    local ok, out = pcall(dfhack.run_command_silent, ...)
    out = ok and tostring(out or '') or ''
    return (out:gsub('\r', ''):match('^[^\n]*') or ''):gsub('^[%w ]+: ', '', 1)
end
-- strings stay in DF's own encoding: dfhack-run converts the console output to UTF-8
local function u8(s) return s or '' end
local out = {}

-- war office
-- one unreadable store must not blank every card on the desk
local function site(key) local ok, d = pcall(dfhack.persistent.getSiteData, key, {}) return ok and type(d) == 'table' and d or {broken = true} end
local W = site('dfai-war-office')
local abroad = {}
for sid, m in pairs(W.sent or {}) do
    abroad[#abroad + 1] = ('%s (%s %s)'):format(u8(m.squad or ('squad ' .. sid)), m.mode or 'raid', u8(m.site or '?'))
end
local last
for i = #(W.log or {}), 1, -1 do
    local e = W.log[i]
    if e.kind == 'result' or e.kind == 'home' then last = e break end
end
out.war = {
    abroad = abroad,
    hold = W.hold,
    last = last and (((last.squad and last.squad ~= '') and last.squad or 'the raiders') .. ' ' .. (last.kind == 'home' and 'came home from' or (last.what or 'hit')) .. ' ' .. (last.site or '?')) or nil,
    office = cmd('dfai-war-office'),
}

-- foreign office: envoys on the road
local F = site('dfai-foreign-office')
local envoys = 0
for _ in pairs(F.sent or {}) do envoys = envoys + 1 end
out.foreign = {broken = F.broken, envoys = envoys, contacts = (function() local n = 0 for _ in pairs(F.contact or {}) do n = n + 1 end return n end)()}

-- the automation scripts' own status lines
-- the army and the beasts right now
local cits = dfhack.units.getCitizens(true)
local soldiers, squads = 0, {}
for _, u in ipairs(cits) do
    if u.military.squad_id ~= -1 then soldiers = soldiers + 1 squads[u.military.squad_id] = true end
end
local nsq = 0
for _ in pairs(squads) do nsq = nsq + 1 end
out.army = {citizens = #cits, soldiers = soldiers, squads = nsq}
local beasts = {}
local okt, tour = pcall(reqscript, 'dfai-room-tour')
local cpos = {}
for _, c in ipairs(cits) do cpos[#cpos + 1] = c.pos end
for _, u in ipairs(df.global.world.units.active) do
    if (dfhack.units.isForgottenBeast(u) or dfhack.units.isMegabeast(u) or dfhack.units.isTitan(u) or dfhack.units.isDemon(u))
        and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not dfhack.maps.getTileFlags(u.pos).hidden then
        local near = okt and tour.close_to_fort and tour.close_to_fort(u, cpos)
        beasts[#beasts + 1] = ('%s (level %d, %s)'):format(u8(dfhack.units.getReadableName(u)):gsub(',.*$', ''), u.pos.z, near and 'IN THE FORT' or 'down in the caverns')
    end
end
local hunt = (cmd('dfai-beast-hunt'):gsub('; err nil', ''))
if hunt:find('^done') or hunt:find('^idle') or hunt == '' then
    out.beast = ('No hunt running. %s Army: %d soldiers in %d squads.'):format(
        #beasts > 0 and ('Beasts in sight: ' .. table.concat(beasts, '; ') .. '.') or 'No beasts in sight.', soldiers, nsq)
else
    out.beast = hunt .. (' (army now: %d soldiers)'):format(soldiers)
end
out.beasts = beasts
out.mist = cmd('dfai-mist')
local function tidy(t) return (t:gsub('^done; last: done', 'done')) end
out.dig = tidy(cmd('dfai-deep-dig'))
out.ore = cmd('dfai-ore-scrub')
out.holiday = cmd('dfai-holiday')
out.smasher = cmd('dfai-pit')
out.catacomb = cmd('dfai-catacomb')
out.cavore = cmd('dfai-cavern-ore')
out.watchdog = (cmd('dfai-watchdog'):gsub('^watchdog:%s*', ''))
out.verify = (cmd('dfai-verify'):gsub('^verify:%s*', ''))
out.ghosts = (cmd('dfai-ghost-watch'):gsub('^ghost watch:%s*', ''))
out.health = (cmd('dfai-fort-health'):gsub('^fort health:%s*', ''):gsub('%s+', ' '))
out.armory = cmd('dfai-armory')
out.seal = cmd('dfai-cavern-seal')
out.pastures = (cmd('dfai-pastures'):gsub(' | .*', ''))

-- projects the camera follows
local okp, pm = pcall(reqscript, 'dfai-projects')
local working = {}
if okp and pm and pm.list then
    for _, p in pairs(pm.list() or {}) do if not p.done then working[#working + 1] = u8(p.title) end end
end
out.projects = working

-- the camera
local tour = rawget(_G, 'dfai_tour') or {}
local cam
if tour.current and tour.current.name then cam = dfhack.df2utf(tour.current.name)
elseif df.global.plotinfo.follow_unit ~= -1 then
    local u = df.unit.find(df.global.plotinfo.follow_unit)
    cam = u and ('following ' .. dfhack.df2utf(dfhack.units.getReadableName(u)):gsub(',.*', '')) or nil
end
out.camera = cam or 'free'
local okl, cl = pcall(reqscript, 'dfai-camera-lock')
out.camlock = okl and cl.status and cl.status() or 'not running'
local threats = 0
for _, u in ipairs(df.global.world.units.active) do
    if not dfhack.units.isDead(u) and (u.flags1.active_invader or dfhack.units.isGreatDanger(u))
        and not dfhack.maps.getTileFlags(u.pos).hidden then threats = threats + 1 end
end
out.threats = threats

print(json.encode(out))
