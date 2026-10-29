-- dfai-archer-posts: when a great beast creeps into the fort's own space (a
-- stairwell, a tunnel) the marksdwarf squads take up a post a few tiles off,
-- with a clear line of fire, and shoot at it (user: "bonus points you could
-- station archers at those little exposed areas and take shots at it?").
--
-- Every ~5 game seconds: a forgotten beast / titan / megabeast / demon that's
-- seen, alive and in fort space (underground, not cavern - see
-- dfai-room-tour close_to_fort) or near citizens. For each one, the ranged
-- squads at home (half or more of the members carry a bow or crossbow) get a
-- move order to a post 5-12 tiles from it on its level: open floor, a clear
-- straight line to the beast, reachable by the squad, and not next to it. The
-- squad goes on its Ready routine (full gear). Stationed marksdwarves fire at
-- what they can see. The post moves when the beast moves; when the beast dies
-- or goes back down, the orders are dropped.
--   dfai-archer-posts start | stop | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-archer-posts'
local TAG = -7778   -- order.year marks our move orders
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'
local function notify(msg) local f = io.open(NOTIFY, 'a') if f then f:write(msg .. '\n') f:close() end end

P = rawget(_G, 'dfai_archers') or {posts = {}, last = 'watching', on = false}
rawset(_G, 'dfai_archers', P)

local function great_beast(u)
    return dfhack.units.isForgottenBeast(u) or dfhack.units.isMegabeast(u) or dfhack.units.isSemiMegabeast(u)
        or dfhack.units.isTitan(u) or dfhack.units.isDemon(u)
end
local function shape(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape
end
local OPEN = {[df.tiletype_shape.FLOOR] = true, [df.tiletype_shape.RAMP] = true, [df.tiletype_shape.STAIR_UP] = true,
    [df.tiletype_shape.STAIR_DOWN] = true, [df.tiletype_shape.STAIR_UPDOWN] = true, [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.PEBBLES] = true, [df.tiletype_shape.SHRUB] = true, [df.tiletype_shape.SAPLING] = true,
    [df.tiletype_shape.RAMP_TOP] = true, [df.tiletype_shape.EMPTY] = true}
local STAND = {[df.tiletype_shape.FLOOR] = true, [df.tiletype_shape.PEBBLES] = true, [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.STAIR_UP] = true, [df.tiletype_shape.STAIR_DOWN] = true, [df.tiletype_shape.STAIR_UPDOWN] = true}
local function blocked_by_building(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    local o = b and b.occupancy[x % 16][y % 16]
    if not o then return true end
    -- walls, closed doors, hatches, statues and the like stop bolts
    return o.building == df.tile_building_occ.Impassable or o.building == df.tile_building_occ.Obstacle
end
local function clear_line(x0, y0, x1, y1, z)
    local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
    local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
    local err, x, y = dx - dy, x0, y0
    while not (x == x1 and y == y1) do
        local e2 = 2 * err
        if e2 > -dy then err = err - dy x = x + sx end
        if e2 < dx then err = err + dx y = y + sy end
        if x == x1 and y == y1 then break end
        if not OPEN[shape(x, y, z)] or blocked_by_building(x, y, z) then return false end
    end
    return true
end

-- ranged squads at home: half or more of the members on the map carry a bow/crossbow
local function ranged_squads()
    local out = {}
    for _, sq in ipairs(df.global.world.squads.all) do
        if sq.entity_id == df.global.plotinfo.group_id then
            local members, ranged = {}, 0
            for _, pos in ipairs(sq.positions) do
                local hf = pos.occupant ~= -1 and df.historical_figure.find(pos.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.inactive then
                    members[#members + 1] = u
                    for _, inv in ipairs(u.inventory) do
                        local it = inv.item
                        if df.item_weaponst:is_instance(it) and it.subtype and it.subtype.ranged_ammo ~= '' then ranged = ranged + 1 break end
                    end
                end
            end
            if #members > 0 and ranged * 2 >= #members then out[#out + 1] = {sq = sq, members = members} end
        end
    end
    return out
end

local function routine(name)
    for i, r in ipairs(df.global.plotinfo.alerts.routines) do if r.name == name then return i end end
end
local function drop_ours(sq)
    for i = #sq.orders - 1, 0, -1 do
        local o = sq.orders[i]
        if df.squad_order_movest:is_instance(o) and o.year == TAG then sq.orders:erase(i) end
    end
end

-- a post 5-12 tiles from the beast on its level, clear line, reachable, near the squad
local function find_post(b, from)
    local best, bs
    local bx, by, bz = b.pos.x, b.pos.y, b.pos.z
    for x = bx - 12, bx + 12 do for y = by - 12, by + 12 do
        local d = math.max(math.abs(x - bx), math.abs(y - by))
        if d >= 5 and STAND[shape(x, y, bz)] and not blocked_by_building(x, y, bz) then
            local f = dfhack.maps.getTileFlags(x, y, bz)
            if f and not f.hidden and f.flow_size == 0 and dfhack.maps.canWalkBetween(from, xyz2pos(x, y, bz)) and clear_line(x, y, bx, by, bz) then
                -- near 8 tiles, and close to where the archers are now (shortest walk, least chance they path past it)
                local sc = math.abs(d - 8) * 4 + (math.abs(x - from.x) + math.abs(y - from.y) + 10 * math.abs(bz - from.z)) / 10
                if not best or sc < bs then best, bs = {x, y, bz}, sc end
            end
        end
    end end
    return best
end

find_post_check = function(x, y, z, from) return find_post({pos = xyz2pos(x, y, z)}, from) end
ranged_squads_check = ranged_squads
local function close(u, cits)
    local ok, m = pcall(reqscript, 'dfai-room-tour')
    if ok and m.close_to_fort then return m.close_to_fort(u, cits) end
    return false
end

local function step()
    if not dfhack.isMapLoaded() then return end
    local cits = {}
    for _, c in ipairs(dfhack.units.getCitizens(true)) do cits[#cits + 1] = c.pos end
    local beasts = {}
    for _, u in ipairs(df.global.world.units.active) do
        if great_beast(u) and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not u.flags1.caged
            and not dfhack.maps.getTileFlags(u.pos).hidden and close(u, cits) then beasts[#beasts + 1] = u end
    end
    local squads = ranged_squads()
    if #beasts == 0 then
        if next(P.posts) then
            for _, h in ipairs(squads) do drop_ours(h.sq) end
            for sid in pairs(P.posts) do local sq = df.squad.find(sid) if sq then drop_ours(sq) end end
            P.posts = {}
            P.last = 'stood down: no beast near the fort'
            dfhack.gui.showAnnouncement('The archers stand down.', COLOR_LIGHTCYAN, false)
        end
        return
    end
    local b = beasts[1]
    local name = dfhack.df2utf(dfhack.units.getReadableName(b)):gsub(',.*$', '')
    local posted = 0
    for i, h in ipairs(squads) do
        local cur = P.posts[h.sq.id]
        local moved = not cur or cur.beast ~= b.id or math.max(math.abs(cur.bx - b.pos.x), math.abs(cur.by - b.pos.y)) > 5 or cur.bz ~= b.pos.z
        if moved then
            local post = find_post(b, h.members[1].pos)
            if post then
                -- spread squads a little: the second squad a few tiles over
                drop_ours(h.sq)
                local o = df.squad_order_movest:new()
                o.pos = xyz2pos(post[1], post[2], post[3])
                o.point_id = -1
                o.year, o.year_tick = TAG, df.global.cur_year_tick
                h.sq.orders:insert(0, o)
                local ready = routine('Ready')
                if ready then h.sq.cur_routine_idx = ready end
                local first = not next(P.posts)
                P.posts[h.sq.id] = {beast = b.id, bx = b.pos.x, by = b.pos.y, bz = b.pos.z, post = post}
                posted = posted + 1
                if first then
                    local msg = ('%s is in the fort! The archers take up a post %d tiles off and open fire.'):format(name,
                        math.max(math.abs(post[1] - b.pos.x), math.abs(post[2] - b.pos.y)))
                    dfhack.gui.showAnnouncement(dfhack.utf2df(msg), COLOR_LIGHTRED, true)
                    notify('**Archers posted:** ' .. msg)
                end
            end
        else
            posted = posted + 1
        end
    end
    P.last = ('%s in the fort at %d,%d,%d: %d of %d ranged squad%s posted'):format(name, b.pos.x, b.pos.y, b.pos.z, posted, #squads, #squads == 1 and '' or 's')
end

function status() return 'archer posts: ' .. (P.on and 'watching' or 'off') .. ' - ' .. tostring(P.last) end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    P.on = true
    repeatUtil.scheduleEvery(KEY, 100, 'ticks', function() local ok, e = pcall(step) if not ok then P.last = 'error: ' .. tostring(e) end end)
    print('archer posts: watching for beasts in the fort')
elseif cmd == 'stop' then
    P.on = false
    repeatUtil.cancel(KEY)
    dfhack.timeout(1, 'ticks', function()
        for sid in pairs(P.posts) do local sq = df.squad.find(sid) if sq then drop_ours(sq) end end
        P.posts = {}
    end)
    print('archer posts: stopped (orders dropped)')
elseif cmd == 'test' then
    -- dry run: the ranged squads and the post each would get for the nearest great beast
    local cits = {}
    for _, c in ipairs(dfhack.units.getCitizens(true)) do cits[#cits + 1] = c.pos end
    local sq = ranged_squads()
    print(('%d ranged squads'):format(#sq))
    for _, u in ipairs(df.global.world.units.active) do
        if great_beast(u) and not dfhack.units.isDead(u) and not dfhack.maps.getTileFlags(u.pos).hidden then
            print(dfhack.df2console(dfhack.units.getReadableName(u)), u.pos.x, u.pos.y, u.pos.z, 'close', close(u, cits))
            if sq[1] then local p = find_post(u, sq[1].members[1].pos) print('  post', p and table.concat(p, ',') or 'none (unreachable)') end
        end
    end
else
    print(status())
end
