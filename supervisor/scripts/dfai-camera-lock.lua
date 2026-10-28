-- dfai-camera-lock: hold the stream camera on one spot (user: "build a camera
-- lock into the overseer desk, also from the 6th of limestone to the 10th of
-- limestone, lock it on the trees as they are changing for autumn").
--
-- While a lock holds, spectate, the room tour, projects, guests and raid
-- send-offs all leave the camera alone; the tour's banner shows the lock's
-- title. A lock can let battles through (the battle camera takes over, then
-- the lock comes back) - the seasonal locks do, desk locks don't.
--
-- Scheduled locks come from dfhack-config/dfai-camera-lock.json, once a year
-- each:  {"schedule": [{"name": "autumn trees", "month": "Limestone", "from": 6,
--          "to": 10, "target": "trees", "title": "Autumn", "line": "The leaves are turning"}]}
-- Unlocking during a scheduled window ends it for that year.
--
--   dfai-camera-lock here [minutes]          lock on what the camera shows now (0/none = until unlocked)
--   dfai-camera-lock trees [minutes]         lock on the thickest stand of trees
--   dfai-camera-lock at x y z [minutes] [title...]
--   dfai-camera-lock off | status | start
--@module = true

local KEY = 'dfai-camera-lock'
local CFG_FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-camera-lock.json'
local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena', 'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}
local DEFAULT_CFG = {schedule = {{name = 'autumn trees', month = 'Limestone', from = 6, to = 10, target = 'trees',
    title = 'Autumn', line = 'The leaves are turning', yield = true}}}

L = rawget(_G, 'dfai_camlock') or {lock = nil, done = {}, running = false, gen = 0}
rawset(_G, 'dfai_camlock', L)

local function abs_tick() return df.global.cur_year * 403200 + df.global.cur_year_tick end
local function view() return ('%d,%d,%d'):format(df.global.window_x, df.global.window_y, df.global.window_z) end
local function ordinal(n) local s = ({'st', 'nd', 'rd'})[n % 10] if n % 100 >= 11 and n % 100 <= 13 or not s then s = 'th' end return n .. s end

local function save()
    dfhack.persistent.saveSiteData(KEY, {lock = L.lock, done = L.done})
end
local function load()
    local d = dfhack.persistent.getSiteData(KEY, {})
    L.lock, L.done = d.lock, d.done or {}
end
local function cfg()
    local f = io.open(CFG_FILE, 'r')
    if not f then
        local json = require('json')
        local w = io.open(CFG_FILE, 'w')
        if w then w:write(json.encode(DEFAULT_CFG, {pretty = true})) w:close() end
        return DEFAULT_CFG
    end
    local txt = f:read('*a') f:close()
    local ok, c = pcall(require('json').decode, txt)
    return ok and type(c) == 'table' and c or DEFAULT_CFG
end
local function month_index(m)
    if type(m) == 'number' then return m end
    for i, n in ipairs(MONTHS) do if n:lower() == tostring(m):lower() then return i - 1 end end
end

-- the thickest stand of trees: count trees per 24-tile cell from the plant
-- list (no map scan), then the level of that cell showing the most leaves
function find_trees()
    local cell, best, bn = {}, nil, 0
    local mx, my = dfhack.maps.getTileSize()
    for _, p in ipairs(df.global.world.plants.all) do
        if p.tree_info then
            local f = dfhack.maps.getTileFlags(p.pos)
            if f and not f.subterranean and not f.hidden then -- a surface tree (its own canopy keeps "outside" off)
                local k = (p.pos.x // 24) * 1000 + (p.pos.y // 24)
                local c = cell[k] or {n = 0, x = 0, y = 0, z = {}}
                c.n, c.x, c.y = c.n + 1, c.x + p.pos.x, c.y + p.pos.y
                c.z[p.pos.z] = (c.z[p.pos.z] or 0) + 1
                cell[k] = c
                local d = math.abs(p.pos.x - mx / 2) + math.abs(p.pos.y - my / 2)
                local score = c.n - d / 40
                if score > bn then best, bn = c, score end
            end
        end
    end
    if not best then return nil end
    local x, y = best.x // best.n, best.y // best.n
    local gz, gn = nil, 0
    for z, n in pairs(best.z) do if n > gn then gz, gn = z, n end end
    -- the level with the most leaves and branches in a screen-sized box
    local LEAF = {[df.tiletype_shape.TWIG] = true, [df.tiletype_shape.BRANCH] = true}
    local bz, bl = gz, -1
    for z = gz, gz + 12 do
        local n = 0
        for dx = -20, 20, 2 do for dy = -12, 12, 2 do
            local tt = dfhack.maps.getTileType(x + dx, y + dy, z)
            if tt then
                local a = df.tiletype.attrs[tt]
                if a.material == df.tiletype_material.TREE and LEAF[a.shape] then n = n + 1 end
            end
        end end
        if n > bl then bz, bl = z, n end
    end
    return {x = x, y = y, z = bz, trees = best.n}
end

local function tour() return rawget(_G, 'dfai_tour') end

local function apply(lk)
    -- take the camera: spectate off, nobody followed, the view on the spot
    dfhack.run_command_silent('disable', 'spectate')
    df.global.plotinfo.follow_unit = -1
    if lk.view ~= view() then
        if lk.wx then
            df.global.window_x, df.global.window_y, df.global.window_z = lk.wx, lk.wy, lk.z
        else
            dfhack.gui.revealInDwarfmodeMap(xyz2pos(lk.x, lk.y, lk.z), true, true)
            df.global.window_z = lk.z
        end
        lk.view = view()
    end
    local t = tour()
    if t then
        if not (t.current and t.current.lock) then
            t.guest, t.threat, t.project = nil, nil, nil
        end
        t.current = {name = lk.title, short = lk.line or '', pos = xyz2pos(lk.x, lk.y, lk.z), secs = 1e9, lock = true}
        t.view, t.last_switch = view(), os.time()
    end
end

function unlock(why)
    if not L.lock then return false end
    local was = L.lock
    if was.source and was.source:find('^schedule:') then L.done[was.source] = true end
    L.lock = nil
    save()
    local t = tour()
    if t and t.current and t.current.lock then t.current = nil end
    if t then t.last_switch, t.season = os.time(), df.global.cur_season end -- (no second leaves shot)
    dfhack.run_command_silent('enable', 'spectate')
    L.last = ('unlocked (%s): %s'):format(why or 'by order', was.title or '?')
    return true
end

function lock(lk)
    lk.view = nil
    L.lock = lk
    save()
    if dfhack.gui.matchFocusString('dwarfmode/Default') then apply(lk) end
    L.last = 'locked: ' .. (lk.title or '?')
end

local function schedule_check()
    local yt = df.global.cur_year_tick
    local month, day = yt // 33600, (yt % 33600) // 1200 + 1
    for _, s in ipairs(cfg().schedule or {}) do
        local m = month_index(s.month)
        local src = ('schedule:%s:%d'):format(s.name or '?', df.global.cur_year)
        if m == month and day >= (s.from or 1) and day <= (s.to or 28) and not L.done[src]
            and not (L.lock and L.lock.source == src) then
            local pos = s.target == 'trees' and find_trees() or (s.x and {x = s.x, y = s.y, z = s.z})
            L.done[src] = true -- once a year, even if no spot was found
            save()
            if pos and not (L.lock and not L.lock.source) then -- a desk lock wins
                local untilt = df.global.cur_year * 403200 + m * 33600 + (s.to or 28) * 1200
                lock({x = pos.x, y = pos.y, z = pos.z, title = s.title or s.name, source = src, yield = s.yield ~= false,
                    line = (s.line or '') .. (' | %s to %s %s'):format(ordinal(s.from or 1), ordinal(s.to or 28), MONTHS[m + 1]),
                    until_tick = untilt})
            end
        end
    end
end

local function step()
    if not dfhack.isMapLoaded() then return end
    schedule_check()
    local lk = L.lock
    if not lk then return end
    if (lk.until_tick and abs_tick() >= lk.until_tick) or (lk.until_wall and os.time() >= lk.until_wall) then
        unlock('time is up')
        return
    end
    local t = tour()
    if lk.yield and t and t.threat then return end   -- the battle camera has it
    if not dfhack.gui.matchFocusString('dwarfmode/Default') then return end
    local spect = false
    local ok, sp = pcall(require, 'plugins.spectate')
    if ok and sp and sp.isEnabled then spect = sp.isEnabled() end
    if spect or df.global.plotinfo.follow_unit ~= -1 or lk.view ~= view() or not (t and t.current and t.current.lock) then
        apply(lk)
    end
end

local function loop(gen)
    if not L.running or gen ~= L.gen then return end
    dfhack.timeout(30, 'frames', function() loop(gen) end)
    local ok, err = pcall(step)
    if not ok then L.err = tostring(err) end
end

function locked() return L.lock end

function status()
    local s
    local lk = L.lock
    if lk then
        local left = ''
        if lk.until_tick then left = (' until the %s'):format(((lk.until_tick % 403200) % 33600) // 1200 > 0 and
            (ordinal(((lk.until_tick % 403200) % 33600) // 1200) .. ' of ' .. MONTHS[(lk.until_tick % 403200) // 33600 + 1]) or 'end of the window')
        elseif lk.until_wall then left = (' for %d more min'):format(math.max(0, (lk.until_wall - os.time() + 59) // 60))
        else left = ' until unlocked' end
        s = ('LOCKED on %s (%d,%d,%d)%s%s'):format(lk.title or '?', lk.x, lk.y, lk.z, left, lk.yield and ', battles break in' or '')
    else
        s = 'unlocked'
    end
    local nxt = {}
    for _, x in ipairs(cfg().schedule or {}) do
        nxt[#nxt + 1] = ('%s %s-%s %s%s'):format(x.name or '?', x.from or 1, x.to or 28, x.month or '?',
            L.done[('schedule:%s:%d'):format(x.name or '?', df.global.cur_year)] and ' (done this year)' or '')
    end
    if #nxt > 0 then s = s .. '; yearly: ' .. table.concat(nxt, ', ') end
    if L.err then s = s .. '; error: ' .. L.err end
    return s
end

if dfhack_flags.module then return end

local args = {...}
local cmd = args[1] or 'status'
local function minutes(i)
    local n = tonumber(args[i])
    if n and n > 0 then return os.time() + math.floor(math.min(n, 24 * 60)) * 60 end
end
if cmd == 'start' then
    load()
    L.running, L.gen = true, (L.gen or 0) + 1
    loop(L.gen)
    print('camera lock: watching (' .. status() .. ')')
elseif cmd == 'here' then
    local t = tour()
    local title = t and t.current and not t.current.lock and t.current.name or "The Overseer's View"
    local x, y, z = df.global.window_x, df.global.window_y, df.global.window_z
    dfhack.timeout(1, 'ticks', function()
        lock({wx = x, wy = y, x = x, y = y, z = z, title = title, line = 'Camera held by the overseer', until_wall = minutes(2)})
    end)
    print('camera lock: holding the camera on ' .. title)
elseif cmd == 'trees' then
    local pos = find_trees()
    if not pos then print('camera lock: no trees found') return end
    dfhack.timeout(1, 'ticks', function()
        lock({x = pos.x, y = pos.y, z = pos.z, title = 'The Trees', line = ('A stand of %d trees'):format(pos.trees), until_wall = minutes(2)})
    end)
    print(('camera lock: on a stand of %d trees at %d,%d,%d'):format(pos.trees, pos.x, pos.y, pos.z))
elseif cmd == 'at' then
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not (x and y and z) then qerror('at x y z [minutes] [title]') end
    local title = #args >= 6 and table.concat(args, ' ', 6) or 'The Overseer\'s View'
    dfhack.timeout(1, 'ticks', function()
        lock({x = x, y = y, z = z, title = title, line = 'Camera held by the overseer', until_wall = minutes(5)})
    end)
    print('camera lock: holding the camera on ' .. title)
elseif cmd == 'off' then
    dfhack.timeout(1, 'ticks', function() unlock('by order') end)
    print('camera lock: ' .. (L.lock and 'released, back to the tour' or 'was not locked'))
else
    print('camera lock: ' .. status())
end
