-- dfai-deep-dig: a mature fort keeps digging down (user: "digging down in
-- general is a thing dwarves love").
--
--   dfai-deep-dig start|stop|status|now
--
-- Once the fort is mature (MATURE_POP+ citizens, at least one cavern outpost),
-- it sinks a staircase shaft from the deepest cavern outpost df-ai dug, BATCH
-- levels at a time: the next batch is designated when the last one is dug.
-- It never breaks into liquid: when magma, water, an aquifer or open space
-- shows up within SAFE levels below (or beside) the shaft, it stops, and the
-- miners carve "The Deep Hall" at the bottom. Then it starts a side gallery
-- every so often (exploration: ore, gems) from the hall.
-- Runs on a game-tick timer (never mid-save). State: dfhack.persistent;
-- dfhack-config/dfai-deep.json for the Herald and the stream camera.

local json = require('json')
local repeatUtil = require('repeat-util')

local KEY = 'dfai-deep-dig'
local MATURE_POP = 60
local SAFE = 3          -- levels kept between the shaft bottom and any liquid/void
local HALL_R = 2        -- the hall is (2R+1)^2
local STALL_DAYS = 10   -- re-designate a level nobody dug
local BATCH = 10        -- levels designated at a time (user: "dig 10 levels at a time")

local function shape(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape
end

local function is_wall(x, y, z)
    local s = shape(x, y, z)
    return s == df.tiletype_shape.WALL
end

local function is_stair(x, y, z)
    local s = shape(x, y, z)
    return s == df.tiletype_shape.STAIR_UP or s == df.tiletype_shape.STAIR_DOWN or s == df.tiletype_shape.STAIR_UPDOWN
end

-- liquid, aquifer or open space at (x+-1, y+-1, z)?
local function danger_at(x, y, z)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local f = dfhack.maps.getTileFlags(x + dx, y + dy, z)
            if not f then return 'map edge' end
            if f.flow_size > 0 then return f.liquid_type and 'magma' or 'water' end
            if f.water_table then return 'aquifer' end
            local s = shape(x + dx, y + dy, z)
            if s == df.tiletype_shape.EMPTY then return 'open space' end
        end
    end
end

-- dig priority 1 (as quickfort sets it): the shaft is far below the fort, and
-- at the default priority the miners always found a nearer dig job first (the
-- last level waited for hours)
local function set_priority(b, x, y, p)
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = p * 1000
end

local function designate(x, y, z, kind)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    if not f or not b then return false end
    f.dig = kind
    set_priority(b, x, y, 1)
    b.flags.designated = true
    return true
end

local function citizens() return #dfhack.units.getCitizens(true) end

local function load_state()
    local s = dfhack.persistent.getSiteData(KEY, {})
    s.log = s.log or {}
    return s
end

local function save_state(s)
    dfhack.persistent.saveSiteData(KEY, s)
    local site = dfhack.world.getCurrentSite()
    local f = io.open(dfhack.getDFPath() .. '/dfhack-config/dfai-deep.json', 'w')
    if f then
        f:write(json.encode({site_id = site and site.id or -1, year = df.global.cur_year, x = s.x, y = s.y, top = s.top,
            bottom = s.cur, levels = s.top and s.cur and (s.top - s.cur) or 0, status = s.status or 'waiting',
            stop_reason = s.stop_reason, galleries = s.galleries or 0, log = s.log}))
        f:close()
    end
end

local function note(s, text)
    table.insert(s.log, {year = df.global.cur_year, tick = df.global.cur_year_tick, text = text})
    while #s.log > 12 do table.remove(s.log, 1) end
end

-- the deepest cavern outpost in df-ai's plan (read once)
local function find_start()
    local dir = df.global.world.cur_savegame.save_dir
    local path = dfhack.getSavePath and dfhack.getSavePath() or nil
    local ok, plan = pcall(json.decode_file, (path or (dfhack.getDFPath() .. '/save/' .. dir)) .. '/df-ai-plan.dat')
    if not ok or not plan then
        ok, plan = pcall(json.decode_file, os.getenv('APPDATA') .. '/Bay 12 Games/Dwarf Fortress/save/' .. dir .. '/df-ai-plan.dat')
    end
    if not ok or not plan then return nil, 'no plan file' end
    local best
    for _, r in ipairs(plan.r or {}) do
        if r.type == 'outpost' and r.outpost_type == 'cavern' and r.status == 'finished' then
            if not best or r.min[3] < best.min[3] then best = r end
        end
    end
    if not best then return nil, 'no cavern outpost yet' end
    -- a cavern-floor tile next to the outpost with solid rock under it, and
    -- outside every df-ai room and corridor (df-ai "repairs" holes in its
    -- rooms with a constructed floor, which capped the first shaft)
    local cx, cy, z = best.min[1], best.min[2], best.min[3]
    local function planned(x, y)
        for _, r in ipairs(plan.r or {}) do
            if r.min[3] <= z and r.max[3] >= z and x >= r.min[1] - 1 and x <= r.max[1] + 1 and y >= r.min[2] - 1 and y <= r.max[2] + 1 then
                return true
            end
        end
        return false
    end
    for r = 1, 10 do
        for dx = -r, r do
            for dy = -r, r do
                local x, y = cx + dx, cy + dy
                local s = shape(x, y, z)
                local f = dfhack.maps.getTileFlags(x, y, z)
                if s == df.tiletype_shape.FLOOR and f and not f.hidden and f.flow_size == 0 and not planned(x, y)
                        and is_wall(x, y, z - 1) and not danger_at(x, y, z - 1) and not danger_at(x, y, z - 2) then
                    return {x = x, y = y, z = z}
                end
            end
        end
    end
    return nil, 'no solid floor by the deepest cavern outpost'
end

local function now_days() return df.global.cur_year * 336 + df.global.cur_year_tick // 1200 end

local function dig_hall(s)
    local n = 0
    for dx = -HALL_R, HALL_R do
        for dy = -HALL_R, HALL_R do
            if (dx ~= 0 or dy ~= 0) and is_wall(s.x + dx, s.y + dy, s.cur) and not danger_at(s.x + dx, s.y + dy, s.cur) then
                designate(s.x + dx, s.y + dy, s.cur, df.tile_dig_designation.Default)
                n = n + 1
            end
        end
    end
    return n
end

-- after the hall: a straight exploratory gallery out of it, a new direction each time
local DIRS = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
local function dig_gallery(s)
    local g = (s.galleries or 0) % 4 + 1
    local d = DIRS[g]
    local n = 0
    for i = HALL_R + 1, HALL_R + 12 do
        local x, y = s.x + d[1] * i, s.y + d[2] * i
        if not is_wall(x, y, s.cur) or danger_at(x, y, s.cur) or danger_at(x, y, s.cur - 1) then break end
        designate(x, y, s.cur, df.tile_dig_designation.Default)
        n = n + 1
    end
    s.galleries = (s.galleries or 0) + 1
    return n
end

function step()
    local s = load_state()
    if s.status == 'done' and s.next_gallery and now_days() >= s.next_gallery then
        local n = dig_gallery(s)
        s.next_gallery = now_days() + 84
        if n > 0 then note(s, ('A new gallery, %d tiles, strikes out from the Deep Hall.'):format(n)) end
        save_state(s)
        return 'gallery: ' .. n .. ' tiles'
    end
    if s.status == 'done' then save_state(s) return 'done' end
    if not s.x then
        if citizens() < MATURE_POP then save_state(s) return 'not mature yet' end
        local st, why = find_start()
        if not st then s.status = 'waiting'; s.why = why; save_state(s) return why end
        s.x, s.y, s.top, s.cur = st.x, st.y, st.z, st.z
        s.status = 'digging'
        designate(s.x, s.y, s.cur, df.tile_dig_designation.DownStair)
        s.designated_at = now_days()
        note(s, ('The deep dig begins: a stair shaft down from the cavern at level %d.'):format(st.z))
        save_state(s)
        return 'started at ' .. st.x .. ',' .. st.y .. ',' .. st.z
    end
    -- has the current batch been dug? (every level from the top to the bottom designated)
    local undug = {}
    for z = s.cur, s.top do
        if not is_stair(s.x, s.y, z) then undug[#undug + 1] = z end
    end
    if #undug > 0 then
        if now_days() - (s.designated_at or 0) > STALL_DAYS then
            -- a stalled level: clear every dig job in the shaft column (stale
            -- ones on dug levels and duplicates from earlier re-designations
            -- kept the miners off it), then designate the undug levels again
            local jobs = {}
            local l = df.global.world.jobs.list.next
            while l do
                local j = l.item
                if j.pos.x == s.x and j.pos.y == s.y and j.pos.z <= s.top and j.pos.z >= s.cur and not dfhack.job.getWorker(j) then
                    jobs[#jobs + 1] = j
                end
                l = l.next
            end
            for _, j in ipairs(jobs) do dfhack.job.removeJob(j) end
            for _, z in ipairs(undug) do
                designate(s.x, s.y, z, z == s.top and df.tile_dig_designation.DownStair or df.tile_dig_designation.UpDownStair)
            end
            s.designated_at = now_days()
        end
        save_state(s)
        return ('waiting for the miners: %d of the batch to dig, bottom at level %d'):format(#undug, s.cur)
    end
    -- the next batch down, each level only if safe
    local n = 0
    while n < BATCH do
        local why
        for k = 1, SAFE do
            why = danger_at(s.x, s.y, s.cur - k)
            if why then break end
        end
        if not why and not is_wall(s.x, s.y, s.cur - 1) then why = 'no rock below' end
        if why then
            if n > 0 then break end -- dig what is designated first, then finish
            local h = dig_hall(s)
            s.status, s.stop_reason = 'done', why
            s.next_gallery = now_days() + 28
            note(s, ('The shaft stops %d levels down: %s lies below. The miners carve the Deep Hall (%d tiles).'):format(s.top - s.cur, why, h))
            save_state(s)
            return 'done: ' .. why
        end
        s.cur = s.cur - 1
        designate(s.x, s.y, s.cur, df.tile_dig_designation.UpDownStair)
        n = n + 1
    end
    s.designated_at = now_days()
    note(s, ('%d more levels marked for the miners: the deep shaft will reach %d levels below the cavern.'):format(n, s.top - s.cur))
    save_state(s)
    return ('designated %d levels, down to level %d'):format(n, s.cur)
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_deep_last = ok and res or ('error: ' .. tostring(res))
end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', tick) -- daily
    print('deep dig: started')
elseif cmd == 'stop' then
    repeatUtil.cancel(KEY)
    print('deep dig: stopped')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('deep dig: queued for the next game tick')
else
    local s = load_state()
    print(('deep dig: %s; last: %s; shaft at %s,%s from %s to %s'):format(tostring(s.status), tostring(_G.dfai_deep_last),
        tostring(s.x), tostring(s.y), tostring(s.top), tostring(s.cur)))
end
