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

local function tr(name, eng) return dfhack.df2utf(dfhack.translation.translateName(name, eng)) end

local function deity_line(hf)
    local sp = {}
    if hf.info and hf.info.metaphysical then
        for _, s in ipairs(hf.info.metaphysical.spheres) do sp[#sp + 1] = df.sphere_type[s]:lower():gsub('_', ' ') end
    end
    local god = tr(hf.name, false)
    if #sp > 0 then local n = math.min(#sp, 3)
        local list = n == 1 and sp[1] or (table.concat(sp, ', ', 1, n - 1) .. ' and ' .. sp[n])
        return god, 'god of ' .. list end
    return god, 'a god'
end

-- who a temple or guildhall belongs to: (long text for the broadsheet, short for the banner)
function loc_detail(loc)
    local t = loc:getType()
    if t == df.abstract_building_type.TEMPLE then
        if loc.deity_type == 0 then
            local hf = df.historical_figure.find(loc.deity_data.Deity)
            if hf then
                local god, what = deity_line(hf)
                return ('Dedicated to %s, %s.'):format(god, what), 'Temple of ' .. god
            end
        elseif loc.deity_type == 1 then
            local e = df.historical_entity.find(loc.deity_data.Religion)
            if e then
                local rel = tr(e.name, true)
                local line = ('Home of %s.'):format(rel)
                if #e.relations.deities > 0 then
                    local hf = df.historical_figure.find(e.relations.deities[0])
                    if hf then
                        local god, what = deity_line(hf)
                        line = ('Home of %s, who worship %s, %s.'):format(rel, god, what)
                    end
                end
                return line, 'Temple: ' .. rel
            end
        end
        return 'Open to every god the fort prays to.', 'Temple to all gods'
    elseif t == df.abstract_building_type.GUILDHALL then
        local prof = loc.contents.profession
        if prof and prof >= 0 then
            local cap = df.profession.attrs[prof].caption or df.profession[prof]
            local plural = cap:match('dwarf$') and (cap:sub(1, -6) .. 'dwarves') or cap:match('man$') and (cap:sub(1, -4) .. 'men') or (cap .. 's')
            return ('The guild of the %s.'):format(plural:lower()), 'Guildhall of the ' .. plural
        end
    end
end

local function center(b) return xyz2pos((b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z) end

local function find_rooms()
    local rooms, seen_loc = {}, {}
    local counts = {}
    local function add(name, kind, pos, detail, short, box)
        counts[kind] = (counts[kind] or 0) + 1
        rooms[#rooms + 1] = {name = name, kind = kind, pos = pos, detail = detail, short = short, box = box}
    end
    local function box(b) return {b.x1, b.y1, b.x2, b.y2, b.z} end
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if z.spec_sub_flag.active ~= false then
            local loc = loc_of(z)
            if loc and not seen_loc[loc.id] then
                seen_loc[loc.id] = true
                local kind = LOC_KIND[loc:getType()] or 'Hall'
                local ok, detail, short = pcall(loc_detail, loc)
                if not ok then detail, short = nil, nil end
                add(dfhack.df2utf(dfhack.translation.translateName(loc.name, true)), kind, center(z), detail, short, box(z))
            elseif not loc then
                local t = z.type
                if t == df.civzone_type.DiningHall and (counts['Dining Hall'] or 0) < 2 then
                    add('The Dining Hall', 'Dining Hall', center(z), nil, nil, box(z))
                elseif t == df.civzone_type.MeetingHall and (counts['Meeting Hall'] or 0) < 2 then
                    add('The Meeting Hall', 'Meeting Hall', center(z), nil, nil, box(z))
                elseif t == df.civzone_type.Barracks and (counts['Barracks'] or 0) < 2 then
                    add('The Barracks', 'Barracks', center(z), nil, nil, box(z))
                elseif t == df.civzone_type.Pen and (z.x2 - z.x1 + 1) * (z.y2 - z.y1 + 1) >= 200 then
                    add('The Pasture', 'Pasture', center(z), nil, nil, box(z))
                end
            end
        end
    end
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
        add('The Trade Depot', 'Trade Depot', center(b), nil, nil, box(b))
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
    -- the deep dig's current bottom (dfai-deep-dig.lua)
    local okd, deep = pcall(function()
        return require('json').decode_file(dfhack.getDFPath() .. '/dfhack-config/dfai-deep.json')
    end)
    if okd and deep and s and deep.site_id == s.id and deep.x and deep.bottom then
        pois[#pois + 1] = {name = deep.status == 'done' and 'The Deep Hall' or 'The Deep Shaft',
            kind = ('%d levels below the caverns'):format(deep.levels or 0), pos = xyz2pos(deep.x, deep.y, deep.bottom)}
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

-- Busy spots: where a crowd of the fort's dwarves is doing the same thing
-- right now (a dig face, a building site, harvest, a party). Found fresh at
-- every pick from units.active only (bounded, no map scans).
local JOB_GROUP = {
    Dig = 'dig', DigChannel = 'dig', CarveRamp = 'dig', CarveUpwardStaircase = 'dig', CarveDownwardStaircase = 'dig',
    CarveUpDownStaircase = 'dig', DetailWall = 'smooth', DetailFloor = 'smooth', CarveFortification = 'smooth', CarveTrack = 'smooth',
    ConstructBuilding = 'build', CarveTrack2 = 'build', FellTree = 'wood', HarvestPlant = 'farm', PlantSeeds = 'farm',
    GatherPlants = 'farm', Fish = 'fish', StoreItemInStockpile = 'haul', StoreItemInBag = 'haul', StoreItemInBarrel = 'haul',
    StoreItemInBin = 'haul', BringItemToDepot = 'trade', BringItemToShop = 'haul', Eat = 'eat', Drink = 'eat', DrinkItem = 'eat',
    Pray = 'pray', Socialize = 'party', PerformMusic = 'party', PerformDance = 'party', PerformStory = 'party', PerformPoetry = 'party',
    Train = 'train', MilitaryTrain = 'train', SparringPartner = 'train', MakeWeapon = 'forge', MakeArmor = 'forge',
    SmeltOre = 'forge', BuryCorpse = 'bury', DumpItem = 'dump',
}
local GROUP_NAME = {
    dig = {'The Dig Face', 'dwarves digging'}, smooth = {'The Engravers', 'dwarves smoothing and carving stone'},
    build = {'A Building Site', 'dwarves building'}, wood = {'The Woodcutters', 'dwarves felling trees'},
    farm = {'The Fields', 'dwarves at the harvest'}, fish = {'The Fishing Hole', 'dwarves fishing'},
    haul = {'The Haulers', 'dwarves hauling'}, trade = {'The Depot Rush', 'dwarves carrying goods to trade'},
    eat = {'Supper Time', 'dwarves eating and drinking'}, pray = {'A Prayer Meeting', 'dwarves praying'},
    party = {'A Party', 'dwarves dancing, playing and talking'}, train = {'Drill Practice', 'soldiers training'},
    forge = {'The Forges Roar', 'smiths at work'}, bury = {'A Funeral', 'dwarves burying the dead'},
    dump = {'The Refuse Run', 'dwarves taking out the garbage'},
}
local SPOT = 12 -- crowd grid cell, tiles

local function unit_positions()
    local list = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.caged
                and (dfhack.units.isCitizen(u) or dfhack.units.isVisitor(u) or dfhack.units.isMerchant(u)) then
            local j = u.job.current_job
            list[#list + 1] = {x = u.pos.x, y = u.pos.y, z = u.pos.z, job = j and df.job_type[j.job_type], cit = dfhack.units.isCitizen(u)}
        end
    end
    return list
end

local function busy(r, units)
    local n = 0
    local b = r.box
    for _, u in ipairs(units) do
        if b then
            if u.z == b[5] and u.x >= b[1] - 1 and u.x <= b[3] + 1 and u.y >= b[2] - 1 and u.y <= b[4] + 1 then n = n + 1 end
        elseif u.z == r.pos.z and math.abs(u.x - r.pos.x) <= 5 and math.abs(u.y - r.pos.y) <= 5 then
            n = n + 1
        end
    end
    return n
end

local function busy_spots(units)
    local cells = {}
    for _, u in ipairs(units) do
        local g = u.cit and u.job and JOB_GROUP[u.job]
        if g then
            local k = ('%s:%d:%d:%d'):format(g, u.x // SPOT, u.y // SPOT, u.z)
            local c = cells[k]
            if not c then c = {g = g, n = 0, sx = 0, sy = 0, z = u.z}; cells[k] = c end
            c.n, c.sx, c.sy = c.n + 1, c.sx + u.x, c.sy + u.y
        end
    end
    local spots = {}
    for _, c in pairs(cells) do
        -- hauling and eating are everywhere: only big crowds count
        local need = (c.g == 'haul' or c.g == 'eat') and 6 or (c.g == 'dig' or c.g == 'build' or c.g == 'smooth') and 3 or 4
        if c.n >= need then
            local nm = GROUP_NAME[c.g]
            spots[#spots + 1] = {name = nm[1], kind = ('%d %s'):format(c.n, nm[2]), spot = c.g, n = c.n,
                pos = xyz2pos(c.sx // c.n, c.sy // c.n, c.z)}
        end
    end
    return spots
end

-- Pick the next place: busy places first, but nothing is forgotten. A room
-- unseen for OVERDUE seconds jumps the queue (the garbage chute gets its turn),
-- and no place repeats within MIN_GAP.
local OVERDUE, MIN_GAP, SPOT_GAP = 30 * 60, 15 * 60, 8 * 60
-- rooms can share a name (three temples to one god): key by place too
local function key_of(r) return r.spot and ('spot:' .. r.spot) or ('%s@%d,%d,%d'):format(r.name, r.pos.x, r.pos.y, r.pos.z) end
local function pick_room()
    if not tour.rooms or os.time() - tour.rooms_at > 300 then
        tour.rooms, tour.rooms_at = find_rooms(), os.time()
    end
    tour.shown = tour.shown or {}
    tour.started = tour.started or os.time()
    local now, units = os.time(), unit_positions()
    local cands = {}
    for _, r in ipairs(tour.rooms) do cands[#cands + 1] = r end
    for _, sp in ipairs(busy_spots(units)) do cands[#cands + 1] = sp end
    local best, bs
    for _, r in ipairs(cands) do
        local key = key_of(r)
        -- never shown: as if last seen half an OVERDUE before the tour started (jittered)
        r.jit = r.jit or (r.spot and 0 or math.random(0, 600))
        local seen = tour.shown[key]
        local stale = seen and (now - seen) or (now - tour.started + OVERDUE // 2 - r.jit)
        if stale >= (r.spot and SPOT_GAP or MIN_GAP) then
            local b = r.spot and r.n or busy(r, units)
            r.busy = b
            local score = math.min(stale, OVERDUE) / 60 + 1.5 * math.min(b, 6) + (r.spot and 4 or 0)
            if (r.spot or r.kind) == tour.last_kind then score = score - 20 end -- not two barracks in a row
            if stale >= OVERDUE then score = 1000 + stale / 60 end
            if not bs or score > bs then best, bs = r, score end
        end
    end
    if best then tour.shown[key_of(best)] = now; tour.last_kind = best.spot or best.kind; tour.last_pick = ('%s (busy %d)'):format(best.name, best.busy or 0) end
    return best
end

local function show_next_room()
    local r = pick_room()
    if not r then return false end
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
local GUEST_GAP = 600 -- the same guest isn't shown again for this long
local GUEST_EVERY = 5 * 60 -- and some guest at most this often

local function revealed(u)
    if tour.test_reveal_all then return true end -- testing only
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
    -- wild creatures (cave critters, wandering animal people) just run around: skip
    if dfhack.units.isWildlife(u) then return false end
    -- other people (elves, goblins, humans, kobolds...) on the map
    if raw.flags.HAS_ANY_INTELLIGENT_SPEAKS or raw.flags.HAS_ANY_INTELLIGENT_LEARNS then return u.race ~= df.global.plotinfo.race_id end
    return false
end

is_guest_check = is_guest

local function pick_guest()
    tour.guest_seen = tour.guest_seen or {}
    local best, best_t
    local now = os.time()
    for _, u in ipairs(df.global.world.units.active) do
        local ok, g = pcall(is_guest, u)
        local b = tour.prev_box
        if ok and g and b and u.pos.z == b[5] and u.pos.x >= b[1] - 2 and u.pos.x <= b[3] + 2 and u.pos.y >= b[2] - 2 and u.pos.y <= b[4] + 2 then
            g = false -- the room we just showed: we've seen them
        end
        if ok and g then
            local t = tour.guest_seen[u.id] or 0
            if now - t >= GUEST_GAP and (not best or t < best_t) then best, best_t = u, t end
        end
    end
    return best
end

local function show_guest()
    if os.time() - (tour.last_guest_at or 0) < GUEST_EVERY then return false end
    local u = pick_guest()
    if not u then return false end
    tour.guest_seen[u.id] = os.time()
    tour.last_guest_at = os.time()
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = u.id
    tour.guest, tour.current = u.id, nil
    tour.last_switch = os.time()
    return true
end

-- threats: forgotten beasts, megabeasts, titans, demons, invaders. While any
-- is on uncovered map the camera stays on threats (the audience wants blood,
-- user's call), rotating between them every THREAT_SECS, least recently shown first.
local THREAT_SECS = 30
local THREAT_GAP = 0

local function is_threat(u)
    if not dfhack.units.isActive(u) or dfhack.units.isDead(u) or dfhack.units.isCitizen(u) then return false end
    if u.flags1.caged or u.flags1.chained then return false end
    local big = dfhack.units.isForgottenBeast(u) or dfhack.units.isMegabeast(u) or dfhack.units.isSemiMegabeast(u)
        or dfhack.units.isTitan(u) or dfhack.units.isDemon(u) or dfhack.units.isGreatDanger(u)
    if not big and not (dfhack.units.isInvader(u) and dfhack.units.isDanger(u)) then return false end
    return revealed(u)
end
is_threat_check = is_threat

local function pick_threat()
    tour.threat_seen = tour.threat_seen or {}
    local now, best, best_t = os.time(), nil, nil
    for _, u in ipairs(df.global.world.units.active) do
        local ok, th = pcall(is_threat, u)
        if ok and th then
            local t = tour.threat_seen[u.id] or 0
            if now - t >= THREAT_GAP and (not best or t < best_t) then best, best_t = u, t end
        end
    end
    return best
end

local function show_threat()
    local u = pick_threat()
    if not u then return false end
    local now = os.time()
    tour.threat_seen[u.id] = now
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = u.id
    tour.guest, tour.current, tour.threat = u.id, nil, true
    tour.last_switch = now
    return true
end

local function back_to_dwarves()
    if tour.guest and df.global.plotinfo.follow_unit == tour.guest then
        df.global.plotinfo.follow_unit = -1 -- let spectate pick a dwarf right away
    end
    tour.current, tour.guest, tour.threat = nil, nil, nil
    dfhack.run_command_silent('enable', 'spectate')
    tour.last_switch = os.time()
end

-- the camera must never die: a followed creature that leaves the map (a squad
-- off on a raid, a messenger, a merchant) or a camera left with nothing to do
-- hands control back to spectate
local IDLE_SECS = 45
local function camera_watchdog()
    local fu = df.global.plotinfo.follow_unit
    if fu ~= -1 then
        local u = df.unit.find(fu)
        if not u or not dfhack.units.isActive(u) or u.flags1.inactive or dfhack.units.isDead(u) then
            df.global.plotinfo.follow_unit = -1
            tour.current, tour.guest, tour.threat = nil, nil, nil
            dfhack.run_command_silent('enable', 'spectate')
            tour.last_switch = os.time()
            tour.idle_since = nil
            return
        end
    end
    if not tour.current and not tour.guest and not spectate_on() and df.global.plotinfo.follow_unit == -1 then
        tour.idle_since = tour.idle_since or os.time()
        if os.time() - tour.idle_since >= IDLE_SECS then
            dfhack.run_command_silent('enable', 'spectate')
            tour.idle_since = nil
        end
    else
        tour.idle_since = nil
    end
end

local function step()
    camera_watchdog()
    -- threats first: break into anything (room, guest, dwarf) except another threat,
    -- and only while the stream camera is in charge
    if not tour.threat and (tour.current or tour.guest or spectate_on()) and pick_threat() then
        show_threat()
        return
    end
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
            tour.prev_box = tour.current.box or {tour.current.pos.x - 5, tour.current.pos.y - 5, tour.current.pos.x + 5, tour.current.pos.y + 5, tour.current.pos.z}
            tour.current = nil
            if not show_guest() then back_to_dwarves() end
        end
    elseif tour.guest then
        local u = df.unit.find(tour.guest)
        if df.global.plotinfo.follow_unit ~= tour.guest then
            back_to_dwarves() -- the camera lost the guest (or someone took it)
        elseif not u or not dfhack.units.isActive(u) or dfhack.units.isDead(u)
            or now - tour.last_switch >= (tour.threat and THREAT_SECS or GUEST_SECS) then
            -- a threat's time is up (or it died): next threat if any, else dwarves
            if not (tour.threat and show_threat()) then back_to_dwarves() end
        end
    elseif spectate_on() and now - tour.last_switch >= DWARF_SECS then
        show_next_room()
    end
end

local function tick(gen)
    -- one loop per start: a reloaded script's 'start' replaces the old loop
    if not tour.running or gen ~= tour.gen then return end
    dfhack.timeout(TICK_FRAMES, 'frames', function() tick(gen) end)
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
    if r then return dfhack.utf2df(r.name):upper(), dfhack.utf2df(r.short or r.kind) end
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
    tour.running = true; tour.last_switch = os.time(); tour.started = tour.started or os.time(); tour.gen = (tour.gen or 0) + 1; tick(tour.gen)
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
elseif cmd == 'threats' then
    for _, u in ipairs(df.global.world.units.active) do
        local ok, th = pcall(is_threat, u)
        if ok and th then print(u.id, df.creature_raw.find(u.race).creature_id, dfhack.units.getReadableName(u)) end
    end
elseif cmd == 'guest' then
    print(show_guest() and ('following ' .. dfhack.units.getReadableName(df.unit.find(tour.guest))) or 'no guests')
elseif cmd == 'busy' then
    local units = unit_positions()
    for _, sp in ipairs(busy_spots(units)) do print('spot', sp.name, sp.kind, sp.pos.x, sp.pos.y, sp.pos.z) end
    for _, r in ipairs(find_rooms()) do
        local key = key_of(r)
        print(('%-32s busy %2d  last shown %s'):format(r.name, busy(r, units), tour.shown and tour.shown[key] and (os.time() - tour.shown[key]) .. 's ago' or 'never'))
    end
elseif cmd == 'list' then
    for i, r in ipairs(find_rooms()) do print(i, r.kind, r.name, r.pos.x, r.pos.y, r.pos.z) end
else
    if tour.last_error then print('last error: ' .. tour.last_error) end
    print('dfai-room-tour: ' .. (tour.running and 'running' or 'stopped') .. (tour.current and (', showing ' .. tour.current.name) or ''))
end
