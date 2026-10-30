-- dfai-build: dig and furnish a new room of any kind df-ai builds, on the
-- Overseer's order. Finds solid, dry rock beside a corridor near rooms of the
-- same kind, digs the room behind a doorway, then furnishes and zones it with
-- a generated quickfort blueprint (dfhack-config/blueprints/dfai-gen/). The
-- furniture comes from the fort's stock; df-ai makes more when it runs short.
--   dfai-build kinds              the menu, as JSON (for the desk)
--   dfai-build new <kind> [n]     order n rooms (they are built one at a time)
--   dfai-build find <kind>        dry run: where it would go
--   dfai-build cancel             drop the queue (a room being dug is kept)
--   dfai-build status | resume
--@module = true

local repeatUtil = require('repeat-util')
local json = require('json')
local KEY = 'dfai-build'
local BP = 'dfai-gen/room.csv'

-- u runs along the room's long side (0..L-1), v away from the door (0..S-1);
-- the door opens onto v=0 at the middle of the long side
local function catacomb(u, v, L, S) if (v == 0 and u ~= L // 2) or v == S - 1 then return 'n' end end
local function tables(u, v, L, S)
    if u >= 1 and u <= L - 2 and u % 2 == 1 then
        if v == 2 then return 't' end
        if v == 1 or v == 3 then return 'c' end
    end
end
local K = {
    catacomb  = {label = 'Catacomb wing', L = 9, S = 5, furn = catacomb, zone_each = 'T', near = {df.civzone_type.Tomb},
                 help = '17 coffins, each with its own tomb'},
    dormitory = {label = 'Dormitory', L = 9, S = 5, furn = function(u, v, L, S) if (v == 0 and u ~= L // 2) or v == S - 1 then return 'b' end end,
                 zone = 'D', near = {df.civzone_type.Dormitory, df.civzone_type.Bedroom}, help = '17 beds in one hall'},
    bedroom   = {label = 'Bedroom', L = 3, S = 3, furn = function(u, v) if v == 2 then return ({'f', 'b', 'h'})[u + 1] end end,
                 zone = 'b', near = {df.civzone_type.Bedroom}, help = 'a bed, a cabinet and a chest behind a door'},
    dining    = {label = 'Dining hall', L = 9, S = 5, furn = tables, zone = 'h', near = {df.civzone_type.DiningHall}, help = '4 tables, 8 chairs'},
    tavern    = {label = 'Tavern (citizens only)', L = 9, S = 5, furn = tables, zone = 'm{location=tavern allow=citizens}',
                 near = {df.civzone_type.MeetingHall, df.civzone_type.DiningHall}, help = 'tables and chairs; citizens only, so the fort keeps one public tavern'},
    temple    = {label = 'Temple', L = 9, S = 5, furn = function(u, v, L, S) if v == S - 1 and u % 2 == 0 and u > 0 and u < L - 1 then return 's' end end,
                 zone = 'm{location=temple}', near = {df.civzone_type.MeetingHall}, help = 'a hall to every god, with 3 statues'},
    hospital  = {label = 'Hospital', L = 9, S = 5, furn = function(u, v, L, S)
                     if v == S - 1 then return 'b' end
                     if v == 0 then return ({[0] = 'R', [1] = 'h', [2] = 't', [6] = 't', [7] = 'h', [8] = 'R'})[u] end end,
                 zone = 'm{location=hospital}', near = {df.civzone_type.MeetingHall}, help = '9 beds, 2 traction benches, tables and chests'},
    barracks  = {label = 'Barracks', L = 9, S = 5, furn = function(u, v, L, S)
                     if v == S - 1 then return 'b' end
                     if v == 0 and u ~= L // 2 then return (u % 2 == 0) and 'a' or 'r' end end,
                 zone = 'B', near = {df.civzone_type.Barracks}, help = '9 beds, armor stands and weapon racks'},
    pasture   = {label = 'Indoor pasture', L = 11, S = 9, soil = true, zone = 'n', near = {df.civzone_type.Pen},
                 help = 'dug in soil (cave grass only grows on soil); feeds about 12 grazers once the grass is in'},
    -- user: "another 20x20 room with a stockpile for the instruments, no
    -- containers ... make that part of the tavern zone and lets see what happens"
    music     = {label = 'Music hall (part of the public tavern)', L = 20, S = 20, pile = 'g', instruments = true, attach = 'public tavern',
                 help = 'a 20x20 hall beside the public tavern with an instruments-only stockpile, zoned into the tavern'},
    jail      = {label = 'Jail cell', L = 3, S = 3, furn = function(u, v) if u == 1 and v == 1 then return 'v' end end,
                 zone = 'j', near = {df.civzone_type.Dungeon}, help = 'a cell with a chain'},
}
local WORKSHOPS = {wc = "Carpenter's", wm = "Mason's", wr = "Craftsdwarf's", wf = "Metalsmith's forge", wj = "Jeweler's", wb = "Bowyer's",
    wt = "Mechanic's", wl = 'Still', wz = 'Kitchen', wu = "Butcher's", wn = "Tanner's", we = 'Leather works', wk = "Clothier's",
    wo = 'Loom', wh = 'Fishery', ww = "Farmer's", wy = 'Ashery', wd = "Dyer's", wS = "Soap maker's", wq = 'Quern',
    ws = 'Siege workshop', es = 'Smelter', ew = 'Wood furnace', eg = 'Glass furnace', ek = 'Kiln'}
for k, name in pairs(WORKSHOPS) do
    local plain = name:find("'s") ~= nil   -- "Carpenter's" -> "Carpenter's workshop"; "Kiln" stays
    K['workshop-' .. k] = {label = plain and (name .. ' workshop'):gsub(' forge workshop$', ' forge') or name,
        L = 5, S = 5, workshop = k, group = 'Workshops', help = 'in its own 5x5 room'}
end
local PILES = {f = 'Food', s = 'Stone', w = 'Wood', g = 'Finished goods', b = 'Bars and blocks', e = 'Gems', h = 'Cloth',
    l = 'Leather', p = 'Weapons', d = 'Armor', u = 'Furniture', z = 'Ammo', a = 'Animals', c = 'Corpses'}
for k, name in pairs(PILES) do
    K['stockpile-' .. k] = {label = name .. ' storeroom', L = 9, S = 5, pile = k, group = 'Storerooms', help = 'a 5x9 stockpile room'}
end

local function load() return dfhack.persistent.getSiteData(KEY, {queue = {}, built = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function project(fn, ...)
    local a = {...}
    pcall(function() reqscript('dfai-projects')[fn](table.unpack(a)) end)
end
local function attrs(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt]
end
local function is_wall(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == df.tiletype_shape.WALL and a.material ~= df.tiletype_material.CONSTRUCTION
        and a.material ~= df.tiletype_material.TREE and a.material ~= df.tiletype_material.ROOT
end
local function is_floor(x, y, z)
    local a = attrs(x, y, z)
    return a and a.shape == df.tiletype_shape.FLOOR
end
local function safe(x, y, z)
    if not dfhack.maps.isValidTilePos(x, y, z) or not is_wall(x, y, z) then return false end
    for dz = -1, 1 do for dx = -1, 1 do for dy = -1, 1 do
        local f = dfhack.maps.getTileFlags(x + dx, y + dy, z + dz)
        if not f then return false end
        if f.flow_size > 0 or f.water_table or f.outside or f.feature_global or f.feature_local then return false end
        local a = attrs(x + dx, y + dy, z + dz)
        if a and dz ~= 0 and a.shape == df.tiletype_shape.EMPTY then return false end
    end end end
    return true
end


-- designate a tile for digging with a priority (quickfort's own designation of
-- the doorway didn't stick: the corridor walls are smoothed, and something
-- clears it); the room behind it stays hidden until the doorway is open
local function designate(x, y, z, prio)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    if not f or not b then return end
    f.dig = df.tile_dig_designation.Default
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = prio or 2000
    b.flags.designated = true
end
-- (a designated tile becomes a Dig job and its flag clears: only re-mark
-- tiles with neither, or every check piles up another job)
local function keep_digging(w)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local jobs = {}
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.Dig and j.pos.z == w.z then jobs[j.pos.x * 10000 + j.pos.y] = true end
        l = l.next
    end
    local function want(x, y)
        if not is_floor(x, y, w.z) and not jobs[x * 10000 + y] and dfhack.maps.getTileFlags(x, y, w.z).dig == df.tile_dig_designation.No then
            designate(x, y, w.z, 2000)
        end
    end
    want(w.door[1], w.door[2])
    for _, c in ipairs(w.tunnel or {}) do want(c[1], c[2]) end
    for x = x1, x2 do for y = y1, y2 do want(x, y) end end
end
local DIRS = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
-- a room of L x S behind a door at corridor tile f + d
local function room_of(fx, fy, z, d, L, S, t)
    local dx, dy = d[1], d[2]
    t = t or 1
    local doorx, doory = fx + dx * t, fy + dy * t
    local x1, y1, x2, y2
    if dy ~= 0 then
        x1, x2 = doorx - (L // 2), doorx - (L // 2) + L - 1
        if dy < 0 then y2 = doory - 1 y1 = y2 - S + 1 else y1 = doory + 1 y2 = y1 + S - 1 end
    else
        y1, y2 = doory - (L // 2), doory - (L // 2) + L - 1
        if dx < 0 then x2 = doorx - 1 x1 = x2 - S + 1 else x1 = doorx + 1 x2 = x1 + S - 1 end
    end
    local tunnel = {}
    for i = 1, t - 1 do tunnel[#tunnel + 1] = {fx + dx * i, fy + dy * i} end
    return {door = {doorx, doory}, box = {x1, y1, x2, y2}, z = z, d = d, L = L, S = S, tunnel = tunnel}
end
-- room-local (u, v) of a map tile
local function uv(w, x, y)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local dx, dy = w.d[1], w.d[2]
    if dy ~= 0 then return x - x1, dy > 0 and (y - y1) or (y2 - y) end
    return y - y1, dx > 0 and (x - x1) or (x2 - x)
end
local function is_soil(x, y, z)
    local a = attrs(x, y, z)
    return a and a.material == df.tiletype_material.SOIL
end
local function fits(fx, fy, z, d, L, S, soil, t)
    local w = room_of(fx, fy, z, d, L, S, t)
    if not safe(w.door[1], w.door[2], z) then return nil end
    for _, c in ipairs(w.tunnel) do if not safe(c[1], c[2], z) then return nil end end
    local x1, y1, x2, y2 = table.unpack(w.box)
    for x = x1 - 1, x2 + 1 do for y = y1 - 1, y2 + 1 do
        if not (x == w.door[1] and y == w.door[2]) and not is_wall(x, y, z) then return nil end
        if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
            if not safe(x, y, z) then return nil end
            if soil and is_soil(x, y, z) then w.soil_n = (w.soil_n or 0) + 1 end
        end
    end end
    -- grass only grows on soil, and soil underground is ragged: most of it will do
    if soil and (w.soil_n or 0) < L * S * 0.7 then return nil end
    return w
end

-- where to look: around rooms of the same kind, else around the fort's busiest levels
-- the fort's public tavern (visitors allowed): the location and its zones
function public_tavern()
    local site = dfhack.world.getCurrentSite()
    if not site then return end
    for _, b in ipairs(site.buildings) do
        if b:getType() == df.abstract_building_type.INN_TAVERN and b.flags.VISITORS_ALLOWED then
            local zones = {}
            for _, id in ipairs(b.contents.building_ids) do
                local z = df.building.find(id)
                if z then zones[#zones + 1] = z end
            end
            if #zones > 0 then return b, zones end
        end
    end
end

local function anchors(kind)
    if kind.attach then
        local _, zones = public_tavern()
        local out = {}
        for _, z in ipairs(zones or {}) do out[#out + 1] = {z = z.z, n = 1, x = (z.x1 + z.x2) // 2, y = (z.y1 + z.y2) // 2} end
        return out
    end
    local want = {}
    for _, t in ipairs(kind.near or {}) do want[t] = true end
    local by = {}
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if not next(want) or want[z.type] then
            local k = z.z
            by[k] = by[k] or {z = k, n = 0, x = 0, y = 0}
            by[k].n, by[k].x, by[k].y = by[k].n + 1, by[k].x + (z.x1 + z.x2) // 2, by[k].y + (z.y1 + z.y2) // 2
        end
    end
    if not next(by) and next(want) then return anchors({}) end
    local out = {}
    for _, a in pairs(by) do out[#out + 1] = {z = a.z, n = a.n, x = a.x // a.n, y = a.y // a.n} end
    table.sort(out, function(a, b) return a.n > b.n end)
    return out
end
local function find_site(kind)
    local cit = dfhack.units.getCitizens(true)[1]
    local list = anchors(kind)
    if kind.soil then
        -- soil is a thin layer: try the levels around each anchor too
        local more = {}
        for i, A in ipairs(list) do
            if i > 2 then break end
            for dz = -2, 2 do more[#more + 1] = {z = A.z + dz, n = A.n, x = A.x, y = A.y} end
        end
        list = more
    end
    for i, A in ipairs(list) do
        if i > (kind.soil and 10 or 6) then break end
        local best, bd
        local R = kind.soil and 24 or 30
        for x = A.x - R, A.x + R do for y = A.y - R, A.y + R do
            if is_floor(x, y, A.z) and not dfhack.buildings.findAtTile(xyz2pos(x, y, A.z))
                and (not cit or dfhack.maps.canWalkBetween(cit.pos, xyz2pos(x, y, A.z))) then
                for _, d in ipairs(DIRS) do
                    -- straight off the corridor; soil rooms may sit at the end of a short tunnel
                    for t = 1, kind.soil and 10 or 1 do
                        local w = fits(x, y, A.z, d, kind.L, kind.S, kind.soil, t)
                        if w then
                            local dist = (x - A.x) ^ 2 + (y - A.y) ^ 2 + t * t * 4
                            if not bd or dist < bd then best, bd = w, dist end
                            break
                        end
                        if not safe(x + d[1] * t, y + d[2] * t, A.z) then break end
                    end
                end
            end
        end end
        if best then return best end
    end
end

-- the furniture cells of a room: {x, y, key}
local function furniture(kind, w)
    local out = {}
    local x1, y1, x2, y2 = table.unpack(w.box)
    if kind.furn then
        for x = x1, x2 do for y = y1, y2 do
            local u, v = uv(w, x, y)
            local k = kind.furn(u, v, w.L, w.S)
            if k then out[#out + 1] = {x, y, k} end
        end end
    elseif kind.workshop then
        out[#out + 1] = {x1 + 1, y1 + 1, kind.workshop .. '(3x3)', big = true}
    end
    return out
end
local function write_bp(kind, w)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local gx1, gy1 = math.min(x1, w.door[1]), math.min(y1, w.door[2])
    local gx2, gy2 = math.max(x2, w.door[1]), math.max(y2, w.door[2])
    local cells = {}
    for _, c in ipairs(furniture(kind, w)) do cells[c[1] * 10000 + c[2]] = c[3] end
    local function grid(fn)
        local rows = {}
        for y = gy1, gy2 do
            local r = {}
            for x = gx1, gx2 do r[#r + 1] = fn(x, y) or '' end
            rows[#rows + 1] = table.concat(r, ',')
        end
        return table.concat(rows, '\n')
    end
    for _, c in ipairs(w.tunnel or {}) do
        gx1, gy1, gx2, gy2 = math.min(gx1, c[1]), math.min(gy1, c[2]), math.max(gx2, c[1]), math.max(gy2, c[2])
    end
    local tun = {}
    for _, c in ipairs(w.tunnel or {}) do tun[c[1] * 10000 + c[2]] = true end
    local inroom = function(x, y) return (x >= x1 and x <= x2 and y >= y1 and y <= y2) or tun[x * 10000 + y] end
    local body = '#dig label(dig) start(1;1)\n' .. grid(function(x, y) if (x == w.door[1] and y == w.door[2]) or inroom(x, y) then return 'd' end end)
        .. '\n#build label(build) start(1;1)\n' .. grid(function(x, y)
            if x == w.door[1] and y == w.door[2] then return 'd' end
            return cells[x * 10000 + y] end)
    if kind.zone then
        body = body .. '\n#zone label(zone) start(1;1)\n' .. grid(function(x, y)
            if x == x1 and y == y1 then return ('%s(%dx%d)'):format(kind.zone, x2 - x1 + 1, y2 - y1 + 1) end end)
    elseif kind.zone_each then
        body = body .. '\n#zone label(zone) start(1;1)\n' .. grid(function(x, y) if cells[x * 10000 + y] then return kind.zone_each end end)
    end
    if kind.pile then
        body = body .. '\n#place label(place) start(1;1)\n' .. grid(function(x, y)
            if x == x1 and y == y1 then return ('%s(%dx%d)'):format(kind.pile, x2 - x1 + 1, y2 - y1 + 1) end end)
    end
    local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
    dfhack.filesystem.mkdir_recursive(dir)
    local f = io.open(dir .. '/room.csv', 'w')
    f:write(body .. '\n')
    f:close()
    return gx1, gy1
end
local function qf(kind, w, label, dry)
    local gx, gy = write_bp(kind, w)
    local args = {'quickfort', 'run', BP, '-n', '/' .. label, '-c', ('%d,%d,%d'):format(gx, gy, w.z)}
    if dry then args[#args + 1] = '--dry-run' end
    return dfhack.run_command_silent(table.unpack(args))
end
-- the room's own buildings
local function at_box(w, want)
    local x1, y1, x2, y2 = table.unpack(w.box)
    for _, b in ipairs(df.global.world.buildings.all) do
        if b.z == w.z and want(b) and b.x1 >= x1 and b.x2 <= x2 and b.y1 >= y1 and b.y2 <= y2 then return b end
    end
end
-- instruments only, no bins/barrels/wheelbarrows (the user's rule for a
-- first pile and for this one)
local function setup_instrument_pile(w)
    local pile = at_box(w, function(b) return b:getType() == df.building_type.Stockpile end)
    if not pile then return false end
    dfhack.run_command_silent('stockpiles', 'import', 'cat_finished_goods', '-s', tostring(pile.id))
    dfhack.run_command_silent('stockpiles', 'import', 'cat_finished_goods', '-s', tostring(pile.id), '-m', 'disable', '-f', 'type/')
    dfhack.run_command_silent('stockpiles', 'import', 'cat_finished_goods', '-s', tostring(pile.id), '-m', 'enable', '-f', 'type/INSTRUMENT')
    pile.storage.max_bins, pile.storage.max_barrels, pile.storage.max_wheelbarrows = 0, 0, 0
    return true
end
-- make the room's zone part of the public tavern (as quickfort's own
-- location=tavern/label does for zones in one blueprint), on the game's tick
local function attach_to_tavern(w)
    local loc = public_tavern()
    local zone = at_box(w, function(b) return b:getType() == df.building_type.Civzone end)
    if not loc or not zone then return false end
    dfhack.timeout(1, 'ticks', function()
        local site = dfhack.world.getCurrentSite()
        local have = false
        for _, id in ipairs(loc.contents.building_ids) do if id == zone.id then have = true end end
        if not have then loc.contents.building_ids:insert('#', zone.id) end
        zone.site_id = site.id
        zone.location_id = loc.id
        zone:uncategorize()
        zone:categorize(true)
    end)
    return true
end

local function dug(w)
    local x1, y1, x2, y2 = table.unpack(w.box)
    local n, of = 0, 0
    for x = x1, x2 do for y = y1, y2 do of = of + 1 if is_floor(x, y, w.z) then n = n + 1 end end end
    return n, of
end
local function furnished(kind, w)
    local n, of = 0, 0
    for _, c in ipairs(furniture(kind, w)) do
        of = of + 1
        local b = dfhack.buildings.findAtTile(xyz2pos(c[1] + (c.big and 1 or 0), c[2] + (c.big and 1 or 0), w.z))
        if b and b:getType() ~= df.building_type.Civzone and b:getBuildStage() >= b:getMaxBuildStage() then n = n + 1 end
    end
    return n, of
end

local function step(s)
    local w = s.current
    if not w then
        local job = table.remove(s.queue, 1)
        if not job then return end
        local kind = K[job]
        if not kind then s.last = 'unknown room kind ' .. tostring(job) return end
        if kind.attach and not public_tavern() then
            table.insert(s.queue, 1, job)
            s.last = ('the %s waits for the fort to open a public tavern'):format(kind.label:lower())
            return
        end
        w = find_site(kind)
        if not w then s.last = ('no solid dry rock beside a corridor for a %s'):format(kind.label:lower()) return end
        w.kind, w.phase = job, 'dig'
        w.key = ('build-%d'):format((s.n or 0) + 1)
        s.n = (s.n or 0) + 1
        s.current = w
        qf(kind, w, 'dig')
        project('add', w.key, 'A New ' .. kind.label, w.box[1], w.box[2], w.z, w.box[3], w.box[4], w.z, true)
        s.last = ('digging a new %s at level %d'):format(kind.label:lower(), w.z)
        return
    end
    local kind = K[w.kind]
    if w.phase == 'dig' then
        local n, of = dug(w)
        s.last = ('digging the new %s: %d of %d'):format(kind.label:lower(), n, of)
        local tunnel_open = true
        for _, c in ipairs(w.tunnel or {}) do if not is_floor(c[1], c[2], w.z) then tunnel_open = false end end
        if n == of and tunnel_open and is_floor(w.door[1], w.door[2], w.z) then
            w.phase = 'build'
            qf(kind, w, 'build')
            if kind.pile then qf(kind, w, 'place') end
        else
            keep_digging(w)
        end
    elseif w.phase == 'build' then
        local n, of = furnished(kind, w)
        s.last = ('furnishing the new %s: %d of %d'):format(kind.label:lower(), n, of)
        w.waits = (w.waits or 0) + 1
        if kind.instruments and not w.pile_set then w.pile_set = setup_instrument_pile(w) or nil end
        if w.waits % 20 == 0 then qf(kind, w, 'build') end   -- re-place anything cancelled
        if n >= of then w.phase = 'zone' end
    elseif w.phase == 'zone' then
        if kind.zone or kind.zone_each then qf(kind, w, 'zone') end
        if kind.attach then
            if not w.zoned then qf({zone = 'm'}, w, 'zone') w.zoned = true return end   -- a plain meeting zone first
            if not attach_to_tavern(w) then s.last = 'could not join the new hall to the public tavern' end
        end
        table.insert(s.built, {kind = w.kind, box = w.box, z = w.z})
        s.current = nil
        project('done', w.key)
        s.last = ('a new %s is ready at level %d'):format(kind.label:lower(), w.z)
    end
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(step, s)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
    if not s.current and #s.queue == 0 then repeatUtil.cancel(KEY) end
end

function status()
    local s = load()
    local q = {}
    for _, k in ipairs(s.queue) do q[#q + 1] = K[k] and K[k].label:lower() or k end
    return ('build: %s%s; %d rooms built on order'):format(s.last or 'nothing ordered',
        #q > 0 and ('; next: ' .. table.concat(q, ', ')) or '', #s.built)
end

if dfhack_flags.module then return end
local args = {...}
local cmd = args[1]
if cmd == 'kinds' then
    local out = {}
    for k, v in pairs(K) do out[#out + 1] = {key = k, label = v.label, help = v.help, group = v.group or 'Rooms'} end
    local G = {Rooms = 1, Storerooms = 2, Workshops = 3}
    table.sort(out, function(a, b) if a.group ~= b.group then return G[a.group] < G[b.group] end return a.label < b.label end)
    print(json.encode(out))
elseif cmd == 'new' then
    local kind = args[2]
    if not K[kind] then qerror('unknown kind; see dfai-build kinds') end
    local n = math.max(1, math.min(5, tonumber(args[3]) or 1))
    local s = load()
    for _ = 1, n do s.queue[#s.queue + 1] = kind end
    save(s)
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print(('build: %d %s ordered'):format(n, K[kind].label:lower()))
elseif cmd == 'find' then
    local kind = K[args[2] or '']
    if not kind then qerror('unknown kind') end
    local w = find_site(kind)
    if not w then print('no site') return end
    print(('site: room %d,%d..%d,%d level %d, door %d,%d'):format(w.box[1], w.box[2], w.box[3], w.box[4], w.z, w.door[1], w.door[2]))
    print((qf(kind, w, 'dig', true):gsub('%s+', ' ')))
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/blueprints/' .. BP) print(f:read('a')) f:close()
elseif cmd == 'cancel' then
    local s = load() s.queue = {} save(s) print('build: queue cleared')
elseif cmd == 'resume' then
    local s = load()
    if s.current or #s.queue > 0 then repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick) end
else
    print(status())
end
