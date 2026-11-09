-- dfai-yardwatch: nobody works outside next to a loose dangerous creature.
--
-- Topcloister: 24 of 56 dwarves in bed, hurt by agitated giant beetles,
-- squirrels, moas and a stegosaurus while building walls, bunkers and
-- windmills outside or hauling in the yard. Soldiers are sent (df-ai's
-- military), but the civilians kept walking back out to their jobs.
--
-- Every few seconds: a threat is any creature that isn't ours, isn't caged
-- or chained, can be seen, and is agitated, an invader, a marauder, undead
-- or otherwise dangerous, over the fort's yard (40 tiles round the entrance,
-- any height above it: fliers). While one is about, every job on an outside
-- tile within 25 tiles of it is suspended and its worker called off. When
-- the yard has been clear for a while, those jobs (only those) are resumed.
--
-- Underground too (Cloisterbolt: a giant cave spider killed 17 dwarves in
-- one game week in the deep workings, 168-08): a reachable dangerous
-- creature (agitated, a DF danger, a large or ambush predator, a webber)
-- that can be seen anywhere underground puts every job within 30 tiles / 8
-- levels of it on hold, and while one is out in a cavern EVERY job in or
-- beside the caverns is held (miners and haulers come out) until it's dead,
-- caged or out of sight. df-ai sends the squads after it.
--   dfai-yardwatch start | status | threats
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-yardwatch'
local SURF = reqscript('dfai-surface')
local R = 25

local function load() return dfhack.persistent.getSiteData(KEY, {held = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

function threats()
    local e = SURF.entrance()
    if not e then return {} end
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and not u.flags1.caged and not u.flags1.chained and not u.flags1.inactive
            and not dfhack.units.isCitizen(u) and not dfhack.units.isOwnCiv(u) and not dfhack.units.isTame(u) then
            local p = u.pos
            if math.abs(p.x - e.x) <= 40 and math.abs(p.y - e.y) <= 40 and p.z >= e.z - 6 then
                local f = dfhack.maps.getTileFlags(p)
                if f and not f.hidden and (dfhack.units.isAgitated(u) or u.flags1.active_invader or u.flags1.marauder
                    or dfhack.units.isUndead(u) or dfhack.units.isGreatDanger(u)
                    or (dfhack.units.isDanger(u) and not u.flags2.visitor)) then
                    out[#out + 1] = u
                end
            end
        end
    end
    return out
end

local function near_threat(pos, ts)
    for _, u in ipairs(ts) do
        if math.abs(pos.x - u.pos.x) <= R and math.abs(pos.y - u.pos.y) <= R and math.abs(pos.z - u.pos.z) <= 8 then return u end
    end
end

-- underground: dangerous creatures the fort's dwarves can walk to
local function cavern_tile(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    return b and b.designation[x % 16][y % 16].feature_local
end
local function in_caverns(p)
    if cavern_tile(p.x, p.y, p.z) then return true end
    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
        if cavern_tile(p.x + d[1], p.y + d[2], p.z) then return true end
    end
    return false
end
function dangerous(u)
    if dfhack.units.isAgitated(u) or dfhack.units.isDanger(u) or dfhack.units.isGreatDanger(u) or dfhack.units.isUndead(u) then return true end
    local r = df.creature_raw.find(u.race)
    local c = r and u.caste >= 0 and r.caste[u.caste]
    return c and (c.flags.LARGE_PREDATOR or c.flags.AMBUSHPREDATOR or c.flags.WEBBER) or false
end
-- {unit, cavern = true when it is out in a cavern}
function deep_threats()
    local fg = SURF.fort_group and SURF.fort_group() or 0
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and not u.flags1.caged and not u.flags1.chained and not u.flags1.inactive
            and not dfhack.units.isCitizen(u) and not dfhack.units.isOwnCiv(u) and not dfhack.units.isTame(u)
            and not dfhack.units.isMerchant(u) and not dfhack.units.isVisitor(u) and not dfhack.units.isDiplomat(u) then
            local f = dfhack.maps.getTileFlags(u.pos)
            if f and not f.hidden and not f.outside and dangerous(u)
                and (fg == 0 or dfhack.maps.getWalkableGroup(u.pos) == fg) then
                out[#out + 1] = {u = u, cavern = in_caverns(u.pos)}
            end
        end
    end
    return out
end
local DR, DZ = 30, 8
local function near_deep(pos, ds)
    for _, t in ipairs(ds) do
        if math.abs(pos.x - t.u.pos.x) <= DR and math.abs(pos.y - t.u.pos.y) <= DR and math.abs(pos.z - t.u.pos.z) <= DZ then return t.u end
    end
end
-- other scripts that send dwarves into the caverns ask this first
function cavern_threat()
    for _, t in ipairs(deep_threats()) do
        if t.cavern then return t.u end
    end
end

-- Every check re-applies the hold: DFHack's suspendmanager keeps
-- construction jobs unsuspended and dfai-walls/dfai-mist run 'unsuspend',
-- so a hold set once was gone within seconds (1,970 "held" ids, none still
-- suspended). The held list is rebuilt from live jobs each time.
local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        local ts = threats()
        local ds = deep_threats()
        local cav = false
        for _, t in ipairs(ds) do if t.cavern then cav = true end end
        local was = s.held or {}
        local now, resumed = {}, 0
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j and j.pos.x >= 0 then
                local key = tostring(j.id)
                local f = dfhack.maps.getTileFlags(j.pos)
                local hold = (#ts > 0 and f and f.outside and near_threat(j.pos, ts))
                    or (#ds > 0 and f and not f.outside and (near_deep(j.pos, ds) or (cav and in_caverns(j.pos))))
                if hold then
                    if not j.flags.suspend or was[key] then
                        j.flags.suspend = true
                        if dfhack.job.getWorker(j) then dfhack.job.removeWorker(j, 0) end
                        now[key] = true
                    end
                elseif was[key] and j.flags.suspend then
                    j.flags.suspend = false   -- the danger moved on
                    resumed = resumed + 1
                end
            end
            l = l.next
        end
        local held = 0
        for _ in pairs(now) do held = held + 1 end
        s.held = now
        if #ds == 0 then
            if s.told_deep then
                dfhack.gui.showAnnouncement('The deep workings are clear. Work below resumes.', COLOR_LIGHTGREEN, false)
            end
            s.told_deep = nil
        end
        if #ts == 0 and #ds == 0 then
            s.last = resumed > 0 and ('the yard and the deep workings are clear: %d jobs resumed'):format(resumed) or 'the yard is clear'
            if resumed > 0 and s.told then dfhack.gui.showAnnouncement('The yard is clear. Outdoor work resumes.', COLOR_LIGHTGREEN, false) end
            s.told = nil
            return
        end
        local names = {}
        for i, u in ipairs(ts) do if i <= 3 then names[#names + 1] = dfhack.df2utf(dfhack.units.getReadableName(u)) end end
        for i, t in ipairs(ds) do if i <= 3 then names[#names + 1] = dfhack.df2utf(dfhack.units.getReadableName(t.u)) .. (t.cavern and ' (caverns)' or ' (below)') end end
        s.last = ('%d job%s on hold: %s about'):format(held, held == 1 and '' or 's', table.concat(names, ', '))
        if #ts > 0 and held > 0 and not s.told then
            dfhack.gui.showAnnouncement('Danger in the yard: outdoor work stops until it is dealt with.', COLOR_YELLOW, false)
            s.told = true
        end
        if #ds > 0 and not s.told_deep then
            dfhack.gui.showAnnouncement(cav and 'A dangerous creature is loose in the caverns: everyone out until it is dealt with.'
                or 'A dangerous creature is loose below: work near it stops.', COLOR_YELLOW, false)
            s.told_deep = true
        end
    end)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
end

-- other scripts ask before a fort-wide 'unsuspend'
function holding()
    for _ in pairs(load().held or {}) do return true end
    return false
end

function status()
    return 'yard watch: ' .. (load().last or 'idle')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', tick)
    print('yard watch: watching')
elseif cmd == 'threats' then
    for _, u in ipairs(threats()) do print('yard', dfhack.df2console(dfhack.units.getReadableName(u)), u.pos.x, u.pos.y, u.pos.z) end
    for _, t in ipairs(deep_threats()) do print(t.cavern and 'caverns' or 'below', dfhack.df2console(dfhack.units.getReadableName(t.u)), t.u.pos.x, t.u.pos.y, t.u.pos.z) end
elseif cmd == 'test' then
    -- dry run: what would be held if a dangerous creature stood at x y z (in a cavern or not)
    local x, y, z = tonumber(({...})[2]), tonumber(({...})[3]), tonumber(({...})[4])
    local p = xyz2pos(x, y, z)
    local cav = in_caverns(p)
    local n, nc = 0, 0
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and j.pos.x >= 0 then
            local f = dfhack.maps.getTileFlags(j.pos)
            if f and not f.outside then
                if math.abs(j.pos.x - x) <= DR and math.abs(j.pos.y - y) <= DR and math.abs(j.pos.z - z) <= DZ then n = n + 1
                elseif cav and in_caverns(j.pos) then nc = nc + 1 end
            end
        end
        l = l.next
    end
    print(('test at %d,%d,%d (%s): %d jobs within %d tiles/%d levels and %d more in the caverns would be held')
        :format(x, y, z, cav and 'cavern' or 'not cavern', n, DR, DZ, nc))
else
    print(status())
end
