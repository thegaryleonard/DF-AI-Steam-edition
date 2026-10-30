-- dfai-traffic: where the fort's dwarves actually walk. Every 100 ticks the
-- position of every citizen out of bed is counted into a heat map (kept per
-- site, coarse-free: one count per tile). Surface projects use it: the mist
-- generator has to stand where dwarves pass (user: "it only works if its
-- creating the mist in a high traffic area"), and the curtain wall's gate goes
-- where the paths cross the ring.
--   dfai-traffic start | status | top [n]
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-traffic'
local EVERY = 100

T = rawget(_G, 'dfai_traffic') or {}
rawset(_G, 'dfai_traffic', T)

local function key(x, y, z) return (z * 1000 + y) * 1000 + x end
local function unkey(k) return k % 1000, (k // 1000) % 1000, k // 1000000 end

local function load()
    local site = df.global.plotinfo.site_id
    if T.site ~= site then
        local d = dfhack.persistent.getSiteData(KEY, {})
        T.site, T.heat, T.samples = site, {}, d.samples or 0
        for k, v in pairs(d.heat or {}) do T.heat[tonumber(k)] = v end
    end
    return T
end
local function save()
    -- keep the busiest 4000 tiles (the rest is noise)
    local list = {}
    for k, v in pairs(T.heat) do list[#list + 1] = {k, v} end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local h = {}
    T.heat = {}
    for i = 1, math.min(4000, #list) do h[tostring(list[i][1])] = list[i][2] T.heat[list[i][1]] = list[i][2] end
    dfhack.persistent.saveSiteData(KEY, {heat = h, samples = T.samples})
end

local function sample()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local t = load()
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if not u.flags1.on_ground then   -- lying down: asleep or hurt, not walking
            local k = key(u.pos.x, u.pos.y, u.pos.z)
            t.heat[k] = (t.heat[k] or 0) + 1
        end
    end
    t.samples = t.samples + 1
    if t.samples % 120 == 0 then save() end   -- every 10 game days
end

-- traffic on one tile, and the sum over a box at one level
function at(x, y, z) return load().heat[key(x, y, z)] or 0 end
function box(x1, y1, x2, y2, z)
    local h, n = load().heat, 0
    for x = x1, x2 do for y = y1, y2 do n = n + (h[key(x, y, z)] or 0) end end
    return n
end
function samples() return load().samples end
-- the busiest tiles passing filter(x, y, z), best first
function hottest(n, filter)
    local list = {}
    for k, v in pairs(load().heat) do
        local x, y, z = unkey(k)
        if not filter or filter(x, y, z) then list[#list + 1] = {x, y, z, v} end
    end
    table.sort(list, function(a, b) return a[4] > b[4] end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

if dfhack_flags.module then return end
local args = {...}
if args[1] == 'start' then
    repeatUtil.scheduleEvery(KEY, EVERY, 'ticks', function() pcall(sample) end)
    print('traffic: counting footsteps')
elseif args[1] == 'top' then
    for _, h in ipairs(hottest(tonumber(args[2]) or 10, function(x, y, z) return dfhack.maps.getTileFlags(x, y, z).outside end)) do
        print(('%d,%d,%d  %d'):format(h[1], h[2], h[3], h[4]))
    end
else
    local n = 0
    for _ in pairs(load().heat) do n = n + 1 end
    print(('traffic: %d samples, %d tiles walked'):format(samples(), n))
end
