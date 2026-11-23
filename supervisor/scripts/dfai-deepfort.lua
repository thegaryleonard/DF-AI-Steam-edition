-- dfai-deepfort: a second, deeper fort just above the first cavern.
--
-- User (2026-11-23): "build another deeper backup fort down at the caverns
-- level so they are closer to water and have places to go". The cavern lake
-- is water that never runs dry, and the main fort's well can be 50 levels
-- above it; injured dwarves die for want of water carried to their beds.
--
--   main fort  ...
--   main stair  S
--   deep fort   S===========   a corridor off the main stair through solid
--               |  |  |  |     rock, 3 levels above the cavern roof, with a
--             dining dorms hospital food   (dfai-build rooms) and a well
--   (rock x2)                  (dfai-wellshaft: a short shaft down into the
--   cavern air  ~ ~ ~ ~        cavern air over the lake)
--   lake        ~ ~ ~ ~
--
-- Once the fort has DEEP_POP citizens and its main stair reaches that level
-- (df-ai's mine shaft usually does). The level is found by a scan that reads
-- one level per tick (no whole-map scan in one go). Nothing is dug next to a
-- cavern: every corridor tile has rock all round, and dfai-build's rooms
-- only go into sealed rock.
--   dfai-deepfort start | status | find (dry run) | now
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-deepfort'
local DEEP_POP = 60
local ABOVE = 3          -- levels of rock between the halls and the cavern roof
local CORRIDOR = 24      -- tiles; rooms go on both sides
local ROOMS = {'dining', 'dormitory', 'dormitory', 'hospital', 'stockpile-f'}

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt]
end
local Sh = df.tiletype_shape

-- solid natural rock with rock (or our own floor) all round, nothing open
-- above or below, no water, not a cavern
local function sealed_rock(x, y, z)
    if not dfhack.maps.isValidTilePos(x, y, z) then return false end
    local a = attrs(x, y, z)
    if not a or a.shape ~= Sh.WALL or a.material == df.tiletype_material.CONSTRUCTION
        or a.material == df.tiletype_material.TREE or a.material == df.tiletype_material.ROOT then return false end
    for dz = -1, 1 do for dx = -1, 1 do for dy = -1, 1 do
        local f = dfhack.maps.getTileFlags(x + dx, y + dy, z + dz)
        if not f or f.flow_size > 0 or f.outside or f.feature_local or f.feature_global or f.water_table then return false end
        local b = attrs(x + dx, y + dy, z + dz)
        -- above and below: rock, or the stair the corridor starts from
        if dz ~= 0 and b and b.shape ~= Sh.WALL and b.shape ~= Sh.STAIR_UP and b.shape ~= Sh.STAIR_DOWN and b.shape ~= Sh.STAIR_UPDOWN then return false end
    end end end
    return true
end

-- a stair column x,y from zhi down to zlo: rock all the way, rock (or open
-- fort floor on the top level) all round, nothing wet or cavern next to it
local function column_ok(x, y, zlo, zhi)
    for z = zlo, zhi do
        local a = attrs(x, y, z)
        if not a or a.shape ~= Sh.WALL or a.material == df.tiletype_material.CONSTRUCTION then return false end
        for dx = -1, 1 do for dy = -1, 1 do
            local f = dfhack.maps.getTileFlags(x + dx, y + dy, z)
            if not f or f.flow_size > 0 or f.outside or f.feature_local or f.feature_global or f.water_table then return false end
            if not (dx == 0 and dy == 0) then
                local b = attrs(x + dx, y + dy, z)
                if not b or b.shape ~= Sh.WALL then return false end
            end
        end end
    end
    -- and the level under the halls is rock too
    for dx = -1, 1 do for dy = -1, 1 do
        local f = dfhack.maps.getTileFlags(x + dx, y + dy, zlo - 1)
        if not f or f.feature_local or f.feature_global or f.flow_size > 0 then return false end
    end end
    return true
end

-- a tile inside a room df-ai has planned (corridors don't count: a stair in
-- a corridor is fine)
local function in_room(x, y, z)
    local ok, ai = pcall(require, 'plugins.df-ai')
    if not ok or not ai.planned_room_at then return false end
    local ok2, d = pcall(ai.planned_room_at, x, y, x, y, z)
    return ok2 and type(d) == 'string' and d ~= '' and not d:find('^corridor')
end

local function lowest_home()
    -- the lowest level with beds: the deep fort only goes well below it
    local lo
    for _, b in ipairs(df.global.world.buildings.other.BED or {}) do
        if not lo or b.z < lo then lo = b.z end
    end
    return lo
end

-- the level scan: from under the lowest bedroom down, the first level with
-- a big cavern; one level per tick
local scanning = false
local function scan_levels(done)
    local cit = dfhack.units.getCitizens(true)[1]
    local home = lowest_home()
    if not cit or not home then done(nil, 'no citizens or beds yet') return end
    local g = dfhack.maps.getWalkableGroup(cit.pos)
    local blocks = {}
    for _, b in ipairs(df.global.world.map.map_blocks) do
        local z = b.map_pos.z
        if z < home then blocks[z] = blocks[z] or {} table.insert(blocks[z], b) end
    end
    local z = home - 1
    local function level()
        if z < 1 then done(nil, 'no cavern under the fort') return end
        local cav = 0
        for _, b in ipairs(blocks[z] or {}) do
            for x = 0, 15 do for y = 0, 15 do
                local d = b.designation[x][y]
                if (d.feature_local or d.feature_global) and df.tiletype.attrs[b.tiletype[x][y]].shape ~= Sh.WALL then cav = cav + 1 end
            end end
        end
        if cav >= 200 then
            local tz = z + 1 + ABOVE
            -- the main stair (fort-walkable, not a cavern) on that level
            local stairs = {}
            for _, b in ipairs(blocks[tz] or {}) do
                for x = 0, 15 do for y = 0, 15 do
                    local d = b.designation[x][y]
                    if b.walkable[x][y] == g and g ~= 0 and not d.outside and not d.feature_local and not d.feature_global then
                        stairs[#stairs + 1] = {x = b.map_pos.x + x, y = b.map_pos.y + y}
                    end
                end end
            end
            if #stairs > 0 then done({z = tz, cavern = z, stairs = stairs}) return end
            -- no stair down there: the fort's lowest level above it, and a
            -- column of solid rock from there down to sink a stair in
            local top
            for zz = tz + 1, home do
                for _, b in ipairs(blocks[zz] or {}) do
                    for x = 0, 15 do for y = 0, 15 do
                        local d = b.designation[x][y]
                        if b.walkable[x][y] == g and g ~= 0 and not d.outside and not d.feature_local and not d.feature_global
                            and df.tiletype.attrs[b.tiletype[x][y]].shape == Sh.FLOOR then
                            top = top or {z = zz, tiles = {}}
                            table.insert(top.tiles, {x = b.map_pos.x + x, y = b.map_pos.y + y})
                        end
                    end end
                end
                if top then break end
            end
            if not top then done(nil, 'no fort level above the cavern to dig down from') return end
            -- candidates a few per tick (each checks a column of 30+ levels)
            local i = 1
            local function try()
                for _ = 1, 25 do
                    local t = top.tiles[i]
                    if not t then done(nil, ('no solid rock to sink a stair from level %d to %d'):format(top.z, tz)) return end
                    i = i + 1
                    if not dfhack.buildings.findAtTile(xyz2pos(t.x, t.y, top.z)) and not in_room(t.x, t.y, top.z)
                        and column_ok(t.x, t.y, tz, top.z - 1) then
                        done({z = tz, cavern = z, stairs = {{x = t.x, y = t.y}}, sink = {x = t.x, y = t.y, top = top.z}})
                        return
                    end
                end
                dfhack.timeout(1, 'ticks', try)
            end
            try()
            return
        end
        z = z - 1
        dfhack.timeout(1, 'ticks', level)
    end
    level()
end

-- the corridor: straight off a stair tile, the longest run of sealed rock
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function plan_corridor(site)
    local best
    for _, st in ipairs(site.stairs) do
        for _, d in ipairs(DIRS) do
            local n = 0
            while n < CORRIDOR and sealed_rock(st.x + d[1] * (n + 1), st.y + d[2] * (n + 1), site.z) do n = n + 1 end
            -- (sealed_rock wants rock all round; the stair tile itself is
            -- still rock on a sink site, which is fine)
            if n >= 12 and (not best or n > best.n) then best = {x = st.x, y = st.y, z = site.z, dx = d[1], dy = d[2], n = n} end
        end
    end
    return best
end

local function corridor_tiles(c)
    local t = {}
    for i = 1, c.n do t[#t + 1] = {c.x + c.dx * i, c.y + c.dy * i} end
    return t
end

local function dug(c)
    local n = 0
    for _, p in ipairs(corridor_tiles(c)) do
        local a = attrs(p[1], p[2], c.z)
        if a and a.shape == Sh.FLOOR then n = n + 1 end
    end
    return n
end

local function designate(c)
    for _, p in ipairs(corridor_tiles(c)) do
        local a = attrs(p[1], p[2], c.z)
        if a and a.shape == Sh.WALL then
            local f, occ = dfhack.maps.getTileFlags(p[1], p[2], c.z)
            if f.dig == df.tile_dig_designation.No then
                f.dig = df.tile_dig_designation.Default
                dfhack.maps.getTileBlock(p[1], p[2], c.z).flags.designated = true
            end
        end
    end
end

local function step(s)
    local pop = #dfhack.units.getCitizens(true)
    if not s.site then
        if pop < DEEP_POP then s.last = ('waits for %d citizens (%d now)'):format(DEEP_POP, pop) return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if s.looked and now - s.looked < 33600 then return end   -- once a game month
        s.looked = now
        if scanning then return end
        scanning = true
        s.last = 'looking for the first cavern under the fort'
        scan_levels(function(site, why)
            scanning = false
            local s2 = load()
            if not site or why then s2.last = 'no deep fort yet: ' .. tostring(why) save(s2) return end
            local c = plan_corridor(site)
            if not c then s2.last = ('no deep fort yet: no sealed rock off the stair at level %d'):format(site.z) save(s2) return end
            s2.site = {z = site.z, cavern = site.cavern, corridor = c, sink = site.sink, phase = site.sink and 'stair' or 'dig'}
            s2.last = ('a deep fort is planned at level %d, %d levels above the cavern at %d'):format(site.z, ABOVE, site.cavern)
            dfhack.gui.showAnnouncement(('The miners will dig a deep fort at level %d, near the cavern lake.'):format(site.z), COLOR_LIGHTCYAN, true)
            pcall(function() reqscript('dfai-projects').add('deepfort', 'The Deep Fort', c.x, c.y, c.z, c.x + c.dx * c.n, c.y + c.dy * c.n, c.z, true) end)
            save(s2)
        end)
        return
    end
    local site, c = s.site, s.site.corridor
    if site.phase == 'stair' then
        -- dig the stair down from the fort's lowest level, top first (each
        -- level is reached from the one above); the top tile is open floor,
        -- so it gets a down stair built, not dug
        local k = site.sink
        local DD, CT = df.tile_dig_designation, df.construction_type
        local left = 0
        for z = k.top, c.z, -1 do
            local a = attrs(k.x, k.y, z)
            local want = (z == k.top and Sh.STAIR_DOWN) or (z == c.z and Sh.STAIR_UP) or Sh.STAIR_UPDOWN
            if a and a.shape ~= want then
                left = left + 1
                if z == k.top then
                    if not dfhack.buildings.findAtTile(xyz2pos(k.x, k.y, z)) then
                        pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = CT.DownStair, pos = xyz2pos(k.x, k.y, z)})
                    end
                elseif a.shape == Sh.WALL then
                    local f = dfhack.maps.getTileFlags(k.x, k.y, z)
                    local how = (z == c.z) and DD.UpStair or DD.UpDownStair
                    if f.dig ~= how then f.dig = how dfhack.maps.getTileBlock(k.x, k.y, z).flags.designated = true end
                end
            end
        end
        if left > 0 then
            s.last = ('digging the stair down to the deep fort: %d of %d levels to go'):format(left, k.top - c.z + 1)
            return
        end
        site.phase = 'dig'
    end
    if site.phase == 'dig' then
        local n = dug(c)
        if n < c.n then
            designate(c)
            s.last = ('digging the deep fort corridor at level %d: %d of %d'):format(c.z, n, c.n)
            return
        end
        site.phase = 'rooms'
        -- the rooms, around the corridor's middle; then a well by it
        local mx, my = c.x + c.dx * (c.n // 2), c.y + c.dy * (c.n // 2)
        for _, k in ipairs(ROOMS) do dfhack.run_command_silent('dfai-build', 'new', k, '1', tostring(mx), tostring(my), tostring(c.z)) end
        pcall(function() reqscript('dfai-wellshaft').request_at(mx, my, c.z) end)
        s.last = ('deep fort corridor dug at level %d: rooms and a well ordered'):format(c.z)
        return
    end
    if site.phase == 'rooms' then
        local okb, b = pcall(reqscript, 'dfai-build')
        local okw, w = pcall(reqscript, 'dfai-wellshaft')
        s.last = ('deep fort at level %d: %s; %s'):format(c.z, okb and b.status() or '?', okw and w.status() or '?')
    end
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, err = pcall(step, s)
    if not ok then s.last = 'error: ' .. tostring(err) end
    save(s)
end

function status()
    local s = load()
    return 'deep fort: ' .. (s.last or 'idle') .. (s.find and ('; dry run: ' .. s.find) or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    print('deep fort: watching')
elseif cmd == 'now' then
    local s = load() s.looked = nil save(s)
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print('deep fort: checking on the next tick')
elseif cmd == 'find' then
    scan_levels(function(site, why)
        if not site then local s = load() s.find = tostring(why) save(s) return end
        local c = (not why) and plan_corridor(site)
        local msg = ('cavern at level %d, halls at level %d, %d stair tiles there; corridor %s'):format(site.cavern, site.z, #site.stairs,
            c and ('from %d,%d heading %d,%d, %d tiles'):format(c.x, c.y, c.dx, c.dy, c.n) or (why or 'none in sealed rock'))
        local s = load() s.find = msg save(s)   -- the scan ends after this command returns
    end)
else
    print(status())
end
