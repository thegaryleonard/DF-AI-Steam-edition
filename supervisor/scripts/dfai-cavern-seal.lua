-- dfai-cavern-seal: breach, then seal (user: "you have to breach and seal the
-- first cavern before cave moss will grow on dirt"). df-ai's "Find Next
-- Cavern" digs an outpost corridor into each cavern; once the cavern is
-- discovered (that's what lets cave moss grow), a constructed wall goes up
-- in the corridor at its turning tile (df-ai logs it as "outpost: wall"), so
-- nothing walks in from the caverns. Waits while any citizen is out in that
-- cavern, so nobody is shut outside.
--   dfai-cavern-seal start | now | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-cavern-seal'
local function load() return dfhack.persistent.getSiteData(KEY, {done = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end

-- every outpost df-ai planned: its wall (corridor turn) and target (cavern floor)
local function outposts()
    local f = io.open(dfhack.getDFPath() .. '/df-ai.log', 'rb')
    if not f then return {} end
    local size = f:seek('end')
    f:seek('set', math.max(0, size - 8 * 1024 * 1024))
    local text = f:read('a')
    f:close()
    local out, wall = {}, nil
    for line in text:gmatch('[^\n]+') do
        local x, y, z = line:match('outpost: wall %((%d+), (%d+), (%d+)%)')
        if x then wall = {tonumber(x), tonumber(y), tonumber(z)} end
        local tx, ty, tz = line:match('outpost: target %((%d+), (%d+), (%d+)%)')
        if tx and wall then
            out[('%d,%d,%d'):format(wall[1], wall[2], wall[3])] = {wall = wall, target = {tonumber(tx), tonumber(ty), tonumber(tz)}}
            wall = nil
        end
    end
    return out
end

local function region_of(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    return b and b.global_feature ~= -1 and df.world_underground_region.find(b.global_feature)
end
local function citizens_out_in(region)
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        local d = dfhack.maps.getTileFlags(u.pos)
        if d and d.feature_global and region_of(u.pos.x, u.pos.y, u.pos.z) == region then return true end
    end
end
local function shape(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape
end

-- After the seal: the FIRST cavern is opened again for its ore once the army
-- can clear it (user: "mine the first cavern if its safe after squads can
-- clear it out"). Ready = at least 2 squads of 5+ armed, armored dwarves. The
-- wall comes down, the squads get a kill list of every hostile or wild
-- creature seen out there, and after 3 quiet days dfai-cavern-ore starts.
-- A great danger (forgotten beast, titan, demon...) out there stops the
-- mining and puts the wall back up once nobody is outside.
local READY_SQUADS, QUIET_DAYS = 2, 3

local function armed_armored_squads()
    local n = 0
    for _, sqid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sqid)
        local good = 0
        for _, pos in ipairs(sq and sq.positions or {}) do
            if pos.occupant ~= -1 then
                local hf = df.historical_figure.find(pos.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u and not dfhack.units.isDead(u) and dfhack.units.isActive(u) then
                    local ok = true
                    for _, cat in ipairs({'weapon', 'body', 'head', 'pants'}) do
                        for _, spec in ipairs(pos.equipment.uniform[cat]) do
                            if #spec.assigned == 0 then ok = false end
                        end
                    end
                    if ok then good = good + 1 end
                end
            end
        end
        if good >= 5 then n = n + 1 end
    end
    return n
end
-- what's out there in that cavern: hostile/wild creatures and great dangers
local function cavern_creatures(region)
    local foes, great = {}, nil
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and dfhack.units.isActive(u) and not dfhack.units.isCitizen(u)
            and not dfhack.units.isTame(u) and not u.flags1.caged and not dfhack.maps.getTileFlags(u.pos).hidden
            and dfhack.maps.getTileFlags(u.pos).feature_global and region_of(u.pos.x, u.pos.y, u.pos.z) == region then
            if dfhack.units.isGreatDanger(u) then great = u end
            if dfhack.units.isDanger(u) or dfhack.units.isWildlife(u) or dfhack.units.isGreatDanger(u) then foes[#foes + 1] = u.id end
        end
    end
    return foes, great
end
local function kill_list(ids)
    for _, sqid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
        local sq = df.squad.find(sqid)
        if sq and sq.assigned_army_controller_id == -1 then
            for i = #sq.orders - 1, 0, -1 do
                local o = sq.orders[i]
                if df.squad_order_kill_listst:is_instance(o) and o.title == 'Clear the caverns' then sq.orders:erase(i) end
            end
            if #ids > 0 then
                local o = df.squad_order_kill_listst:new()
                o.title = 'Clear the caverns'
                for _, id in ipairs(ids) do o.units:insert('#', id) end
                o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
                sq.orders:insert('#', o)
            end
        end
    end
end
local function first_cavern(s)
    local best, bz
    for key, st in pairs(s.done) do
        if st == 'sealed' or type(st) == 'table' then
            local w = {key:match('(%d+),(%d+),(%d+)')}
            local z = tonumber(w[3])
            if z and (not bz or z > bz) then best, bz = key, z end
        end
    end
    return best
end
-- the reopen/clear/mine cycle for the first cavern (state in s.first)
local function first_cavern_step(s, notes, ops)
    local key = first_cavern(s)
    if not key then return end
    local o = ops[key]
    if not o then return end
    local w, t = o.wall, o.target
    local region = region_of(t[1], t[2], t[3])
    if not region then return end
    local f = s.first or {phase = 'sealed'}
    s.first = f
    local foes, great = cavern_creatures(region)
    if great and f.phase ~= 'sealed' then
        dfhack.run_command_silent('dfai-cavern-ore', 'stop')
        kill_list({})
        f.phase, f.quiet = 'sealed', 0
        s.done[key] = nil   -- the main loop walls it up again once nobody is out there
        notes[#notes + 1] = ('a great danger is in the first cavern: mining stopped, the wall goes back up')
        dfhack.gui.showAnnouncement('Something terrible lurks in the caverns. The way down is being walled up again.', COLOR_LIGHTRED, true)
        return
    end
    if f.phase == 'sealed' then
        local ready = armed_armored_squads()
        if great or ready < READY_SQUADS then
            notes[#notes + 1] = ('first cavern stays sealed until %d squads are armed and armored (%d now)%s'):format(READY_SQUADS, ready, great and '; a great danger is out there' or '')
            return
        end
        if shape(w[1], w[2], w[3]) == df.tiletype_shape.WALL then dfhack.constructions.designateRemove(xyz2pos(w[1], w[2], w[3])) end
        f.phase, f.quiet = 'clearing', 0
        notes[#notes + 1] = 'the army is ready: opening the first cavern to clear it out'
        dfhack.gui.showAnnouncement('The squads are going down to clear out the caverns.', COLOR_YELLOW, true)
    elseif f.phase == 'clearing' then
        kill_list(foes)
        if #foes == 0 and shape(w[1], w[2], w[3]) ~= df.tiletype_shape.WALL then f.quiet = (f.quiet or 0) + 1 else f.quiet = 0 end
        notes[#notes + 1] = ('clearing the first cavern: %d creatures out there, %d of %d quiet days'):format(#foes, f.quiet, QUIET_DAYS)
        if f.quiet >= QUIET_DAYS then
            f.phase = 'mining'
            dfhack.run_command_silent('dfai-cavern-ore', 'start')
            dfhack.gui.showAnnouncement('The first cavern is clear: the miners go after its ore.', COLOR_LIGHTGREEN, false)
        end
    elseif f.phase == 'mining' then
        if #foes > 0 then kill_list(foes) end
        notes[#notes + 1] = ('first cavern open and mined%s'):format(#foes > 0 and (' (squads after %d creatures)'):format(#foes) or '')
    end
end

C = rawget(_G, 'dfai_cavern_seal') or {last = 'idle'}
rawset(_G, 'dfai_cavern_seal', C)

local function step()
    if not dfhack.isMapLoaded() then return end
    local s = load()
    local notes = {}
    local ops = outposts()
    for key, o in pairs(ops) do
        -- the first cavern, once reopened, isn't walled up again by this loop
        if not s.done[key] and not (s.first and s.first.phase ~= 'sealed' and first_cavern(s) == key) then
            local w, t = o.wall, o.target
            local region = region_of(t[1], t[2], t[3])
            local tf = dfhack.maps.getTileFlags(t[1], t[2], t[3])
            local wf = dfhack.maps.getTileFlags(w[1], w[2], w[3])
            if region and region.feature_init and region.feature_init.flags.Discovered and tf and not tf.hidden then
                local bld = dfhack.buildings.findAtTile(xyz2pos(w[1], w[2], w[3]))
                if shape(w[1], w[2], w[3]) == df.tiletype_shape.WALL then
                    s.done[key] = 'sealed'
                    notes[#notes + 1] = ('cavern at level %d sealed'):format(t[3])
                elseif bld and bld:getType() == df.building_type.Construction then
                    notes[#notes + 1] = ('sealing the cavern at level %d (wall being built at %d,%d)'):format(t[3], w[1], w[2])
                elseif citizens_out_in(region) then
                    notes[#notes + 1] = ('cavern at level %d is open; waiting for dwarves to come back in before sealing'):format(t[3])
                elseif wf and not wf.hidden and shape(w[1], w[2], w[3]) == df.tiletype_shape.FLOOR and not bld then
                    local ok = pcall(dfhack.run_command_silent, 'quickfort', 'run', 'dfai-gen/seal.csv', '-c', ('%d,%d,%d'):format(w[1], w[2], w[3]))
                    notes[#notes + 1] = ('cavern at level %d is open: walling the outpost corridor at %d,%d%s'):format(t[3], w[1], w[2], ok and '' or ' (failed)')
                    if not s.announced or not s.announced[key] then
                        s.announced = s.announced or {}
                        s.announced[key] = true
                        dfhack.gui.showAnnouncement('The caverns are open: the outpost corridor is being walled up.', COLOR_YELLOW, false)
                    end
                end
            end
        end
    end
    local ok, e = pcall(first_cavern_step, s, notes, ops)
    if not ok then notes[#notes + 1] = 'first cavern: ' .. tostring(e) end
    C.last = #notes > 0 and table.concat(notes, '; ') or 'no open cavern breach'
    save(s)
end

function status()
    local s = load()
    local n = 0
    for _ in pairs(s.done) do n = n + 1 end
    return ('cavern seal: %s; %d breaches sealed'):format(C.last, n)
end

if dfhack_flags.module then return end
local dir = dfhack.getDFPath() .. '/dfhack-config/blueprints/dfai-gen'
dfhack.filesystem.mkdir_recursive(dir)
local f = io.open(dir .. '/seal.csv', 'w') f:write('#build label(seal) start(1;1)\nCw\n') f:close()
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() local ok, e = pcall(step) if not ok then C.last = 'error: ' .. tostring(e) end end)
    print('cavern seal: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then C.last = 'error: ' .. tostring(e) end end)
    print('cavern seal: checking on the next tick')
else
    print(status())
end
