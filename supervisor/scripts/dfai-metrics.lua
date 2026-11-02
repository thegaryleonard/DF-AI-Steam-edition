-- dfai-metrics: one line of the fort's vital signs as JSON, for the
-- Overseer's Desk charts (overseer.py samples it every few minutes).
local json = require('json')
local out = {}
if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then
    print(json.encode({loaded = false}))
    return
end
local function count(list, pred)
    local n = 0
    for _, i in ipairs(list) do if not pred or pred(i) then n = n + i.stack_size end end
    return n
end
local function usable(i) local f = i.flags return not (f.forbid or f.rotten or f.trader or f.dump or f.garbage_collect) end
local cits = dfhack.units.getCitizens(true)
local hungry, thirsty, unhappy, soldiers = 0, 0, 0, 0
for _, u in ipairs(cits) do
    if u.counters2.hunger_timer > 50000 then hungry = hungry + 1 end
    if u.counters2.thirst_timer > 30000 then thirsty = thirsty + 1 end
    local st = dfhack.units.getStressCategory and dfhack.units.getStressCategory(u) or 3
    if st <= 1 then unhappy = unhappy + 1 end
    if u.military.squad_id ~= -1 then soldiers = soldiers + 1 end
end
local ghosts, foes = 0, 0
for _, u in ipairs(df.global.world.units.active) do
    -- a ghost counts as dead, so it has to be counted before that check
    -- (the counter said 0 with 17 of them walking about)
    if dfhack.units.isGhost(u) then ghosts = ghosts + 1 end
    if not dfhack.units.isDead(u) then
        if (dfhack.units.isDanger(u) or dfhack.units.isGreatDanger(u)) and not dfhack.maps.getTileFlags(u.pos).hidden then foes = foes + 1 end
    end
end
local site = dfhack.world.getCurrentSite()
out = {
    loaded = true,
    fort = site and dfhack.df2utf(dfhack.translation.translateName(site.name, true)) or '?',
    year = df.global.cur_year, tick = df.global.cur_year_tick,
    pop = #cits, soldiers = soldiers,
    food = count(df.global.world.items.other.ANY_GOOD_FOOD, usable),
    drink = count(df.global.world.items.other.DRINK, usable),
    hungry = hungry, thirsty = thirsty, unhappy = unhappy,
    ghosts = ghosts, foes = foes,
    fps = df.global.enabler.calculated_fps, fps_cap = df.global.enabler.fps,
    jobs = (function() local n, l = 0, df.global.world.jobs.list.next while l do n = n + 1 l = l.next end return n end)(),
    wealth = df.global.plotinfo.tasks.wealth.total,
}
print(json.encode(out))
