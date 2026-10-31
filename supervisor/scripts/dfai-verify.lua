-- dfai-verify: the "not tested yet" list, ticked off when each feature first
-- works for real in a running fort (user asked for lessons learned; one was
-- that features piled up unproven). Daily; results kept across forts in
-- dfhack-config/dfai-verified.json (feature -> fort, year, what was seen).
--   dfai-verify start | now | status | json
--@module = true

local json = require('json')
local repeatUtil = require('repeat-util')
local KEY = 'dfai-verify'
local FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-verified.json'

local function sd(key) return dfhack.persistent.getSiteData(key, {}) end
local function log_has(pat)
    local f = io.open(dfhack.getDFPath() .. '/df-ai.log', 'rb')
    if not f then return false end
    local size = f:seek('end')
    f:seek('set', math.max(0, size - 4 * 1024 * 1024))
    local t = f:read('a') f:close()
    return t:find(pat, 1, true) ~= nil
end

-- feature -> {what it claims, check() -> evidence string or nil}
FEATURES = {
    {'water', 'Water from the caverns: a zone or well we made ends "No water source"', function()
        local ok, H = pcall(function() return rawget(_G, 'dfai_fort_health') end)
        local made = ok and H and (H.water_zone or H.water_well)
        local okp, pri = pcall(reqscript, 'dfai-priorities')
        if made and okp and not pri.no_water() then return 'dwarves stopped cancelling "No water source"' end
    end},
    {'mist', 'Tavern mist generator primes and runs', function()
        local p = sd('dfai-mist').plan
        if p and p.phase == 'running' then return 'running over the tavern' end
    end},
    {'crusher', 'Refuse crusher: lowering the bridge destroys the load', function()
        local s = sd('dfai-pit')
        if (s.crushed or 0) > 0 and s.shaft then return ('%d items crushed'):format(s.crushed) end
    end},
    {'pen', 'Execution pit pen: something lands in the pen and stays in', function()
        local s = sd('dfai-pit')
        local sh = s.shaft
        if not sh or s.phase ~= 'running' then return end
        for _, u in ipairs(df.global.world.units.active) do
            if not dfhack.units.isDead(u) and not dfhack.units.isCitizen(u) and u.pos.z == sh.zb - 1
                and math.abs(u.pos.x - sh.p[1]) <= 4 and math.abs(u.pos.y - sh.p[2]) <= 4 then
                return dfhack.df2utf(dfhack.units.getReadableName(u)) .. ' is alive in the pen'
            end
        end
    end},
    {'bunker', 'Bolt-thrower bunker: built, facing out, firing at enemies', function()
        for _, b in ipairs(sd('dfai-bunker').built or {}) do
            local e = df.building.find(b.engine)
            if e and e.action == df.siegeengine_action.FireAtWill then return 'engine ' .. e.id .. ' set to fire at will' end
        end
    end},
    {'walls', 'Curtain wall finished with its gate', function()
        if sd('dfai-walls').finished then return 'finished' end
    end},
    {'caravan', 'Stuck merchants are sent home', function()
        local H = rawget(_G, 'dfai_fort_health')
        for _, l in ipairs(H and H.report or {}) do if l:find('stuck merchants and animals sent home', 1, true) then return l end end
    end},
    {'flier', 'Agitated creatures over the fort get a squad', function()
        if log_has('agitated creature over the fort') then return 'df-ai sent a squad (df-ai.log)' end
    end},
    {'slab', 'Ghost watch: a slab it queued gets set', function()
        local G = rawget(_G, 'dfai_ghost_watch')
        for _, r in ipairs(G and G.rows or {}) do if r.slab == 'set' then return r.name .. "'s slab is set" end end
    end},
    {'gate', 'Cavern water gate: the breach door locks when danger is out there', function()
        local C = rawget(_G, 'dfai_cavern_seal')
        if C and C.last and C.last:find('water gate locked', 1, true) then return C.last end
    end},
}

local function read() local ok, d = pcall(json.decode_file, FILE) return ok and type(d) == 'table' and d or {} end
V = rawget(_G, 'dfai_verify') or {}
rawset(_G, 'dfai_verify', V)

local function step()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local done = read()
    local site = dfhack.world.getCurrentSite()
    local fort = site and dfhack.df2utf(dfhack.translation.translateName(site.name, true)) or '?'
    local changed = false
    for _, f in ipairs(FEATURES) do
        if not done[f[1]] then
            local ok, ev = pcall(f[3])
            if ok and ev then
                done[f[1]] = {fort = fort, year = df.global.cur_year, seen = ev}
                changed = true
                dfhack.gui.showAnnouncement('Verified: ' .. f[2], COLOR_LIGHTGREEN, false)
            end
        end
    end
    if changed then json.encode_file(done, FILE) end
    local n, open = 0, {}
    for _, f in ipairs(FEATURES) do if done[f[1]] then n = n + 1 else open[#open + 1] = f[1] end end
    V.last = ('%d of %d features proven in a real fort; still to see: %s'):format(n, #FEATURES, #open > 0 and table.concat(open, ', ') or 'nothing')
end

function status() return 'verify: ' .. (V.last or 'not checked yet') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() pcall(step) end)
    dfhack.timeout(1, 'ticks', function() pcall(step) end)
    print('verify: daily')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then V.last = 'error: ' .. tostring(e) end end)
    print('verify: checking')
elseif cmd == 'json' then
    local done, out = read(), {}
    for _, f in ipairs(FEATURES) do out[#out + 1] = {key = f[1], what = f[2], proven = done[f[1]]} end
    print(json.encode(out))
else
    print(status())
end
