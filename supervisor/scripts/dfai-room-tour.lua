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
    -- finished projects that drew a crowd (mission mode promotes them)
    local okp, pm = pcall(reqscript, 'dfai-projects')
    if okp and pm and pm.promoted then
        for _, p in ipairs(pm.promoted()) do
            pois[#pois + 1] = {name = p.name, kind = p.kind or 'Built on stream', pos = xyz2pos(p.x, p.y, p.z),
                box = p.box and {p.box[1], p.box[2], p.box[4], p.box[5], p.box[3]} or nil}
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
    tour.guest, tour.current, tour.project = u.id, nil, nil
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

-- battle mode: the camera goes where the fighting is. Threats next to one of
-- our citizens (in the melee) come first, least recently shown first; with 3+
-- threats on the map the camera cuts every BATTLE_SECS. The banner counts them.
local BATTLE_SECS = 15
local function near_citizen(u, cits)
    local p = u.pos
    for _, c in ipairs(cits) do
        if c.z == p.z and math.abs(c.x - p.x) <= 5 and math.abs(c.y - p.y) <= 5 then return true end
    end
    return false
end

local function pick_threat()
    tour.threat_seen = tour.threat_seen or {}
    local now, best, best_s = os.time(), nil, nil
    local cits = {}
    for _, c in ipairs(dfhack.units.getCitizens(true)) do cits[#cits + 1] = c.pos end
    local n = 0
    for _, u in ipairs(df.global.world.units.active) do
        local ok, th = pcall(is_threat, u)
        if ok and th then
            n = n + 1
            local t = tour.threat_seen[u.id] or 0
            if now - t >= THREAT_GAP then
                local score = (now - t) + (near_citizen(u, cits) and 100000 or 0)
                if not best or score > best_s then best, best_s = u, score end
            end
        end
    end
    tour.battle_n = n
    return best
end

local function show_threat()
    local u = pick_threat()
    if not u then return false end
    local now = os.time()
    tour.threat_seen[u.id] = now
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = u.id
    tour.guest, tour.current, tour.threat, tour.project = u.id, nil, true, nil
    tour.last_switch = now
    return true
end

local function back_to_dwarves()
    if tour.guest and df.global.plotinfo.follow_unit == tour.guest then
        df.global.plotinfo.follow_unit = -1 -- let spectate pick a dwarf right away
    end
    tour.current, tour.guest, tour.threat, tour.project = nil, nil, nil, nil
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
            tour.current, tour.guest, tour.threat, tour.project = nil, nil, nil, nil
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

-- mission mode (user idea): follow a project as it gets built. Projects come
-- from dfai-projects (rescues, the deep shaft: anything a script or the console
-- posts) and from the job list (a new workshop, furnace, depot, well or bridge
-- going up). The camera follows the dwarf working inside the project's box
-- under a "PROJECT:" banner, and cuts to the result when it is finished.
local PROJECT_SECS = 40      -- following the worker
local PROJECT_EVERY = 4 * 60 -- some project at most this often
local PROJECT_GAP = 10 * 60  -- the same project again after this long
local DONE_SECS = 20         -- the finished-result shot
local SCAN_SECS = 10
local BIG_BUILDINGS = {
    [df.building_type.Workshop] = true, [df.building_type.Furnace] = true,
    [df.building_type.TradeDepot] = true, [df.building_type.Well] = true,
    [df.building_type.Bridge] = true, [df.building_type.Windmill] = true,
    [df.building_type.WaterWheel] = true, [df.building_type.ScrewPump] = true,
}
local WORK_JOBS = {
    [df.job_type.Dig] = true, [df.job_type.CarveUpwardStaircase] = true, [df.job_type.CarveDownwardStaircase] = true,
    [df.job_type.CarveUpDownStaircase] = true, [df.job_type.CarveRamp] = true, [df.job_type.DigChannel] = true,
    [df.job_type.ConstructBuilding] = true, [df.job_type.SmoothFloor] = true, [df.job_type.SmoothWall] = true,
    [df.job_type.CarveFortification] = true, [df.job_type.CarveTrack] = true, [df.job_type.DetailWall] = true,
    [df.job_type.DetailFloor] = true,
}

local function projects_mod()
    local ok, m = pcall(reqscript, 'dfai-projects')
    return ok and m or nil
end

local function in_box(pos, b)
    return pos.x >= b[1] - 1 and pos.x <= b[4] + 1 and pos.y >= b[2] - 1 and pos.y <= b[5] + 1 and pos.z >= b[3] and pos.z <= b[6]
end

local function bld_name(b)
    local ok, n = pcall(dfhack.buildings.getName, b)
    if ok and n and n ~= '' then return dfhack.df2utf(n) end
    return df.building_type[b:getType()] or 'building'
end

-- every SCAN_SECS: the live projects, each with the worker (if any) on a job in its box
local function scan_projects()
    local now = os.time()
    if tour.proj_list and now - (tour.proj_scan_at or 0) < SCAN_SECS then return tour.proj_list end
    tour.proj_scan_at = now
    tour.proj_auto = tour.proj_auto or {}
    local m = projects_mod()
    local list = {}
    if m then
        pcall(m.prune)
        for _, p in ipairs(m.list()) do list[#list + 1] = p end
    end
    -- rooms df-ai is digging (dfai_poi.py writes them from df-ai's plan)
    tour.proj_state = tour.proj_state or {}
    local ok, data = pcall(function() return require('json').decode_file(dfhack.getDFPath() .. '/dfhack-config/dfai-poi.json') end)
    if ok and data and data.projects then
        for _, r in ipairs(data.projects) do
            local st = tour.proj_state[r.key]
            if not st then
                st = {key = r.key, title = r.title, box = r.box, added = now, plan = true, promote = r.promote, kind = r.kind}
                local f = dfhack.maps.getTileFlags(r.box[1], r.box[2], r.box[3])
                if f and f.feature_global and r.kind == 'location' then
                    st.title = st.title:gsub('^A New ', 'A New Cavern ')
                end
                tour.proj_state[r.key] = st
            end
            list[#list + 1] = st
        end
    end
    for key, st in pairs(tour.proj_state) do
        if st.done and now - (st.done_at or now) > 3600 then tour.proj_state[key] = nil end
    end
    -- new big buildings going up
    local jobs = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if WORK_JOBS[j.job_type] then jobs[#jobs + 1] = j end
        if j.job_type == df.job_type.ConstructBuilding then
            local b = dfhack.job.getHolder(j)
            if b and BIG_BUILDINGS[b:getType()] then
                local key = 'bld:' .. b.id
                if not tour.proj_auto[key] then
                    tour.proj_auto[key] = {key = key, title = 'New ' .. bld_name(b), bld = b.id, added = now,
                        box = {b.x1, b.y1, b.z, b.x2, b.y2, b.z}}
                end
            end
        end
        l = l.next
    end
    for key, p in pairs(tour.proj_auto) do
        local b = df.building.find(p.bld)
        if not b then
            tour.proj_auto[key] = nil -- cancelled or removed
        else
            if not p.done and b:getBuildStage() >= b:getMaxBuildStage() then
                p.done, p.done_at, p.title = true, now, bld_name(b)
            end
            if p.done and now - p.done_at > 3600 then tour.proj_auto[key] = nil else list[#list + 1] = p end
        end
    end
    -- the worker in each box, and auto-finish for non-manual listed projects
    for _, p in ipairs(list) do
        p.worker, p.job, p.njobs = nil, nil, 0
        for _, j in ipairs(jobs) do
            if in_box(j.pos, p.box) then
                p.njobs = p.njobs + 1
                local w = dfhack.job.getWorker(j)
                if w and not p.worker then p.worker, p.job = w.id, dfhack.job.getName(j) end
            end
        end
        if not p.bld and (m or p.plan) then
            if p.njobs > 0 and not p.seen_work then
                if not p.plan then pcall(m.update, p.key, {seen_work = true}) end
                p.seen_work = true
            end
            if not p.done and not p.manual and p.seen_work and p.njobs == 0 then
                p.idle_scans = (tour.proj_idle or {})[p.key] or 0
                tour.proj_idle = tour.proj_idle or {}
                tour.proj_idle[p.key] = p.idle_scans + 1
                if p.idle_scans + 1 >= 3 then
                    if not p.plan then pcall(m.done, p.key) end
                    p.done, p.done_at = true, now
                end
            elseif tour.proj_idle then
                tour.proj_idle[p.key] = nil
            end
        end
    end
    -- progress (dug tiles in the box, or the building's stage), who worked
    -- on it, and the crowd once it is finished
    tour.proj_workers = tour.proj_workers or {}
    tour.proj_traffic = tour.proj_traffic or {}
    for _, p in ipairs(list) do
        local b = p.box
        if p.bld then
            local bb = df.building.find(p.bld)
            if bb and bb:getMaxBuildStage() > 0 then p.pct = math.floor(100 * bb:getBuildStage() / bb:getMaxBuildStage()) end
            p.what = 'built'
        elseif (b[4] - b[1] + 1) * (b[5] - b[2] + 1) * (b[6] - b[3] + 1) <= 400 then
            local open, all = 0, 0
            for z = b[3], b[6] do for y = b[2], b[5] do for x = b[1], b[4] do
                local tt = dfhack.maps.getTileType(x, y, z)
                if tt then
                    all = all + 1
                    if df.tiletype.attrs[tt].shape ~= df.tiletype_shape.WALL then open = open + 1 end
                end
            end end end
            if all > 0 then p.pct = math.floor(100 * open / all) end
            p.what = 'dug'
        end
        if p.worker then
            local w = df.unit.find(p.worker)
            local ws = tour.proj_workers[p.key] or {}
            tour.proj_workers[p.key] = ws
            if w then
                local nm = dfhack.df2utf(dfhack.units.getReadableName(w)):gsub(',.*$', ''):gsub('^(%S+).-"(.-)".*$', '%1 "%2"')
                if not ws[nm] then ws[nm] = true; ws[#ws + 1] = nm end
            end
        end
        if p.done and p.promote and not p.promoted then
            local n = 0
            for _, u in ipairs(df.global.world.units.active) do
                if dfhack.units.isActive(u) and in_box(u.pos, b) then n = n + 1 end
            end
            if n >= 3 then tour.proj_traffic[p.key] = (tour.proj_traffic[p.key] or 0) + 1 end
            if (tour.proj_traffic[p.key] or 0) >= 3 and m and m.promote then
                local name = p.real_name or p.title:gsub('^A New ', 'The '):gsub('^New ', 'The New ')
                pcall(m.promote, p.key, name, p.title, b)
                p.promoted = true
            end
        end
    end
    tour.proj_list = list
    return list
end
scan_projects_check = function() tour.proj_scan_at = 0 return scan_projects() end

local function box_center(b) return xyz2pos((b[1] + b[4]) // 2, (b[2] + b[5]) // 2, b[6]) end

-- the finished result, once per project
local function show_project_done()
    tour.proj_shown_done = tour.proj_shown_done or {}
    for _, p in ipairs(scan_projects()) do
        if p.done and not tour.proj_shown_done[p.key] then
            tour.proj_shown_done[p.key] = true
            local b = p.box
            -- the room's real name once DF knows it (a tavern called The Brash Voice)
            local okr, rooms = pcall(find_rooms)
            if okr then
                for _, r in ipairs(rooms) do
                    if r.box and r.box[5] >= b[3] and r.box[5] <= b[6] and r.pos.x >= b[1] and r.pos.x <= b[4] and r.pos.y >= b[2] and r.pos.y <= b[5] then
                        p.real_name = r.name
                        break
                    end
                end
            end
            local ws = tour.proj_workers and tour.proj_workers[p.key] or {}
            local m = projects_mod()
            if m and m.log_done then
                pcall(m.log_done, {title = p.title, name = p.real_name, z = b[3], workers = {table.unpack(ws, 1, math.min(#ws, 4))},
                    kind = p.kind or (p.bld and 'building') or p.key:match('^%a+'), year = df.global.cur_year,
                    month = df.global.cur_year_tick // 33600 + 1})
            end
            local pos = box_center(b)
            if p.key == 'deepdig' then pos = xyz2pos(b[1], b[2], b[3]) end -- the bottom of a shaft
            dfhack.run_command_silent('disable', 'spectate')
            df.global.plotinfo.follow_unit = -1
            dfhack.gui.revealInDwarfmodeMap(pos, true, true)
            local by = #ws > 0 and (' | by ' .. ws[1]:gsub(' ".*', '') .. (#ws > 1 and (' and ' .. (#ws - 1) .. ' more') or '')) or ''
            tour.current = {name = 'Project complete', short = (p.real_name or p.title) .. by, pos = pos, secs = DONE_SECS,
                box = {b[1], b[2], b[4], b[5], pos.z}}
            tour.view, tour.last_switch, tour.project = view(), os.time(), nil
            return true
        end
    end
    return false
end

-- critical projects (user: "stick to critical mission views like breaching
-- the caves so things aren't missed; even if it's not busy it's suspenseful"):
-- shown whenever someone is working on them, every CRITICAL_GAP, for longer
local CRITICAL_GAP = 2 * 60
local CRITICAL_SECS = 75
local function show_project(critical_only)
    local now = os.time()
    tour.proj_seen = tour.proj_seen or {}
    local best, best_t
    for _, p in ipairs(scan_projects()) do
        local u = p.worker and df.unit.find(p.worker)
        if not p.done and u and dfhack.units.isActive(u) and revealed(u) and (p.critical or not critical_only) then
            local t = tour.proj_seen[p.key] or 0
            local gap = p.critical and CRITICAL_GAP or PROJECT_GAP
            local due = p.critical or now - (tour.last_project_at or 0) >= PROJECT_EVERY
            if due and now - t >= gap and (not best or (p.critical and not best.critical) or (not not p.critical == not not best.critical and t < best_t)) then best, best_t = p, t end
        end
    end
    if not best then return false end
    tour.proj_seen[best.key] = now
    tour.last_project_at = now
    tour.proj_opened = tour.proj_opened or {}
    if not tour.proj_opened[best.key] then
        -- first time on stream: the site before the dwarves get far ("Breaking ground")
        tour.proj_opened[best.key] = true
        local b = best.box
        local pos = box_center(b)
        if best.key == 'deepdig' then pos = xyz2pos(b[1], b[2], b[3]) end
        dfhack.run_command_silent('disable', 'spectate')
        df.global.plotinfo.follow_unit = -1
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
        tour.current = {name = 'PROJECT: ' .. best.title, short = 'Breaking ground' .. (best.pct and (' | ' .. best.pct .. '% ' .. (best.what or 'done')) or ''),
            pos = pos, secs = 10, then_follow = best.key, box = {b[1], b[2], b[4], b[5], pos.z}}
        tour.view, tour.last_switch, tour.project = view(), now, nil
        return true
    end
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = best.worker
    tour.guest, tour.current, tour.threat, tour.project = best.worker, nil, nil, best
    tour.last_switch = now
    return true
end

-- leaves mode (user: "when the seasons change and the leaves visibly change,
-- take a breath and watch that"): on a new season the camera rests on a stand
-- of surface trees near the fort for LEAVES_SECS under a season banner
local LEAVES_SECS = 40
local SEASON_NAME = {[0] = 'Spring', 'Summer', 'Autumn', 'Winter'}
local SEASON_LINE = {[0] = 'New leaves on the trees', 'The trees in full leaf', 'The leaves are turning', 'Bare branches and the first frost'}
local function tree_spot()
    if tour.tree_spot and tour.tree_spot_at and os.time() - tour.tree_spot_at < 3600 then return tour.tree_spot end
    local cits = dfhack.units.getCitizens(true)
    local cx, cy, cz = 96, 96, 170
    if #cits > 0 then cx, cy, cz = cits[1].pos.x, cits[1].pos.y, cits[1].pos.z end
    local mx, my, mz = dfhack.maps.getTileSize()
    local best, bn
    for z = math.min(mz - 1, cz + 12), math.max(0, cz - 6), -1 do
        for x = 20, mx - 21, 6 do
            for y = 16, my - 17, 6 do
                local f = dfhack.maps.getTileFlags(x, y, z)
                if f and f.outside and not f.hidden then
                    local n = 0
                    for dx = -3, 3, 2 do for dy = -3, 3, 2 do
                        local tt = dfhack.maps.getTileType(x + dx, y + dy, z)
                        if tt then
                            local a = df.tiletype.attrs[tt]
                            if a.material == df.tiletype_material.TREE or a.material == df.tiletype_material.PLANT and a.shape == df.tiletype_shape.SAPLING then n = n + 1 end
                        end
                    end end
                    n = n * 10 - (math.abs(x - cx) + math.abs(y - cy)) // 8
                    if n > 20 and (not best or n > bn) then best, bn = xyz2pos(x, y, z), n end
                end
            end
        end
    end
    tour.tree_spot, tour.tree_spot_at = best, os.time()
    return best
end

local function show_leaves()
    local season = df.global.cur_season
    if tour.season == nil then tour.season = season return false end
    if season == tour.season then return false end
    tour.season = season
    local pos = tree_spot()
    if not pos then return false end
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = -1
    dfhack.gui.revealInDwarfmodeMap(pos, true, true)
    tour.current = {name = SEASON_NAME[season] or 'A new season', short = SEASON_LINE[season] or '', pos = pos, secs = LEAVES_SECS}
    tour.view, tour.last_switch, tour.guest, tour.project = view(), os.time(), nil, nil
    return true
end
show_leaves_check = function(force) if force then tour.season = -1 end return show_leaves() end

-- testing: take the next project now
function show_project_check() tour.last_project_at = 0 tour.proj_scan_at = 0 tour.proj_seen = {} return show_project() end

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
    if tour.project then
        for _, p in ipairs(scan_projects()) do
            if p.key == tour.project.key then tour.project = p end
        end
    end
    if not tour.threat and not (tour.current and tour.current.secs == LEAVES_SECS) and show_leaves() then return end
    if not tour.threat and not (tour.project and tour.project.critical) and not (tour.current and tour.current.then_follow)
        and (tour.current or spectate_on()) and show_project(true) then return end
    if tour.current then
        if view() ~= tour.view then
            tour.current = nil -- a person moved the map: leave the camera to them
            return
        end
        if now - tour.last_switch >= (tour.current.secs or ROOM_SECS) then
            -- after a room, visit a guest if one is around, else back to dwarves
            tour.prev_box = tour.current.box or {tour.current.pos.x - 5, tour.current.pos.y - 5, tour.current.pos.x + 5, tour.current.pos.y + 5, tour.current.pos.z}
            local follow = tour.current.then_follow
            tour.current = nil
            if follow then
                -- the opening shot is over: follow the worker
                for _, p in ipairs(scan_projects()) do
                    local u = p.key == follow and p.worker and df.unit.find(p.worker)
                    if u then
                        df.global.plotinfo.follow_unit = p.worker
                        tour.guest, tour.project, tour.last_switch = p.worker, p, os.time()
                        return
                    end
                end
            end
            if not show_project_done() and not show_guest() then back_to_dwarves() end
        end
    elseif tour.guest then
        local u = df.unit.find(tour.guest)
        if df.global.plotinfo.follow_unit ~= tour.guest then
            back_to_dwarves() -- the camera lost the guest (or someone took it)
        elseif tour.project and tour.project.done then
            tour.guest, tour.project = nil, nil
            if not show_project_done() then back_to_dwarves() end
        elseif not u or not dfhack.units.isActive(u) or dfhack.units.isDead(u)
            or now - tour.last_switch >= (tour.threat and ((tour.battle_n or 0) >= 3 and BATTLE_SECS or THREAT_SECS) or (tour.project and (tour.project.critical and CRITICAL_SECS or PROJECT_SECS)) or GUEST_SECS) then
            -- a threat's time is up (or it died): next threat if any, else dwarves
            if not (tour.threat and show_threat()) then back_to_dwarves() end
        end
    elseif spectate_on() and now - tour.last_switch >= DWARF_SECS then
        if not show_project_done() and not show_project() then show_next_room() end
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
-- the job, naming the item for hauling-type jobs ("Storing item in
-- stockpile" -> "Storing a copper battle axe in stockpile")
local function job_text(j)
    local name = dfhack.job.getName(j)
    if not name:lower():find('item', 1, true) then return name end
    -- the hauled thing, not the bin or barrel it goes into
    local it, cont
    local CONTAINER = {[df.item_type.BIN] = true, [df.item_type.BARREL] = true, [df.item_type.BOX] = true,
        [df.item_type.BAG] = true, [df.item_type.TOOL] = true}
    for _, ref in ipairs(j.items) do
        if ref.item then
            if CONTAINER[ref.item:getType()] then cont = cont or ref.item
            elseif not it then it = ref.item end
        end
    end
    it = it or cont
    if not it then return name end
    local ok, desc = pcall(dfhack.items.getReadableDescription, it)
    if not ok or not desc or desc == '' then ok, desc = pcall(dfhack.items.getDescription, it, 0, true) end
    if not ok or not desc or desc == '' then return name end
    -- keep DF's own encoding (the banner draws in it), and drop the quality
    -- marks round crafted items (-x- +x+ *x* and the CP437 quality symbols)
    local marks = '[%-%+%*' .. string.char(240, 15, 174, 175) .. ']'
    desc = desc:gsub('%s*<#%d+>', '')
    for _ = 1, 3 do desc = desc:gsub('^' .. marks, ''):gsub(marks .. '$', '') end
    desc = desc:gsub('^%u', string.lower)
    local out, n = name:gsub('[Ii]tems?', desc, 1)
    return n > 0 and out or (name .. ': ' .. desc)
end
job_text_check = job_text

local function banner_lines()
    local r = tour.current
    if r then return dfhack.utf2df(r.name):upper(), dfhack.utf2df(r.short or r.kind or '') end
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
    if tour.project and tour.guest == u.id then
        local job = u.job.current_job and job_text(u.job.current_job) or tour.project.job or 'On the way'
        local pct = tour.project.pct and (' (' .. tour.project.pct .. '% ' .. (tour.project.what or 'done') .. ')') or ''
        return ((tour.project.critical and 'MISSION: ' or 'PROJECT: ') .. dfhack.utf2df(tour.project.title)):upper() .. pct, name .. ', ' .. prof .. ': ' .. job
    end
    if tour.threat and tour.guest == u.id then
        local alive, fallen = 0, 0
        for _, x in ipairs(df.global.world.units.active) do
            if x.flags1.active_invader or x.flags2.visitor_uninvited then
                if dfhack.units.isDead(x) then fallen = fallen + 1 elseif dfhack.units.isActive(x) then alive = alive + 1 end
            end
        end
        local tag = alive + fallen > 1 and ('BATTLE: %d invaders, %d fallen'):format(alive, fallen) or 'BATTLE'
        return name:upper(), tag .. ' | ' .. prof
    end
    local job = u.job.current_job and job_text(u.job.current_job)
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
