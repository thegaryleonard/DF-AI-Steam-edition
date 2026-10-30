-- dfai-fort-health: a daily scrub for the fort-level problems a new world/new
-- fort turned up (user: "this new world new fort has brought up a bunch of
-- bugs. better scrub everything for things like this"). Each check fixes what
-- it safely can and says what it saw; `dfai-fort-health` prints the last
-- report (the desk shows it).
--   1. stone: if every stone is "economic" (Hammerfaiths started that way),
--      masons have nothing to carve - reset to ores, flux, coal and clays
--   2. fertilizer: farm plots asking for potash the fort hasn't got post a
--      job per tile that's cancelled at once (177 of them) - fertilize only
--      while there's potash
--   3. coffins: unburied citizens (ghosts!) vs empty coffins - order more
--   4. memorial slabs stuck: EngraveSlab jobs that never get posted
--   5. the army: soldiers vs citizens, unarmed soldiers, hungry squads
--   6. labor: idle dwarves next to unworked workshop jobs
--   dfai-fort-health start | now | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-fort-health'
H = rawget(_G, 'dfai_fort_health') or {report = {}}
rawset(_G, 'dfai_fort_health', H)

local function citizens() return dfhack.units.getCitizens(true) end

local function check_stone(out)
    local e = df.global.plotinfo.economic_stone
    local all = df.global.world.raws.inorganics.all
    local on, stone = 0, 0
    for i, m in ipairs(all) do
        if m.flags.SEDIMENTARY or m.flags.IGNEOUS_INTRUSIVE or m.flags.IGNEOUS_EXTRUSIVE or m.flags.METAMORPHIC then
            stone = stone + 1
            if e[i] ~= 0 then on = on + 1 end
        end
    end
    if stone > 0 and on >= stone * 0.9 then
        local n = 0
        for i, m in ipairs(all) do
            local econ = #m.metal_ore.mat_index > 0 or #m.thread_metal.mat_index > 0
            for _, rc in ipairs(m.material.reaction_class) do
                local r = rc.value
                if r == 'FLUX' or r == 'COAL' or r == 'GYPSUM' or r == 'KAOLINITE' then econ = true end
            end
            e[i] = econ and 1 or 0
            if econ then n = n + 1 end
        end
        out[#out + 1] = ('stone: every stone was reserved ("economic"), masons had nothing to use - reset, %d kinds reserved'):format(n)
    else
        out[#out + 1] = ('stone: ok (%d of %d stone kinds reserved)'):format(on, stone)
    end
end

local function potash()
    local n = 0
    for _, i in ipairs(df.global.world.items.other.BAR) do
        if not i.flags.forbid and dfhack.matinfo.decode(i):toString():find('potash') then n = n + i.stack_size end
    end
    return n
end
local function check_fertilizer(out)
    local p = potash()
    local want = p >= 5
    local changed = 0
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
        if b.farm_flags.seasonal_fertilize ~= want then b.farm_flags.seasonal_fertilize = want changed = changed + 1 end
    end
    local removed = 0
    if not want then
        local kill = {}
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j.job_type == df.job_type.FertilizeField and not dfhack.job.getWorker(j) then kill[#kill + 1] = j end
            l = l.next
        end
        for _, j in ipairs(kill) do if dfhack.job.removeJob(j) then removed = removed + 1 end end
    end
    out[#out + 1] = ('fertilizer: %d potash; fertilizing %s%s%s'):format(p, want and 'on' or 'off',
        changed > 0 and (' (%d plots switched)'):format(changed) or '', removed > 0 and (', %d dead-end fertilize jobs cleared'):format(removed) or '')
end

local function check_coffins(out)
    local unburied = 0
    for _, i in ipairs(df.global.world.items.other.ANY_CORPSE) do
        local u = i.unit_id and df.unit.find(i.unit_id)
        if u and u.civ_id == df.global.plotinfo.civ_id and dfhack.units.isDwarf(u) and not i.flags.in_building and not i.flags.dump then
            local b = dfhack.items.getHolderBuilding(i)
            if not b or b:getType() ~= df.building_type.Coffin then unburied = unburied + 1 end
        end
    end
    local empty = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Coffin and #b.contained_items <= 1 then empty = empty + 1 end
    end
    local loose = 0
    for _, i in ipairs(df.global.world.items.other.COFFIN) do if not i.flags.in_building and not i.flags.forbid then loose = loose + 1 end end
    local ordered = 0
    for _, mo in ipairs(df.global.world.manager_orders.all) do
        if mo.job_type == df.job_type.ConstructCoffin then ordered = ordered + mo.amount_left end
    end
    local short = unburied + 2 - empty - loose - ordered
    if short > 0 then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructCoffin","amount_total":%d,"material":"INORGANIC"}'):format(math.min(short, 10)))
    end
    local ghosts = 0
    for _, u in ipairs(df.global.world.units.active) do if dfhack.units.isGhost(u) and not dfhack.units.isDead(u) then ghosts = ghosts + 1 end end
    out[#out + 1] = ('coffins: %d dwarves unburied, %d ghosts; %d empty coffins, %d made, %d on order%s'):format(unburied, ghosts, empty, loose, ordered,
        short > 0 and (' - ordered %d more'):format(math.min(short, 10)) or '')
end

local function posted_ids()
    local p = {}
    for _, x in ipairs(df.global.world.jobs.postings) do if not x.flags.dead and x.job then p[x.job.id] = true end end
    return p
end
local function check_workshops(out)
    local idle = 0
    for _, u in ipairs(citizens()) do
        if not u.job.current_job and u.military.squad_id == -1 and dfhack.units.isAdult(u) then idle = idle + 1 end
    end
    local queued, worked, front_unposted = 0, 0, {}
    local posted = posted_ids()
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        if (t == df.building_type.Workshop or t == df.building_type.Furnace) and #b.jobs > 0 then
            for _, j in ipairs(b.jobs) do
                queued = queued + 1
                if dfhack.job.getWorker(j) then worked = worked + 1 end
            end
            local j = b.jobs[0]
            if not dfhack.job.getWorker(j) and not posted[j.id] and not j.flags.suspend then
                local k = df.job_type[j.job_type]
                front_unposted[k] = (front_unposted[k] or 0) + 1
            end
        end
    end
    local fu = {}
    for k, n in pairs(front_unposted) do fu[#fu + 1] = ('%s x%d'):format(k, n) end
    out[#out + 1] = ('workshops: %d jobs queued, %d being worked, %d idle civilians%s'):format(queued, worked, idle,
        #fu > 0 and ('; front jobs waiting on materials: ' .. table.concat(fu, ', ')) or '')
end

local function check_army(out)
    local c = citizens()
    local sol, hungry, unarmed = 0, 0, 0
    for _, u in ipairs(c) do
        if u.military.squad_id ~= -1 then
            sol = sol + 1
            if u.counters2.hunger_timer > 50000 or u.counters2.thirst_timer > 30000 then hungry = hungry + 1 end
            local armed = false
            for _, it in ipairs(u.inventory) do if it.mode == 1 then armed = true end end
            if not armed then unarmed = unarmed + 1 end
        end
    end
    out[#out + 1] = ('army: %d soldiers of %d citizens; %d hungry or thirsty; %d not holding a weapon right now'):format(sol, #c, hungry, unarmed)
end

local CHECKS = {check_stone, check_fertilizer, check_coffins, check_workshops, check_army}
local function step()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local out = {}
    for _, f in ipairs(CHECKS) do
        local ok, e = pcall(f, out)
        if not ok then out[#out + 1] = 'error: ' .. tostring(e) end
    end
    H.report, H.at = out, df.global.cur_year_tick
end

function status() return 'fort health:\n  ' .. (#H.report > 0 and table.concat(H.report, '\n  ') or 'not checked yet') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() local ok, e = pcall(step) if not ok then H.report = {'error: ' .. tostring(e)} end end)
    dfhack.timeout(1, 'ticks', step)
    print('fort health: checking daily')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then H.report = {'error: ' .. tostring(e)} end end)
    print('fort health: checking on the next tick')
else
    print(status())
end
