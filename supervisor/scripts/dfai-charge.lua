-- dfai-charge: every squad at home musters and goes for the invaders (user:
-- "accelerate it a bit by mustering and having our troops engage the invaders").
-- Every ~15 game seconds while seen, reachable invaders are on the map: each
-- squad with members on the map goes on its Ready routine with one kill list
-- ("Charge") holding every such invader; when none are left the kill lists are
-- dropped and the squads go back to their usual routine.
--   dfai-charge start | stop | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-charge'
C = rawget(_G, 'dfai_charge') or {on = false, last = 'idle'}
rawset(_G, 'dfai_charge', C)

local function routine(name)
    for i, r in ipairs(df.global.plotinfo.alerts.routines) do if r.name == name then return i end end
end
local function home_squads()
    local out = {}
    for _, sq in ipairs(df.global.world.squads.all) do
        if sq.entity_id == df.global.plotinfo.group_id then
            local n = 0
            for _, p in ipairs(sq.positions) do
                local hf = p.occupant ~= -1 and df.historical_figure.find(p.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.inactive then n = n + 1 end
            end
            if n > 0 then out[#out + 1] = sq end
        end
    end
    return out
end
local function drop(sq)
    for i = #sq.orders - 1, 0, -1 do
        local o = sq.orders[i]
        if df.squad_order_kill_listst:is_instance(o) and o.title == 'Charge' then sq.orders:erase(i) end
    end
end

local function step()
    if not dfhack.isMapLoaded() then return end
    local cits = dfhack.units.getCitizens(true)
    if #cits == 0 then return end
    local from = cits[1].pos
    local targets = {}
    for _, u in ipairs(df.global.world.units.active) do
        if (u.flags1.active_invader or u.flags2.visitor_uninvited) and dfhack.units.isActive(u) and not dfhack.units.isDead(u)
            and not u.flags1.caged and not u.flags1.chained and not dfhack.maps.getTileFlags(u.pos).hidden
            and dfhack.maps.canWalkBetween(from, u.pos) then
            targets[#targets + 1] = u.id
        end
    end
    local squads = home_squads()
    if #targets == 0 then
        if C.engaged then
            for _, sq in ipairs(squads) do drop(sq) end
            C.engaged = false
            C.last = 'no invaders left in reach: kill lists dropped'
            dfhack.gui.showAnnouncement('The invaders are gone. The squads stand down.', COLOR_LIGHTGREEN, false)
        end
        return
    end
    local ready = routine('Ready')
    for _, sq in ipairs(squads) do
        drop(sq)
        local o = df.squad_order_kill_listst:new()
        o.title = 'Charge'
        for _, id in ipairs(targets) do o.units:insert('#', id) end
        o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
        sq.orders:insert(0, o)
        if ready then sq.cur_routine_idx = ready end
    end
    if not C.engaged then
        dfhack.gui.showAnnouncement(('To arms! %d squads charge %d invaders.'):format(#squads, #targets), COLOR_LIGHTRED, true)
    end
    C.engaged = true
    C.last = ('%d squads charging %d invaders'):format(#squads, #targets)
end

function status() return 'charge: ' .. (C.on and 'on' or 'off') .. ' - ' .. C.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    C.on = true
    repeatUtil.scheduleEvery(KEY, 300, 'ticks', function() local ok, e = pcall(step) if not ok then C.last = 'error: ' .. tostring(e) end end)
    print('charge: the squads go for any invaders in reach')
elseif cmd == 'stop' then
    C.on = false
    repeatUtil.cancel(KEY)
    dfhack.timeout(1, 'ticks', function() for _, sq in ipairs(home_squads()) do drop(sq) end C.engaged = false end)
    print('charge: stopped (kill lists dropped)')
else
    print(status())
end
