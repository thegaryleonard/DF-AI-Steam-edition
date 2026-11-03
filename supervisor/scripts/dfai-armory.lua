-- dfai-armory: a weapon for every soldier (user: "fights shouldnt last that
-- long" - 49 soldiers punched a war tiger for 47 days with ~4 weapons between
-- them while 67 iron bars sat in the stockpile; df-ai only kept 5 weapons in
-- stock and its forge queue was all armor. Divedfountain: 55 of the 95 dead
-- in a goblin siege were Recruits/Wrestlers with no weapon).
-- Once a game day: counts soldiers on the map with no USABLE weapon (an empty
-- uniform weapon slot, or an assigned weapon that is gone or held by someone
-- else), adds spares so a fresh draft is armed at once, subtracts free
-- weapons (stockpile bins included) and weapons already on order, and orders
-- the rest at the forge, up to 25 a day. User: "just make more weapons,
-- spears and such" -> spears and war hammers only, split evenly (falling
-- back to whichever of the two the civ can make; maces and swords already in
-- stock still get issued). Each kind takes the best metal it has bars for
-- (blunt hammers like dense silver, spears want a hard edge), fewer when the
-- bars run short. With no bars it marks loose enemy metal weapons for
-- melting (df-ai's melt orders had nothing designated). Crossbows for
-- marksdwarves are made of wood. Also keeps 2 picks and 2 axes for the
-- miners and woodcutters. Module functions soldier_armed/squad_armed are
-- shared with dfai-charge (unarmed squads never charge).
--   dfai-armory start | now | status | plan [N]  (plan = dry run, as if N more were unarmed)
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-armory'
A = rawget(_G, 'dfai_armory') or {last = 'idle'}
rawset(_G, 'dfai_armory', A)

-- weapon -> metals, best first
local MELEE = {
    {id = 'ITEM_WEAPON_SPEAR', metals = {'STEEL', 'IRON', 'BRONZE', 'COPPER', 'SILVER'}},
    {id = 'ITEM_WEAPON_HAMMER_WAR', metals = {'STEEL', 'SILVER', 'IRON', 'BRONZE', 'COPPER'}},
}
-- only when the civ can make neither spears nor war hammers
local FALLBACK = {
    {id = 'ITEM_WEAPON_MACE', metals = {'STEEL', 'SILVER', 'IRON', 'BRONZE', 'COPPER'}},
    {id = 'ITEM_WEAPON_SWORD_SHORT', metals = {'STEEL', 'IRON', 'BRONZE', 'COPPER', 'SILVER'}},
}
local TOOL_METALS = {'STEEL', 'IRON', 'BRONZE', 'COPPER', 'SILVER'}
local MAX_PER_DAY = 25

local function weapon_def(id)
    for _, d in ipairs(df.global.world.raws.itemdefs.weapons) do if d.id == id then return d end end
end
local function civ_has(id)
    local ent = df.global.plotinfo.main.fortress_entity
    for _, sub in ipairs(ent.entity_raw.equipment.weapon_id) do
        local d = df.itemdef_weaponst.find(sub)
        if d and d.id == id then return true end
    end
end
local function bars()
    local n = {}
    for _, i in ipairs(df.global.world.items.other.BAR) do
        if not i.flags.forbid and not i.flags.in_job and not i.flags.trader and i.mat_type == 0 then
            local m = df.inorganic_raw.find(i.mat_index)
            if m then n[m.id] = (n[m.id] or 0) + i.stack_size end
        end
    end
    return n
end
-- free to hand out: lying loose or in a stockpile bin (a bin is not a hand;
-- the old check skipped every binned weapon - 38 maces at Divedfountain)
local function free(i)
    local f = i.flags
    if f.forbid or f.in_job or f.owned or f.trader or f.removed or f.garbage_collect or f.foreign or f.dump or f.melt then return false end
    if f.in_inventory then
        if dfhack.items.getHolderUnit(i) then return false end
        local c = dfhack.items.getContainer(i)
        if not c or c.flags.forbid or c.flags.in_job or c.flags.trader or dfhack.items.getHolderUnit(c) then return false end
    end
    return true
end
local function is_tool(d) return d.skill_melee == df.job_skill.MINING or d.skill_melee == df.job_skill.AXE end

-- the soldier can fight with this weapon: it exists, is real (not training),
-- and nobody else holds it (a dead soldier's hand, a goblin's)
local function usable(it, u)
    if not it or it.flags.garbage_collect or it.flags.removed then return false end
    if not df.item_weaponst:is_instance(it) or it.subtype.flags.TRAINING then return false end
    local outer, h = it, dfhack.items.getHolderUnit(it)
    if not h then
        local c = dfhack.items.getContainer(it)
        if c then outer, h = c, dfhack.items.getHolderUnit(c) end
    end
    if not h or h == u then return true end
    -- a hauler carrying it (to the soldier or a stockpile) doesn't count
    for _, inv in ipairs(h.inventory) do
        if inv.item == outer and inv.mode == df.inv_item_role_type.Hauled then return not dfhack.units.isDead(h) end
    end
    return false
end
-- does this soldier have a weapon to fight with (in hand or assigned)?
function soldier_armed(pos, u)
    for _, inv in ipairs(u.inventory) do
        if inv.mode == df.inv_item_role_type.Weapon and usable(inv.item, u) then return true end
    end
    for _, spec in ipairs(pos.equipment.uniform.weapon) do
        for _, id in ipairs(spec.assigned) do
            if usable(df.item.find(id), u) then return true end
        end
    end
    return false
end
local function on_map(pos)
    local hf = pos.occupant ~= -1 and df.historical_figure.find(pos.occupant)
    local u = hf and df.unit.find(hf.unit_id)
    if u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.inactive then return u end
end
-- members on the map, how many of them armed
function squad_arms(sq)
    local n, armed = 0, 0
    for _, pos in ipairs(sq.positions) do
        local u = on_map(pos)
        if u then
            n = n + 1
            if soldier_armed(pos, u) then armed = armed + 1 end
        end
    end
    return n, armed
end
-- fit to fight: half or more of its members on the map have a weapon
-- (same rule as df-ai's Population::squad_armed)
function squad_armed(sq)
    local n, armed = squad_arms(sq)
    return n == 0 or armed * 2 >= n
end

-- soldiers on the map with no usable weapon, melee and ranged
local function unarmed()
    local melee, ranged, soldiers = 0, 0, 0
    for _, sqid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sqid)
        for _, pos in ipairs(sq and sq.positions or {}) do
            local u = on_map(pos)
            if u then
                soldiers = soldiers + 1
                if not soldier_armed(pos, u) then
                    local want_ranged = false
                    for _, spec in ipairs(pos.equipment.uniform.weapon) do
                        if spec.indiv_choice.ranged then want_ranged = true end
                    end
                    if want_ranged then ranged = ranged + 1 else melee = melee + 1 end
                end
            end
        end
    end
    return melee, ranged, soldiers
end
local function free_weapons()
    local melee, ranged, picks, axes = 0, 0, 0, 0
    for _, i in ipairs(df.global.world.items.other.WEAPON) do
        if free(i) and i.subtype and not i.subtype.flags.TRAINING then
            local s = i.subtype
            if s.skill_melee == df.job_skill.MINING then picks = picks + 1
            elseif s.skill_melee == df.job_skill.AXE then axes = axes + 1
            elseif s.skill_ranged ~= df.job_skill.NONE then ranged = ranged + 1
            else melee = melee + 1 end
        end
    end
    return melee, ranged, picks, axes
end
local function on_order(pred)
    local n = 0
    for _, mo in ipairs(df.global.world.manager_orders.all) do
        if mo.job_type == df.job_type.MakeWeapon then
            local d = df.itemdef_weaponst.find(mo.item_subtype)
            if d and pred(d) then n = n + mo.amount_left end
        end
    end
    return n
end
local function order(id, metal, n)
    local o = {job = 'MakeWeapon', item_subtype = id, amount_total = n}
    if metal then o.material = 'INORGANIC:' .. metal else o.material_category = {'wood'} end
    return dfhack.run_command_silent('workorder', require('json').encode(o))
end
local function best_metal(b, metals, need)
    for _, m in ipairs(metals) do if (b[m] or 0) >= need then return m end end
end
local function bars_per(d) return math.max(1, d.material_size // 3) end

-- short of bars: melt loose enemy metal weapons (invaders' drops), at most
-- 20 a day; df-ai's MeltMetalObject orders then have something to melt
local function melt_goblinite()
    local n = 0
    for _, i in ipairs(df.global.world.items.other.WEAPON) do
        if n >= 20 then break end
        local f = i.flags
        -- never axes or picks: they're woodcutting and mining tools (both of
        -- Channelevened's axes were invaders' drops marked for melting, and a
        -- tool marked for melting is never picked up: no wood for a year)
        local tool = i.subtype.skill_melee == df.job_skill.AXE or i.subtype.skill_melee == df.job_skill.MINING
        if not tool and f.foreign and f.on_ground and not (f.forbid or f.in_job or f.melt or f.dump or f.artifact or f.trader or f.owned or f.in_inventory) then
            if dfhack.items.canMelt(i) and dfhack.items.markForMelting(i) then n = n + 1 end
        end
    end
    return n
end

-- dry: print what would be ordered instead of ordering; pretend: extra
-- unarmed soldiers to plan for (for testing the split and the metal choice)
local function step(dry, pretend)
    if not dfhack.isMapLoaded() then return end
    local m_short, r_short, soldiers = unarmed()
    m_short = m_short + (pretend or 0)
    local place = order
    if dry then place = function(id, metal, n) print(('would order %d %s in %s'):format(n, id, metal or 'wood')) end end
    local m_free, r_free, picks, axes = free_weapons()
    local b = bars()
    local notes = {}
    -- melee: the unarmed plus spares for the next recruits (1 per 8 soldiers, min 2)
    local spares = math.max(2, soldiers // 8)
    local ordered = on_order(function(d) return d.skill_ranged == df.job_skill.NONE and not is_tool(d) end)
    local want = math.min(MAX_PER_DAY, m_short + spares - m_free - ordered)
    if want > 0 then
        local kinds = {}
        for _, k in ipairs(MELEE) do
            local d = weapon_def(k.id)
            if d and civ_has(k.id) then kinds[#kinds + 1] = {k = k, d = d} end
        end
        if #kinds == 0 then
            for _, k in ipairs(FALLBACK) do
                local d = weapon_def(k.id)
                if d and civ_has(k.id) then kinds[#kinds + 1] = {k = k, d = d} end
            end
        end
        local made = 0
        -- split evenly; a kind short of bars hands the rest of its share on
        for idx, kd in ipairs(kinds) do
            local n = math.ceil((want - made) / (#kinds - idx + 1))
            local per = bars_per(kd.d)
            while n > 0 do
                local metal = best_metal(b, kd.k.metals, per * n)
                if metal then
                    place(kd.k.id, metal, n)
                    b[metal] = b[metal] - per * n
                    made = made + n
                    notes[#notes + 1] = ('%d %s %s'):format(n, metal:lower(), kd.d.name_plural)
                    break
                end
                n = n - 1
            end
        end
        if made < want then
            local melted = dry and 0 or melt_goblinite()
            notes[#notes + 1] = ('%d more wait for weapon-grade metal bars (ore smelting, caravans%s)'):format(
                want - made, melted > 0 and (', ' .. melted .. ' enemy weapons marked for melting') or '')
        end
    end
    -- crossbows (wood)
    local rwant = math.min(10, r_short - r_free - on_order(function(d) return d.skill_ranged ~= df.job_skill.NONE end))
    if rwant > 0 and civ_has('ITEM_WEAPON_CROSSBOW') then
        place('ITEM_WEAPON_CROSSBOW', nil, rwant)
        notes[#notes + 1] = ('%d wooden crossbows'):format(rwant)
    end
    -- the miners' and woodcutters' tools
    for _, t in ipairs({{'ITEM_WEAPON_PICK', picks, df.job_skill.MINING}, {'ITEM_WEAPON_AXE_BATTLE', axes, df.job_skill.AXE}}) do
        local w = 2 - t[2] - on_order(function(d) return d.skill_melee == t[3] end)
        local d = weapon_def(t[1])
        if w > 0 and d then
            local metal = best_metal(b, TOOL_METALS, bars_per(d) * w)
            if metal then
                place(t[1], metal, w)
                b[metal] = b[metal] - bars_per(d) * w
                notes[#notes + 1] = ('%d %s %s'):format(w, metal:lower(), d.name_plural)
            end
        end
    end
    local line = ('%d of %d soldiers without a weapon (%d melee, %d crossbow), %d free melee weapons, %d on order; %s'):format(
        m_short + r_short, soldiers, m_short, r_short, m_free, ordered,
        #notes > 0 and ('ordered ' .. table.concat(notes, ', ')) or 'nothing to order')
    if dry then print('plan: ' .. line) return end
    A.short, A.soldiers = m_short + r_short, soldiers
    A.last = line
end

function status() return 'armory: ' .. A.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() local ok, e = pcall(step) if not ok then A.last = 'error: ' .. tostring(e) end end)
    print('armory: watching')
elseif cmd == 'plan' then
    -- dry run: dfai-armory plan [extra unarmed soldiers]
    local ok, e = pcall(step, true, tonumber(({...})[2]) or 0)
    if not ok then print('error: ' .. tostring(e)) end
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then A.last = 'error: ' .. tostring(e) end end)
    print('armory: checking on the next tick')
else
    print(status())
end
