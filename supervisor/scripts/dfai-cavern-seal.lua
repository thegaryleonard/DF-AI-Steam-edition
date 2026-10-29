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

C = rawget(_G, 'dfai_cavern_seal') or {last = 'idle'}
rawset(_G, 'dfai_cavern_seal', C)

local function step()
    if not dfhack.isMapLoaded() then return end
    local s = load()
    local notes = {}
    for key, o in pairs(outposts()) do
        if not s.done[key] then
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
