-- dfai-guard: tells df-ai where squads stand guard (user: "start a squad
-- rotation to those places to guard them and shoot foes").
-- Posts: the watch post on the roof over the fort entrance (dfai-watchpost)
-- and on the wall beside every gate turret, all inside the curtain wall. df-ai's training
-- rotation then gives each post a squad in turn in the months it doesn't train:
-- four soldiers stand there in uniform while the rest of the squad works
-- (the "G" months in the [MILITARY] training rotation log lines). A danger
-- still calls everyone to battle stations as before.
--   dfai-guard start | status | off | on
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-guard'
state = state or {last = 'idle', posts = {}}

function posts()
    local out = {}
    -- the watch post over the entrance (inside the wall), not the bunkers
    -- out past it: small guard groups outside the wall were picked off
    local okw, wp = pcall(reqscript, 'dfai-watchpost')
    if okw and wp.posts then
        for _, p in ipairs(wp.posts()) do out[#out + 1] = {p[1], p[2], p[3], 'watch'} end
    end
    local ok, gt = pcall(reqscript, 'dfai-gateturret')
    if ok and gt.posts then
        for _, p in ipairs(gt.posts()) do out[#out + 1] = {p[1], p[2], p[3], 'gate'} end
    end
    -- a post nobody can walk to is no post
    local cit = dfhack.units.getCitizens(true)[1]
    local kept = {}
    for _, p in ipairs(out) do
        if not cit or dfhack.maps.canWalkBetween(cit.pos, xyz2pos(p[1], p[2], p[3])) then kept[#kept + 1] = p end
    end
    return kept
end

local function off() return dfhack.persistent.getSiteData(KEY, {}).off end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local ok, err = pcall(function()
        local list = off() and {} or posts()
        local parts, names = {}, {}
        for _, p in ipairs(list) do
            parts[#parts + 1] = ('%d,%d,%d'):format(p[1], p[2], p[3])
            names[#names + 1] = p[4]
        end
        local okp, P = pcall(require, 'plugins.df-ai')
        if not okp or not P.set_guard_posts then state.last = 'df-ai is not loaded' return end
        -- the curtain wall's ring: squads hold inside it during a siege
        local w = dfhack.persistent.getSiteData('dfai-walls', {})
        state.box = nil
        if P.set_defense_box then
            if w.box and w.z then
                P.set_defense_box(w.box.x1, w.box.y1, w.box.x2, w.box.y2, w.z)
                state.box = w.box
            else
                P.set_defense_box(-1, -1, -1, -1, -1)
            end
        end
        local n = P.set_guard_posts(table.concat(parts, ';'))
        state.posts = list
        if n < 0 then state.last = 'df-ai is not running'
        elseif n == 0 then state.last = off() and 'off (dfai-guard on to resume)' or 'on; no guard posts yet (the watch post inside the gate and the gate turrets)'
        else
            local c = {}
            for _, k in ipairs(names) do c[k] = (c[k] or 0) + 1 end
            state.last = ('%d guard posts (%d watch post, %d gate turrets); squads take turns there when not training')
                :format(n, c.watch or 0, c.gate or 0)
        end
    end)
    if not ok then state.last = 'error: ' .. tostring(err) end
end

function status()
    return 'guard: ' .. state.last .. (state.box and ('; squads hold inside the wall (%d,%d..%d,%d) in a siege'):format(state.box.x1, state.box.y1, state.box.x2, state.box.y2) or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'off' or cmd == 'on' then
    -- off: no guard duty (the squads only train); kept with the fort
    dfhack.persistent.saveSiteData(KEY, {off = cmd == 'off'})
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print('guard: ' .. cmd)
elseif cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('guard: watching')
else
    print(status())
end
