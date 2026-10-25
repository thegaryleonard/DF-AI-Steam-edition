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
    return rooms
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

local function back_to_dwarves()
    tour.current = nil
    dfhack.run_command_silent('enable', 'spectate')
    tour.last_switch = os.time()
end

local function tick()
    if not tour.running then return end
    dfhack.timeout(TICK_FRAMES, 'frames', tick)
    if not dfhack.isMapLoaded() or not dfhack.gui.matchFocusString('dwarfmode/Default') then
        return
    end
    local now = os.time()
    if tour.current then
        if view() ~= tour.view then
            tour.current = nil -- a person moved the map: leave the camera to them
            return
        end
        if now - tour.last_switch >= ROOM_SECS then back_to_dwarves() end
    elseif spectate_on() and now - tour.last_switch >= DWARF_SECS then
        show_next_room()
    end
end

-- on-screen label for the room being shown
RoomLabel = defclass(RoomLabel, overlay.OverlayWidget)
RoomLabel.ATTRS{
    desc = 'Shows the name of the room the stream camera is visiting.',
    default_pos = {x = 60, y = 10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 52, h = 4},
    visible = function() local t = rawget(_G, 'dfai_tour') return t ~= nil and t.current ~= nil end,
}

local function centered(s, w)
    s = tostring(s or '')
    if #s >= w then return s:sub(1, w) end
    local pad = (w - #s) // 2
    return (' '):rep(pad) .. s .. (' '):rep(w - #s - pad)
end

function RoomLabel:onRenderBody(dc)
    local r = tour.current
    if not r then return end
    local w, h = self.frame.w, self.frame.h
    local bg = {ch = 32, fg = COLOR_BLACK, bg = COLOR_BLACK}
    dc:fill(0, 0, w - 1, h - 1, bg)
    dc:seek(0, 0):pen{fg = COLOR_BROWN, bg = COLOR_BLACK}:string(('='):rep(w))
    dc:seek(0, 1):pen{fg = COLOR_YELLOW, bg = COLOR_BLACK}:string(centered(dfhack.utf2df(r.name):upper(), w))
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
elseif cmd == 'list' then
    for i, r in ipairs(find_rooms()) do print(i, r.kind, r.name, r.pos.x, r.pos.y, r.pos.z) end
else
    print('dfai-room-tour: ' .. (tour.running and 'running' or 'stopped') .. (tour.current and (', showing ' .. tour.current.name) or ''))
end
