-- Beast hunt (Showerwheels, site 350; user: "dig a door down to that beast and
-- then kill it, muster the troops at the door before you breach and attack").
--
-- phases (state in site data 'dfai-beast-hunt', resumes after a reload):
--   dig     stairs from the breach bubble (43,92,132) down to one level above
--           the first cavern (42,92,131), plus a door in the shaft-floor tunnel
--   muster  every squad at home gets a move order to the door; wait until most
--           soldiers stand there (or MUSTER_TICKS pass)
--   breach  the last stair (42,92,130) opens into the cavern
--   attack  move orders dropped; every squad on Ready with a kill order on
--           every forgotten beast that can now walk to the fort
--   done    all hunted beasts dead (or the army is gone)
--
--   dfai-beast-hunt start | status | stop | attack (skip the wait)
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-beast-hunt'
local SITE = 350

local DOOR = {44, 94, 159}         -- tunnel from the shaft floor to the breach stairs
local MUSTER = {46, 95, 159}       -- just inside the door (falls back to the door)
local STAIRS = {{42, 92, 132, 'DownStair'}, {42, 92, 131, 'UpDownStair'}}
local LAST = {42, 92, 130, 'UpStair'}
local CAVERN = {42, 91, 130}       -- cavern floor the last stair opens onto
local MUSTER_TICKS = 2 * 1200      -- two game days at most
local MUSTER_SHARE = 0.4   -- user: at 40% mustered, go (murder ball)
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'

local function notify(msg)
    local f = io.open(NOTIFY, 'a')
    if f then f:write('<@YOUR_DISCORD_USER_ID> ' .. msg .. '\n') f:close() end
end
local function log(msg) print('[beast hunt] ' .. msg) end

local function load_state() return dfhack.persistent.getSiteData(KEY, {}) end
local function save_state(s) dfhack.persistent.saveSiteData(KEY, s) end
local function now_abs() return df.global.cur_year * 403200 + df.global.cur_year_tick end
local function P(t) return xyz2pos(t[1], t[2], t[3]) end

local function shape(t) return df.tiletype.attrs[dfhack.maps.getTileType(t[1], t[2], t[3])].shape end
local function is_wall(t) return shape(t) == df.tiletype_shape.WALL end

local function designate(t)
    local x, y, z = t[1], t[2], t[3]
    if not is_wall(t) then return end
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    f.dig = df.tile_dig_designation[t[4]]
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = 1000
    b.flags.designated = true
end

local function citizen()
    for _, u in ipairs(dfhack.units.getCitizens(true)) do return u end
end

local function home_squads()
    local out = {}
    for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sid)
        if sq and sq.assigned_army_controller_id == -1 then
            local members = {}
            for _, p in ipairs(sq.positions) do
                local hf = p.occupant ~= -1 and df.historical_figure.find(p.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then members[#members + 1] = u end
            end
            if #members > 0 then out[#out + 1] = {sq = sq, members = members} end
        end
    end
    return out
end

local function is_ours(o, kind)
    return (o.year == -7777) or (kind == 'move' and df.squad_order_movest:is_instance(o)
        and o.pos.x == MUSTER[1] and o.pos.y == MUSTER[2] and o.pos.z == MUSTER[3])
end

local function drop_moves(sq)
    for i = #sq.orders - 1, 0, -1 do
        local o = sq.orders[i]
        if df.squad_order_movest:is_instance(o) then sq.orders:erase(i) end
    end
end

local function routine(name)
    for i, r in ipairs(df.global.plotinfo.alerts.routines) do
        if r.name == name then return i end
    end
end

local function prey()
    local c = citizen()
    local out = {}
    if not c then return out end
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isForgottenBeast(u) and dfhack.units.isActive(u) and not dfhack.units.isDead(u)
            and dfhack.maps.canWalkBetween(c.pos, u.pos) then
            out[#out + 1] = u
        end
    end
    table.sort(out, function(a, b)
        local da = math.abs(a.pos.x - CAVERN[1]) + math.abs(a.pos.y - CAVERN[2]) + 3 * math.abs(a.pos.z - CAVERN[3])
        local db = math.abs(b.pos.x - CAVERN[1]) + math.abs(b.pos.y - CAVERN[2]) + 3 * math.abs(b.pos.z - CAVERN[3])
        return da < db
    end)
    return out
end

local function unit_name(u)
    local n = dfhack.units.getReadableName(u)
    return dfhack.df2utf(n:gsub(', Forgotten Beast', ''))
end

-- the hunt's story for the Herald (herald_trade.py reads this file)
local function hfn(u)
    local hf = u and u.hist_figure_id ~= -1 and df.historical_figure.find(u.hist_figure_id)
    local n = hf and dfhack.translation.translateName(hf.name, true) or (u and dfhack.units.getReadableName(u)) or ''
    return dfhack.df2utf(n)
end
local function killer_of(u)
    local inc = u and u.counters.death_id >= 0 and df.incident.find(u.counters.death_id)
    return inc and inc.criminal ~= -1 and df.unit.find(inc.criminal) or nil
end
function report()
    local s = load_state()
    local out = {year = df.global.cur_year, phase = s.phase, mustered = s.mustered, beasts = {}, fallen = {}}
    for id, nm in pairs(s.hunted or {}) do
        local u = df.unit.find(tonumber(id))
        local raw = u and df.creature_raw.find(u.race)
        local k = killer_of(u)
        out.beasts[#out.beasts + 1] = {
            name = nm, dead = u and dfhack.units.isDead(u) or false,
            what = raw and dfhack.df2utf(raw.caste[u.caste].description) or '',
            slayer = k and hfn(k) or nil,
            slayer_job = k and dfhack.df2utf(dfhack.units.getProfessionName(k)) or nil,
            slayer_alive = k and not dfhack.units.isDead(k) or false,
        }
    end
    -- our dead from the attack to a day after the end (the hunt's own clock)
    local t0, t1 = s.attack_at or 0, (s.done_at or now_abs()) + 1200
    for _, u in ipairs(df.global.world.units.all) do
        if dfhack.units.isOwnCiv(u) and dfhack.units.isDead(u) and dfhack.units.isDwarf(u) then
            local hf = df.historical_figure.find(u.hist_figure_id)
            local t = hf and hf.died_year >= 0 and (hf.died_year * 403200 + hf.died_seconds)
            if t and t >= t0 and t <= t1 then
                local k = killer_of(u)
                local kraw = k and df.creature_raw.find(k.race)
                out.fallen[#out.fallen + 1] = {
                    name = hfn(u), job = dfhack.df2utf(dfhack.units.getProfessionName(u)),
                    by = k and (dfhack.units.isForgottenBeast(k) and hfn(k):match('^[^,]+') or (kraw and kraw.name[0])) or nil,
                }
            end
        end
    end
    local f = io.open('dfhack-config/dfai-beast-hunt.json', 'w')
    if f then f:write(require('json').encode(out)) f:close() end
    return out
end

local function step()
    if df.global.plotinfo.main.fortress_entity == nil or df.global.plotinfo.site_id ~= SITE then return 'not this fort' end
    local s = load_state()
    s.phase = s.phase or 'dig'

    if s.phase == 'dig' then
        if not s.dig_set then
            -- the first plan went through a cave tree's canopy: drop it
            for z = 132, 130, -1 do dfhack.maps.getTileFlags(43, 91, z).dig = df.tile_dig_designation.No end
            for _, t in ipairs(STAIRS) do designate(t) end
            local door = dfhack.buildings.findAtTile(P(DOOR))
            if not door then
                local ok, b = pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Door, pos = P(DOOR)})
                log('door ordered at the cavern tunnel: ' .. tostring(ok and b and b.id))
            end
            s.dig_set = true
            log('digging down to one level above the cavern')
        end
        local done = true
        for _, t in ipairs(STAIRS) do if is_wall(t) then done = false end end
        if done then
            s.phase, s.muster_at = 'muster', now_abs()
            if not dfhack.maps.isValidTilePos(P(MUSTER)) or is_wall(MUSTER) then MUSTER = DOOR end
            local n = 0
            for _, h in ipairs(home_squads()) do
                drop_moves(h.sq)
                local o = df.squad_order_movest:new()
                o.pos = P(MUSTER)
                o.point_id = -1
                o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
                h.sq.orders:insert(0, o)
                local ready = routine('Ready')
                if ready then h.sq.cur_routine_idx = ready end
                n = n + 1
            end
            s.squads = n
            log(('one step from the cavern: %d squads mustering at the door'):format(n))
            notify(('**Beast hunt:** the stairs stop one level above the first cavern. %d squads are mustering in full gear at the new cavern door before the last step is dug.'):format(n))
        end

    elseif s.phase == 'muster' then
        local total, there = 0, 0
        for _, h in ipairs(home_squads()) do
            for _, u in ipairs(h.members) do
                total = total + 1
                if u.pos.z == MUSTER[3] and math.abs(u.pos.x - MUSTER[1]) + math.abs(u.pos.y - MUSTER[2]) <= 10 then there = there + 1 end
            end
        end
        s.mustered = ('%d of %d soldiers at the door'):format(there, total)
        if (total > 0 and there >= total * MUSTER_SHARE) or s.force or now_abs() - (s.muster_at or 0) >= MUSTER_TICKS then
            designate(LAST)
            s.phase, s.force = 'breach', nil
            log('mustered (' .. s.mustered .. '): breaching')
            pcall(function()
                local m = reqscript('dfai-projects')
                m.add('beasthunt', 'The Beast Hunt: Breaching The Cavern', 41, 91, 130, 43, 93, 132, true)
                m.update('beasthunt', {critical = true})
            end)
        end

    elseif s.phase == 'breach' then
        local c = citizen()
        if c and dfhack.maps.canWalkBetween(c.pos, P(CAVERN)) then
            s.phase = 'attack'
            s.attack_at = now_abs()
            pcall(function() reqscript('dfai-projects').done('beasthunt') end)
        end
    end

    if s.phase == 'attack' then
        local beasts = prey()
        s.hunted = s.hunted or {}
        s.killed = s.killed or {}
        for _, u in ipairs(beasts) do s.hunted[tostring(u.id)] = s.hunted[tostring(u.id)] or unit_name(u) end
        for id, nm in pairs(s.hunted) do
            local u = df.unit.find(tonumber(id))
            if (not u or dfhack.units.isDead(u)) and not s.killed[id] then
                s.killed[id] = true
                log(nm .. ' is dead')
                notify(('**Beast hunt:** %s is dead.'):format(nm))
            end
        end
        local squads = home_squads()
        if not s.attack_sent and #beasts > 0 then
            s.attack_sent = true
            local names = {}
            for _, u in ipairs(beasts) do names[#names + 1] = unit_name(u) end
            log('ATTACK: ' .. #squads .. ' squads against ' .. table.concat(names, ', '))
            notify(('**Beast hunt: ATTACK.** The cavern is open. %d squads are going after %d forgotten beasts: %s. The battle camera has the fight.')
                :format(#squads, #beasts, table.concat(names, '; ')))
        end
        local ready = routine('Ready')
        for _, h in ipairs(squads) do
            drop_moves(h.sq)
            if ready then h.sq.cur_routine_idx = ready end
            local ko
            for _, o in ipairs(h.sq.orders) do
                if df.squad_order_kill_listst:is_instance(o) and o.title == 'Beast hunt' then ko = o end
            end
            if #beasts > 0 then
                if not ko then
                    ko = df.squad_order_kill_listst:new()
                    ko.title = 'Beast hunt'
                    ko.year, ko.year_tick = df.global.cur_year, df.global.cur_year_tick
                    h.sq.orders:insert(0, ko)
                end
                ko.units:resize(0)
                for _, u in ipairs(beasts) do ko.units:insert('#', u.id) end
            end
        end
        local left = 0
        for id in pairs(s.hunted) do if not s.killed[id] then left = left + 1 end end
        if (left == 0 and next(s.hunted)) or #squads == 0 then
            s.phase = 'done'
            s.done_at = now_abs()
            local n = 0
            for _ in pairs(s.killed) do n = n + 1 end
            local msg = #squads == 0 and ('the army is gone; %d beasts killed'):format(n)
                or ('every beast that could reach the fort is dead (%d)'):format(n)
            log('done: ' .. msg)
            notify('**Beast hunt over:** ' .. msg .. '.')
            pcall(report)
        end
    end
    save_state(s)
    return s.phase
end

local function tick()
    local ok, res = pcall(step)
    if not ok then _G.dfai_beast_hunt_err = tostring(res) end
end

if dfhack_flags and dfhack_flags.module then return end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    print('beast hunt: started')
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    print('beast hunt: stopped')
elseif cmd == 'report' then
    local ids = {select(2, ...)}
    dfhack.timeout(1, 'ticks', function()
        if #ids > 0 then   -- 'report <hf ids>': set the hunt's window from known deaths
            local st, lo, hi = load_state(), nil, nil
            for _, id in ipairs(ids) do
                local hf = df.historical_figure.find(tonumber(id))
                if hf and hf.died_year >= 0 then
                    local t = hf.died_year * 403200 + hf.died_seconds
                    lo, hi = math.min(lo or t, t), math.max(hi or t, t)
                end
            end
            if lo then st.attack_at, st.done_at = lo - 1200, hi save_state(st) end
        end
        local ok, r = pcall(report)
        if not ok then _G.dfai_beast_hunt_err = tostring(r) else _G.dfai_beast_hunt_err = nil end
    end)
    print('beast hunt: report queued')
elseif cmd == 'attack' then
    dfhack.timeout(1, 'ticks', function() local s = load_state() s.force = true save_state(s) end)
    print('beast hunt: breaching without waiting for the muster')
else
    local s = load_state()
    print(('beast hunt: %s; %s; err %s'):format(tostring(s.phase or 'not started'), tostring(s.mustered or ''), tostring(_G.dfai_beast_hunt_err)))
end
