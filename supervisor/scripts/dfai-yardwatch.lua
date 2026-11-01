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
--   dfai-yardwatch start | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-yardwatch'
local SURF = reqscript('dfai-surface')
local R, CLEAR_CHECKS = 25, 6

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

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(function()
        local ts = threats()
        local held = 0
        for _ in pairs(s.held) do held = held + 1 end
        if #ts == 0 then
            if held == 0 then s.last = 'the yard is clear' return end
            s.clear = (s.clear or 0) + 1
            if s.clear < CLEAR_CHECKS then s.last = ('the yard looks clear; %d outdoor jobs resume soon'):format(held) return end
            local back = 0
            local l = df.global.world.jobs.list.next
            while l do
                local j = l.item
                if j and s.held[tostring(j.id)] and j.flags.suspend then j.flags.suspend = false back = back + 1 end
                l = l.next
            end
            s.held, s.clear = {}, 0
            s.last = ('the yard is clear: %d outdoor jobs resumed'):format(back)
            if back > 0 then dfhack.gui.showAnnouncement('The yard is clear. Outdoor work resumes.', COLOR_LIGHTGREEN, false) end
            return
        end
        s.clear = 0
        local new, names = 0, {}
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j and j.pos.x >= 0 then
                local f = dfhack.maps.getTileFlags(j.pos)
                local t = f and f.outside and near_threat(j.pos, ts)
                if t and not s.held[tostring(j.id)] and not j.flags.suspend then
                    j.flags.suspend = true
                    local w = dfhack.job.getWorker(j)
                    if w then dfhack.job.removeWorker(j, 0) end
                    s.held[tostring(j.id)] = true
                    new = new + 1
                end
            end
            l = l.next
        end
        for i, u in ipairs(ts) do if i <= 3 then names[#names + 1] = dfhack.df2utf(dfhack.units.getReadableName(u)) end end
        held = held + new
        s.last = ('%d outdoor job%s on hold: %s about'):format(held, held == 1 and '' or 's', table.concat(names, ', '))
        if new > 0 and not s.told then
            dfhack.gui.showAnnouncement('Danger in the yard: outdoor work stops until it is dealt with.', COLOR_YELLOW, false)
        end
        s.told = new > 0 or nil
    end)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
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
    for _, u in ipairs(threats()) do print(dfhack.df2console(dfhack.units.getReadableName(u)), u.pos.x, u.pos.y, u.pos.z) end
else
    print(status())
end
