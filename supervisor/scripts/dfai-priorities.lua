-- dfai-priorities: the fort's priority list (user: "before you do big mining
-- operations, get food going. actually also on the overseer desk give a
-- priority list"). The list lives in dfhack-config/dfai-priorities.json and
-- the Overseer's Desk reorders it. Two kinds of entries:
--   goals      food, drink, defense, housing: met or not, measured here
--   activities mining (deep dig, cavern ore, ore scrub), outreach (raids and
--              messengers): each waits until every goal ABOVE it is met
-- A goal, once met, stays met until it drops below 60% of its mark (no
-- flapping on every meal eaten).
--   dfai-priorities            status
--   dfai-priorities json       the list with live state (for the desk)
--   dfai-priorities allowed X  "yes"/"no: <reason>" for an activity
--@module = true

local json = require('json')
local CFG = dfhack.getDFPath() .. '/dfhack-config/dfai-priorities.json'
DEFAULT = {'food', 'drink', 'defense', 'mining', 'housing', 'bunkers', 'walls', 'mist', 'outreach'}
ACTIVITY = {mining = true, outreach = true, bunkers = true, walls = true, mist = true}
-- activities with no builder for a new fort yet: listed so they can be ranked
NO_BUILDER = {walls = true, mist = true}
LABEL = {
    food = 'Food: farms going and 15 meals or food per dwarf',
    drink = 'Drink: 10 drinks per dwarf',
    defense = 'Defense: one armed soldier for every 5 dwarves (at least 3)',
    housing = 'Housing: a bed for every dwarf',
    mining = 'Big mining: the deep dig, cavern ore and ore marking',
    outreach = 'Outreach: raids and messengers (also wait for 100 citizens)',
    bunkers = 'Bolt-thrower bunkers outside the gate (one per 40 citizens, up to 3)',
    walls = 'Exterior walls round the surface',
    mist = 'Mist generator by the entrance',
}
P = rawget(_G, 'dfai_priorities') or {met = {}}
rawset(_G, 'dfai_priorities', P)

function order()
    local ok, d = pcall(json.decode_file, CFG)
    local o = ok and type(d) == 'table' and d.order or nil
    local seen, out = {}, {}
    for _, k in ipairs(o or {}) do if LABEL[k] and not seen[k] then out[#out + 1] = k seen[k] = true end end
    for _, k in ipairs(DEFAULT) do if not seen[k] then out[#out + 1] = k end end   -- anything missing goes last
    return out
end

local function count(list, pred)
    local n = 0
    for _, i in ipairs(list) do if pred(i) then n = n + i.stack_size end end
    return n
end
local function usable(i) local f = i.flags return not (f.forbid or f.rotten or f.trader or f.dump or f.garbage_collect) end

-- each goal: have, want, and a short line
local MEASURE = {
    food = function(pop)
        local food = count(df.global.world.items.other.ANY_GOOD_FOOD, usable)
        local farms = 0
        for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do if b:getBuildStage() >= b:getMaxBuildStage() then farms = farms + 1 end end
        local want = 15 * pop
        return (farms > 0 and food or 0), want, ('%d food, %d farm plots'):format(food, farms)
    end,
    drink = function(pop)
        local d = count(df.global.world.items.other.DRINK, usable)
        return d, 10 * pop, ('%d drinks'):format(d)
    end,
    defense = function(pop)
        local armed = 0
        for _, sqid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
            local sq = df.squad.find(sqid)
            for _, pos in ipairs(sq and sq.positions or {}) do
                if pos.occupant ~= -1 then
                    local has = false
                    for _, spec in ipairs(pos.equipment.uniform.weapon) do if #spec.assigned > 0 then has = true end end
                    if has then armed = armed + 1 end
                end
            end
        end
        return armed, math.max(3, pop // 5), ('%d armed soldiers'):format(armed)
    end,
    housing = function(pop)
        local beds = 0
        for _, b in ipairs(df.global.world.buildings.other.BED or {}) do if b:getBuildStage() >= b:getMaxBuildStage() then beds = beds + 1 end end
        return beds, pop, ('%d beds'):format(beds)
    end,
}

-- the live list: {key, label, kind, met/allowed, line}
function state()
    local pop = #dfhack.units.getCitizens(true)
    local out, blocking = {}, nil
    for _, k in ipairs(order()) do
        local e = {key = k, label = LABEL[k], kind = ACTIVITY[k] and 'activity' or 'goal'}
        if ACTIVITY[k] then
            e.ok = blocking == nil
            if NO_BUILDER[k] then e.ok = false e.line = '(no builder for new forts yet)' out[#out + 1] = e goto continue end
            e.line = blocking and ('waits for ' .. blocking) or 'go ahead'
        else
            local ok, have, want, line = pcall(MEASURE[k], pop)
            if not ok then have, want, line = 0, 1, 'error: ' .. tostring(have) end
            local met = have >= want or (P.met[k] and have >= want * 0.6)
            P.met[k] = met or nil
            e.ok = met and true or false
            e.line = ('%s (wants %d)'):format(line, want)
            if not met and not blocking then blocking = k end
        end
        out[#out + 1] = e
        ::continue::
    end
    return out
end

-- may this activity run now? true, or false and why
function allowed(what)
    if not dfhack.isMapLoaded() then return false, 'no fort' end
    for _, e in ipairs(state()) do
        if e.key == what then return e.ok, e.line end
    end
    return true
end

if dfhack_flags.module then return end
local args = {...}
if args[1] == 'json' then
    print(json.encode({order = state()}))
elseif args[1] == 'allowed' then
    local ok, why = allowed(args[2] or '')
    print(ok and 'yes' or ('no: ' .. tostring(why)))
else
    local t = {}
    for i, e in ipairs(state()) do t[#t + 1] = ('%d. %s %s - %s'):format(i, e.ok and '[x]' or '[ ]', e.key, e.line) end
    print('priorities:\n  ' .. table.concat(t, '\n  '))
end
