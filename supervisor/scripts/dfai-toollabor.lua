-- dfai-toollabor: mining, woodcutting and hunting go to civilians, matched
-- to the tools the fort has.
--
-- A dwarf in a squad won't take up a pick, an axe or a crossbow for work, but
-- autolabor only counts a dwarf as military by profession, and militia keep
-- their civilian ones: it handed woodcutting to soldiers. Channelevened (183
-- dwarves, nearly all in squads) had 4 of 5 woodcutters in squads, one of its
-- two axes locked in a squad's uniform, 70 trees marked and none felled, and
-- no wood for a year: no beds, bins, barrels or charcoal, so no metal, so no
-- new axes.
--
-- So these three labors are taken out of autolabor (`autolabor X disable`:
-- it never touches a disabled labor) and set here, once a game day: as many
-- civilians as there are tools for (up to a share of the fort), the ones who
-- already have the labor first, then the most skilled; never soldiers. An
-- axe or pick held in a squad's uniform list while civilians lack one is
-- taken back out of it.
--   dfai-toollabor start | status | now
--   dfai-toollabor want MINE <n>   (another script asks for more miners for a while)
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-toollabor'
local L = df.unit_labor
local LABORS = {
    {labor = L.MINE, name = 'MINE', skill = df.job_skill.MINING, share = 12, min = 3, max = 12},
    {labor = L.CUTWOOD, name = 'CUTWOOD', skill = df.job_skill.AXE, share = 20, min = 2, max = 8},
    {labor = L.HUNT, name = 'HUNT', skill = nil, share = 0, min = 1, max = 1},
}

local function load() return dfhack.persistent.getSiteData(KEY, {want = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

local function adult_civilian(u)
    return dfhack.units.isCitizen(u) and not dfhack.units.isChild(u) and not dfhack.units.isBaby(u)
        and dfhack.units.isSane(u) and u.military.squad_id == -1 and u.mood == -1
end

-- tools of a kind that aren't training weapons, with where they are
local function squad_assigned()
    local set = {}
    for _, id in ipairs(df.global.plotinfo.equipment.items_assigned.WEAPON) do set[id] = true end
    -- a squad position's own list holds it too (that's where the game put
    -- Channelevened's axe)
    for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sid)
        for _, p in ipairs(sq and sq.positions or {}) do
            for _, id in ipairs(p.equipment.assigned_items) do set[id] = true end
        end
    end
    return set
end
-- usable tools of a kind (not training weapons, not held by a soldier, not in
-- a squad's uniform list), and the ones locked in squad uniform lists
local function tools(skill)
    local assigned = squad_assigned()
    local usable, locked = 0, {}
    for _, w in ipairs(df.global.world.items.other.WEAPON) do
        if w.subtype.skill_melee == skill and not w.subtype.flags.TRAINING and not w.flags.garbage_collect and not w.flags.forbid then
            -- a tool marked for melting is never picked up for work: unmark it
            if w.flags.melt and not w.flags.in_job then dfhack.items.cancelMelting(w) end
            local h = dfhack.items.getHolderUnit(w)
            if h then
                if dfhack.units.isCitizen(h) and h.military.squad_id == -1 then usable = usable + 1 end
            elseif assigned[w.id] then
                locked[#locked + 1] = w
            elseif not w.flags.in_building then
                usable = usable + 1
            end
        end
    end
    return usable, locked
end

-- an axe or pick a squad keeps in its uniform list (the game's own uniform
-- assignment does it; df-ai never does) goes back to the stockpile
local function release_from_squads(items)
    local ids = {}
    for _, w in ipairs(items) do ids[w.id] = true end
    local n = 0
    for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sid)
        for _, p in ipairs(sq and sq.positions or {}) do
            for i = #p.equipment.assigned_items - 1, 0, -1 do
                if ids[p.equipment.assigned_items[i]] then p.equipment.assigned_items:erase(i) n = n + 1 end
            end
            for _, spec in ipairs(p.equipment.uniform.weapon) do
                for i = #spec.assigned - 1, 0, -1 do if ids[spec.assigned[i]] then spec.assigned:erase(i) end end
            end
        end
    end
    local eq = df.global.plotinfo.equipment
    for id in pairs(ids) do
        local v = eq.items_assigned.WEAPON
        for i = #v - 1, 0, -1 do if v[i] == id then v:erase(i) end end
    end
    if n > 0 then eq.update.weapon = true end
    return n
end

local function skill_of(u, sk)
    if not sk then return 0 end
    return dfhack.units.getNominalSkill(u, sk, true)
end

function step(s)
    s = s or load()
    local cits = dfhack.units.getCitizens(true)
    local pop = #cits
    local report = {}
    for _, d in ipairs(LABORS) do
        -- autolabor must leave this labor to us
        if not s.disabled or not s.disabled[d.name] then
            dfhack.run_command_silent('autolabor', d.name, 'disable')
            s.disabled = s.disabled or {}
            s.disabled[d.name] = true
        end
        local want = d.share > 0 and math.max(d.min, math.min(d.max, pop // d.share)) or d.min
        local asked = s.want[d.name]
        if asked and asked.n and asked.until_tick and df.global.world.frame_counter < asked.until_tick then
            want = math.max(want, asked.n)
        end
        local have_tools = 999
        if d.skill then
            local n, locked = tools(d.skill)
            if n < want and #locked > 0 then
                local r = release_from_squads(locked)
                if r > 0 then
                    report[#report + 1] = ('%d %s taken back from squads'):format(r, d.name == 'MINE' and 'picks' or 'axes')
                    n = n + math.min(r, #locked)
                end
            end
            have_tools = math.max(n, 1)
        end
        local target = math.min(want, have_tools)
        -- keep the ones who have it, then the most skilled
        local cand = {}
        for _, u in ipairs(cits) do
            if adult_civilian(u) then
                cand[#cand + 1] = {u = u, has = u.status.labors[d.labor], sk = skill_of(u, d.skill)}
            end
        end
        table.sort(cand, function(a, b)
            if a.has ~= b.has then return a.has end
            return a.sk > b.sk
        end)
        local on = {}
        for i = 1, math.min(target, #cand) do on[cand[i].u.id] = true end
        local count, moved = 0, 0
        for _, u in ipairs(cits) do
            local should = on[u.id] == true
            if u.status.labors[d.labor] ~= should then
                u.status.labors[d.labor] = should
                moved = moved + 1
            end
            if should then count = count + 1 end
        end
        report[#report + 1] = ('%s %d (tools %s, wanted %d)'):format(d.name, count, d.skill and tostring(have_tools) or '-', want)
    end
    s.last = table.concat(report, '; ')
    save(s)
    return s.last
end

local function tick() dfhack.with_suspend(function() pcall(step) end) end

local args = {...}
if dfhack_flags and dfhack_flags.module then return end
local cmd = args[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print('tool labors: managing mining, woodcutting and hunting')
elseif cmd == 'now' then
    print('tool labors: ' .. step())
elseif cmd == 'want' and args[2] and tonumber(args[3]) then
    local s = load()
    s.want[args[2]:upper()] = {n = tonumber(args[3]), until_tick = df.global.world.frame_counter + 1200 * 28}
    save(s)
    print(('tool labors: %s wanted at %s for a month'):format(args[2]:upper(), args[3]))
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    for _, d in ipairs(LABORS) do dfhack.run_command_silent('autolabor', d.name, 'reset') end
    local s = load() s.disabled = {} save(s)
    print('tool labors: handed back to autolabor')
else
    print('tool labors: ' .. tostring(load().last or 'not run yet'))
end
