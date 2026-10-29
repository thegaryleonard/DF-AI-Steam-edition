-- dfai-armory: a weapon for every soldier (user: "fights shouldnt last that
-- long" - 49 soldiers punched a war tiger for 47 days with ~4 weapons between
-- them while 67 iron bars sat in the stockpile; df-ai only kept 5 weapons in
-- stock and its forge queue was all armor).
-- Once a game day: counts soldiers whose uniform still has an empty melee or
-- ranged weapon slot, subtracts free weapons and weapons already on order,
-- and orders the rest (up to 10 a day) at the forge in the best metal the
-- fort has bars of: war hammers, maces, spears and short swords in turn
-- (axes and picks go to woodcutters and miners - df-ai never hands those to
-- soldiers). Crossbows for marksdwarves are made of wood. Also keeps 2 picks
-- and 2 axes for the miners and woodcutters.
--   dfai-armory start | now | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-armory'
A = rawget(_G, 'dfai_armory') or {last = 'idle'}
rawset(_G, 'dfai_armory', A)

local METALS = {'STEEL', 'IRON', 'BRONZE', 'COPPER', 'SILVER'}     -- weapon-grade first
local MELEE = {'ITEM_WEAPON_HAMMER_WAR', 'ITEM_WEAPON_MACE', 'ITEM_WEAPON_SPEAR', 'ITEM_WEAPON_SWORD_SHORT'}

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
        if not i.flags.forbid and not i.flags.in_job and i.mat_type == 0 then
            local m = df.inorganic_raw.find(i.mat_index)
            if m then n[m.id] = (n[m.id] or 0) + i.stack_size end
        end
    end
    return n
end
local function free(i)
    local f = i.flags
    return not (f.forbid or f.in_inventory or f.in_job or f.owned or f.trader or f.removed or f.garbage_collect or f.foreign)
end
-- empty uniform weapon slots, melee and ranged
local function unarmed()
    local melee, ranged = 0, 0
    for _, sqid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sqid)
        for _, pos in ipairs(sq and sq.positions or {}) do
            if pos.occupant ~= -1 then
                for _, spec in ipairs(pos.equipment.uniform.weapon) do
                    if #spec.assigned == 0 then
                        if spec.indiv_choice.ranged then ranged = ranged + 1 else melee = melee + 1 end
                    end
                end
            end
        end
    end
    return melee, ranged
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
local function best_metal(b, need)
    for _, m in ipairs(METALS) do if (b[m] or 0) >= need then return m end end
end

local function step()
    if not dfhack.isMapLoaded() then return end
    local m_short, r_short = unarmed()
    local m_free, r_free, picks, axes = free_weapons()
    local b = bars()
    local notes = {}
    -- melee
    local want = math.min(10, m_short - m_free - on_order(function(d) return d.skill_ranged == df.job_skill.NONE and d.skill_melee ~= df.job_skill.MINING and d.skill_melee ~= df.job_skill.AXE end))
    if want > 0 then
        local made = 0
        for k, id in ipairs(MELEE) do
            local d = weapon_def(id)
            if d and civ_has(id) and made < want then
                local per = math.max(1, d.material_size // 3)
                local n = math.ceil((want - made) / (#MELEE - k + 1))
                local metal = best_metal(b, per * n)
                if metal then
                    order(id, metal, n)
                    b[metal] = b[metal] - per * n
                    made = made + n
                    notes[#notes + 1] = ('%d %s %s'):format(n, metal:lower(), d.name_plural)
                end
            end
        end
        if made == 0 then notes[#notes + 1] = ('%d soldiers need melee weapons but there are no weapon-grade metal bars'):format(want) end
    end
    -- crossbows (wood)
    local rwant = math.min(10, r_short - r_free - on_order(function(d) return d.skill_ranged ~= df.job_skill.NONE end))
    if rwant > 0 and civ_has('ITEM_WEAPON_CROSSBOW') then
        order('ITEM_WEAPON_CROSSBOW', nil, rwant)
        notes[#notes + 1] = ('%d wooden crossbows'):format(rwant)
    end
    -- the miners' and woodcutters' tools
    for _, t in ipairs({{'ITEM_WEAPON_PICK', picks, df.job_skill.MINING}, {'ITEM_WEAPON_AXE_BATTLE', axes, df.job_skill.AXE}}) do
        local w = 2 - t[2] - on_order(function(d) return d.skill_melee == t[3] end)
        local d = weapon_def(t[1])
        if w > 0 and d then
            local metal = best_metal(b, math.max(1, d.material_size // 3) * w)
            if metal then order(t[1], metal, w) notes[#notes + 1] = ('%d %s %s'):format(w, metal:lower(), d.name_plural) end
        end
    end
    A.last = ('%d soldiers without a melee weapon, %d without a crossbow; %s'):format(m_short, r_short,
        #notes > 0 and ('ordered ' .. table.concat(notes, ', ')) or 'nothing to order')
end

function status() return 'armory: ' .. A.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() local ok, e = pcall(step) if not ok then A.last = 'error: ' .. tostring(e) end end)
    print('armory: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then A.last = 'error: ' .. tostring(e) end end)
    print('armory: checking on the next tick')
else
    print(status())
end
