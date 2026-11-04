-- dfai-guard: tells df-ai where squads stand guard (user: "start a squad
-- rotation to those places to guard them and shoot foes").
-- Posts: inside every bolt-thrower bunker (marksdwarves shoot through its
-- fortifications) and on the wall beside every gate turret. df-ai's training
-- rotation then gives each post a squad in turn in the months it doesn't train:
-- four soldiers stand there in uniform while the rest of the squad works
-- (the "G" months in the [MILITARY] training rotation log lines). A danger
-- still calls everyone to battle stations as before.
--   dfai-guard start | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-guard'
state = state or {last = 'idle', posts = {}}

function posts()
    local out = {}
    local b = dfhack.persistent.getSiteData('dfai-bunker', {built = {}})
    for _, x in ipairs(b.built or {}) do
        out[#out + 1] = {(x.x1 + x.x2) // 2, (x.y1 + x.y2) // 2, x.z, 'bunker'}
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

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local ok, err = pcall(function()
        local list = posts()
        local parts, names = {}, {}
        for _, p in ipairs(list) do
            parts[#parts + 1] = ('%d,%d,%d'):format(p[1], p[2], p[3])
            names[#names + 1] = p[4]
        end
        local okp, P = pcall(require, 'plugins.df-ai')
        if not okp or not P.set_guard_posts then state.last = 'df-ai is not loaded' return end
        local n = P.set_guard_posts(table.concat(parts, ';'))
        state.posts = list
        if n < 0 then state.last = 'df-ai is not running'
        elseif n == 0 then state.last = 'no guard posts yet (they come with the bunkers and gate turrets)'
        else
            local c = {}
            for _, k in ipairs(names) do c[k] = (c[k] or 0) + 1 end
            state.last = ('%d guard posts (%d bunkers, %d gate turrets); squads take turns there when not training')
                :format(n, c.bunker or 0, c.gate or 0)
        end
    end)
    if not ok then state.last = 'error: ' .. tostring(err) end
end

function status() return 'guard: ' .. state.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('guard: watching')
else
    print(status())
end
