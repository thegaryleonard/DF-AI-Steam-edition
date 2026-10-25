-- dfai-room-tour: between dwarves, show the fort's rooms on stream.
--@ module = true
--
-- While spectate is following dwarves (nobody is playing), every
-- DWARF_SECS of wall time the camera leaves the dwarf, shows one room for
-- ROOM_SECS with a big name label, then hands the camera back to spectate.
-- Rooms come from the fort itself: taverns, temples, libraries, guildhalls and
-- hospitals (by their DF names), dining halls, meeting halls, barracks, big
-- pastures, the trade depot and machine rooms (the mist chamber).
--
--   dfai-room-tour start | stop | status | next
--   overlay enable dfai-room-tour.label      (the on-screen room name)

local gui = require('gui')
local overlay = require('plugins.overlay')

local DWARF_SECS = 30
local ROOM_SECS = 20
local TICK_FRAMES = 60

-- shared with other scripts (the broadsheet's state script reads it)
tour = rawget(_G, 'dfai_tour') or {running = false, current = nil, idx = 0, last_switch = 0, rooms = nil, rooms_at = 0, view = nil}
rawset(_G, 'dfai_tour', tour)

local function site() return dfhack.world.getCurrentSite() end

local function loc_of(zone)
    local s = site()
    if not s or zone.location_id == -1 then return nil end
    for _, b in ipairs(s.buildings) do
        if b.id == zone.location_id then return b end
    end
end

local LOC_KIND = {
    [df.abstract_building_type.TEMPLE] = 'Temple',
    [df.abstract_building_type.INN_TAVERN] = 'Tavern',
    [df.abstract_building_type.LIBRARY] = 'Library',
    [df.abstract_building_type.GUILDHALL] = 'Guildhall',
    [df.abstract_building_type.HOSPITAL] = 'Hospital',
}

local function center(b) return xyz2pos((b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z) end

local function find_rooms()
    local rooms, seen_loc = {}, {}
    local counts = {}
    local function add(name, kind, pos)
        counts[kind] = (counts[kind] or 0) + 1
        rooms[#rooms + 1] = {name = name, kind = kind, pos = pos}
    end
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if z.spec_sub_flag.active ~= false then
            local loc = loc_of(z)
            if loc and not seen_loc[loc.id] then
                seen_loc[loc.id] = true
                local kind = LOC_KIND[loc:getType()] or 'Hall'
                add(dfhack.df2utf(dfhack.translation.translateName(loc.name, true)), kind, center(z))
            elseif not loc then
                local t = z.type
                if t == df.civzone_type.DiningHall and (counts['Dining Hall'] or 0) < 2 then
                    add('The Dining Hall', 'Dining Hall', center(z))
                elseif t == df.civzone_type.MeetingHall and (counts['Meeting Hall'] or 0) < 2 then
                    add('The Meeting Hall', 'Meeting Hall', center(z))
                elseif t == df.civzone_type.Barracks and (counts['Barracks'] or 0) < 2 then
                    add('The Barracks', 'Barracks', center(z))
                elseif t == df.civzone_type.Pen and (z.x2 - z.x1 + 1) * (z.y2 - z.y1 + 1) >= 200 then
                    add('The Pasture', 'Pasture', center(z))
                end
            end
        end
    end
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
        add('The Trade Depot', 'Trade Depot', center(b))
        break
    end
    -- machine rooms: a cluster of screw pumps (the mist generator); show the
    -- room the mist falls into, one level below the pumps
    local px, py, pz, n = 0, 0, nil, 0
    for _, b in ipairs(df.global.world.buildings.other.SCREW_PUMP) do
        if not pz or b.z == pz then
            pz = b.z
            px, py, n = px + b.centerx, py + b.centery, n + 1
        end
    end
    if n >= 3 then
        add('The Mist Chamber', 'Mist Generator', xyz2pos(px // n, py // n, pz - 1))
    end
    local wx, wy, wz, wn = 0, 0, nil, 0
    for _, b in ipairs(df.global.world.buildings.other.WINDMILL) do
        if not wz or b.z == wz then
            wz = b.z
            wx, wy, wn = wx + b.centerx, wy + b.centery, wn + 1
        end
    end
    if wn >= 2 then
        add('The Windmills', 'They power the mist generator', xyz2pos(wx // wn, wy // wn, wz))
    end
    -- places df-ai planned that have no DF zone (written by supervisor/dfai_poi.py)
    local pois = {}
    local ok, data = pcall(function()
        return require('json').decode_file(dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json')
    end)
    local s = site()
    if ok and data and s and data.site_id == s.id then
        for _, p in ipairs(data.pois or {}) do
            pois[#pois + 1] = {name = p.name, kind = p.kind, pos = xyz2pos(p.x, p.y, p.z)}
        end
    end
    -- interleave rooms and points of interest so the tour mixes them
    local mixed, i, j = {}, 1, 1
    while i <= #rooms or j <= #pois do
        if i <= #rooms then mixed[#mixed + 1] = rooms[i]; i = i + 1 end
        if j <= #pois then mixed[#mixed + 1] = pois[j]; j = j + 1 end
    end
    return mixed
end

local function spectate_on()
    local ok, plugin = pcall(require, 'plugins.spectate')
    if ok and plugin and plugin.isEnabled then return plugin.isEnabled() end
    return false
end

local function view() return ('%d,%d,%d'):format(df.global.window_x, df.global.window_y, df.global.window_z) end

local function show_next_room()
    if not tour.rooms or os.time() - tour.rooms_at > 300 then
        tour.rooms, tour.rooms_at = find_rooms(), os.time()
    end
    if #tour.rooms == 0 then return false end
    tour.idx = tour.idx % #tour.rooms + 1
    local r = tour.rooms[tour.idx]
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = -1
    dfhack.gui.revealInDwarfmodeMap(r.pos, true, true)
    tour.current, tour.view = r, view()
    tour.last_switch = os.time()
    return true
end

-- guests: interesting creatures that aren't the fort's dwarves (visitors,
-- merchants, diplomats, animal people, elves, goblins, odd peaceful beasts)
local GUEST_SECS = 25
local GUEST_GAP = 120 -- the same guest isn't shown again for this long

local function revealed(u)
    local f = dfhack.maps.getTileFlags(xyz2pos(dfhack.units.getPosition(u)))
    return f and not f.hidden
end

local function is_guest(u)
    if not dfhack.units.isActive(u) or dfhack.units.isDead(u) or dfhack.units.isCitizen(u) then return false end
    if dfhack.units.isForgottenBeast(u) or dfhack.units.isMegabeast(u) or dfhack.units.isSemiMegabeast(u)
        or dfhack.units.isTitan(u) or dfhack.units.isDemon(u) or dfhack.units.isInvader(u) or dfhack.units.isGreatDanger(u) then
        return false
    end
    if u.flags1.caged or u.flags1.chained or dfhack.units.isTame(u) or dfhack.units.isUndead(u) then return false end
    if dfhack.units.isDanger(u) and not (dfhack.units.isVisitor(u) or dfhack.units.isMerchant(u) or dfhack.units.isDiplomat(u)) then
        return false -- invaders and monsters: spectate's own hostile picks cover those
    end
    if not revealed(u) then return false end
    local raw = df.creature_raw.find(u.race)
    if not raw then return false end
    if dfhack.units.isVisitor(u) or dfhack.units.isMerchant(u) or dfhack.units.isDiplomat(u) or dfhack.units.isForest(u) then
        return true
    end
    -- animal people and other people (elves, goblins, humans, kobolds...)
    if raw.flags.HAS_ANY_INTELLIGENT_SPEAKS or raw.flags.HAS_ANY_INTELLIGENT_LEARNS then return u.race ~= df.global.plotinfo.race_id end
    -- odd peaceful wildlife: fanciful/good/evil creatures, not vermin swarms
    return (raw.flags.FANCIFUL or raw.flags.GOOD or raw.flags.EVIL) and not dfhack.units.isForgottenBeast(u) and not dfhack.units.isDemon(u)
end

is_guest_check = is_guest

local function pick_guest()
    tour.guest_seen = tour.guest_seen or {}
    local best, best_t
    local now = os.time()
    for _, u in ipairs(df.global.world.units.active) do
        local ok, g = pcall(is_guest, u)
        if ok and g then
            local t = tour.guest_seen[u.id] or 0
            if now - t >= GUEST_GAP and (not best or t < best_t) then best, best_t = u, t end
        end
    end
    return best
end

local function show_guest()
    local u = pick_guest()
    if not u then return false end
    tour.guest_seen[u.id] = os.time()
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = u.id
    tour.guest, tour.current = u.id, nil
    tour.last_switch = os.time()
    return true
end

local function back_to_dwarves()
    if tour.guest and df.global.plotinfo.follow_unit == tour.guest then
        df.global.plotinfo.follow_unit = -1 -- let spectate pick a dwarf right away
    end
    tour.current, tour.guest = nil, nil
    dfhack.run_command_silent('enable', 'spectate')
    tour.last_switch = os.time()
end

local function step()
    if not dfhack.isMapLoaded() or not dfhack.gui.matchFocusString('dwarfmode/Default') then
        return
    end
    local now = os.time()
    if tour.current then
        if view() ~= tour.view then
            tour.current = nil -- a person moved the map: leave the camera to them
            return
        end
        if now - tour.last_switch >= ROOM_SECS then
            -- after a room, visit a guest if one is around, else back to dwarves
            tour.current = nil
            if not show_guest() then back_to_dwarves() end
        end
    elseif tour.guest then
        local u = df.unit.find(tour.guest)
        if df.global.plotinfo.follow_unit ~= tour.guest then
            back_to_dwarves() -- the camera lost the guest (or someone took it)
        elseif not u or not dfhack.units.isActive(u) or now - tour.last_switch >= GUEST_SECS then
            back_to_dwarves()
        end
    elseif spectate_on() and now - tour.last_switch >= DWARF_SECS then
        show_next_room()
    end
end

local function tick()
    if not tour.running then return end
    dfhack.timeout(TICK_FRAMES, 'frames', tick)
    tour.ticks = (tour.ticks or 0) + 1
    local ok, err = pcall(step)
    if not ok then tour.last_error = tostring(err) end
end

-- on-screen label for the room being shown
RoomLabel = defclass(nil, overlay.OverlayWidget)  -- fresh class: reusing the old table kept stale methods across reloads
RoomLabel.ATTRS{
    desc = 'Stream banner: the room the camera is visiting, or the followed creature.',
    default_pos = {x = 60, y = 10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 52, h = 4},
    visible = function() local t = rawget(_G, 'dfai_tour') return (t ~= nil and t.current ~= nil) or df.global.plotinfo.follow_unit ~= -1 end,
}

local function centered(s, w)
    s = tostring(s or '')
    if #s >= w then return s:sub(1, w) end
    local pad = (w - #s) // 2
    return (' '):rep(pad) .. s .. (' '):rep(w - #s - pad)
end

-- what the banner shows: the room being toured, else the followed creature
local function banner_lines()
    local r = tour.current
    if r then return dfhack.utf2df(r.name):upper(), r.kind end
    local u = df.unit.find(df.global.plotinfo.follow_unit)
    if not u then return nil end
    local name = dfhack.units.getReadableName(u):gsub(',.*$', '')
    local prof = dfhack.units.getProfessionName(u)
    if u.race ~= df.global.plotinfo.race_id then
        local raw = df.creature_raw.find(u.race)
        local cname = raw and raw.name[0] or ''
        if cname ~= '' and not prof:lower():find(cname:lower(), 1, true) then prof = cname:gsub('^%l', string.upper) .. ' ' .. prof end
        if prof:upper() == name:upper() then prof = dfhack.units.isWildlife(u) and 'Wild creature' or 'Guest' end
        if dfhack.units.isMerchant(u) then prof = prof .. ' (merchant)'
        elseif dfhack.units.isDiplomat(u) then prof = prof .. ' (diplomat)'
        elseif dfhack.units.isVisitor(u) then prof = prof .. ' (visitor)' end
    end
    local job = u.job.current_job and dfhack.job.getName(u.job.current_job)
        or (u.race ~= df.global.plotinfo.race_id and 'Wandering' or 'No job')
    return name:upper(), prof .. ': ' .. job
end
RoomLabel_banner_lines = banner_lines

function RoomLabel:onRenderBody(dc)
    local l1, l2 = banner_lines()
    if not l1 then return end
    local r = {name = l1, kind = l2}
    local w, h = self.frame.w, self.frame.h
    local bg = {ch = 32, fg = COLOR_BLACK, bg = COLOR_BLACK}
    dc:fill(0, 0, w - 1, h - 1, bg)
    dc:seek(0, 0):pen{fg = COLOR_BROWN, bg = COLOR_BLACK}:string(('='):rep(w))
    dc:seek(0, 1):pen{fg = COLOR_YELLOW, bg = COLOR_BLACK}:string(centered(r.name, w))
    dc:seek(0, 2):pen{fg = COLOR_GREY, bg = COLOR_BLACK}:string(centered(r.kind, w))
    dc:seek(0, 3):pen{fg = COLOR_BROWN, bg = COLOR_BLACK}:string(('='):rep(w))
end

OVERLAY_WIDGETS = {label = RoomLabel}

if dfhack_flags.module then return end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    if not tour.running then tour.running = true; tour.last_switch = os.time(); tick() end
    print('dfai-room-tour: running')
elseif cmd == 'stop' then
    tour.running = false
    if tour.current then back_to_dwarves() end
    print('dfai-room-tour: stopped')
elseif cmd == 'next' then
    print(show_next_room() and ('showing ' .. tour.current.name) or 'no rooms')
elseif cmd == 'guests' then
    for _, u in ipairs(df.global.world.units.active) do
        local ok, g = pcall(is_guest, u)
        if ok and g then print(u.id, df.creature_raw.find(u.race).creature_id, dfhack.units.getReadableName(u)) end
    end
elseif cmd == 'guest' then
    print(show_guest() and ('following ' .. dfhack.units.getReadableName(df.unit.find(tour.guest))) or 'no guests')
elseif cmd == 'list' then
    for i, r in ipairs(find_rooms()) do print(i, r.kind, r.name, r.pos.x, r.pos.y, r.pos.z) end
else
    if tour.last_error then print('last error: ' .. tour.last_error) end
    print('dfai-room-tour: ' .. (tour.running and 'running' or 'stopped') .. (tour.current and (', showing ' .. tour.current.name) or ''))
end
