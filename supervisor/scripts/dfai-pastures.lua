-- Pasture balancer (user: "your indoor livestock pen is out of cave moss, dudes
-- ate it all. need a bigger livestock pen").
--
-- Two big pens on the cave grass of the first cavern (opened by the beast hunt),
-- and once a game day every pen is weighed up: a pen with more grazers than its
-- grass can feed (one grazer per GRASS_PER tiles) sends the extras to the pen
-- with the most grass to spare. Only grazers in pens move; owned pets, caged and
-- tame-but-wild animals stay where they are.
--
-- Indoor pens are the default (user: "cavern pastures are great they should
-- not be the default and having them in rooms is way safer"): grazers in the
-- cavern pens come back indoors as room allows, new indoor pasture rooms are
-- ordered from dfai-build when the herd outgrows them, and autobutcher keeps
-- each grazing species to its share of the grass (birds to a small laying
-- flock). The cavern pens are only used once ordered ("cavern on").
--
--   dfai-pastures start | now | status | cavern on|off
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-pastures'
local SITE = 350
local GRASS_PER = 6
local CAVERN_PENS = {    -- name, x, y, z (top-left corner of a 20x20 zone)
    {'Cavern Pasture (North)', 41, 59, 129},
    {'Cavern Pasture (East)', 60, 84, 127},
}

local function cfg() return dfhack.persistent.getSiteData(KEY, {cavern = false}) end
local function is_cavern_pen(z)
    for _, p in ipairs(CAVERN_PENS) do if z.x1 == p[2] and z.y1 == p[3] and z.z == p[4] then return true end end
    return (z.name or ''):find('^Cavern Pasture') ~= nil
end

local function is_grass(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local a = df.tiletype.attrs[tt]
    return a.shape == df.tiletype_shape.FLOOR and (a.material == df.tiletype_material.GRASS_LIGHT
        or a.material == df.tiletype_material.GRASS_DARK)
end

local function pens()
    local out = {}
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if z.type == df.civzone_type.Pen and z.spec_sub_flag.active then
            local grass = 0
            for x = z.x1, z.x2 do
                for y = z.y1, z.y2 do
                    if dfhack.buildings.containsTile(z, x, y) and is_grass(x, y, z.z) then grass = grass + 1 end
                end
            end
            local grazers = {}
            for _, id in ipairs(z.assigned_units) do
                local u = df.unit.find(id)
                local c = u and dfhack.units.getCasteRaw(u)
                if c and c.flags.GRAZER and not dfhack.units.isDead(u) then grazers[#grazers + 1] = u end
            end
            out[#out + 1] = {zone = z, grass = grass, grazers = grazers, cap = grass // GRASS_PER, cavern = is_cavern_pen(z)}
        end
    end
    return out
end

local function assign(u, to)
    for i = #u.general_refs - 1, 0, -1 do
        local r = u.general_refs[i]
        if df.general_ref_building_civzone_assignedst:is_instance(r) then
            local old = df.building.find(r.building_id)
            if old then
                for j = #old.assigned_units - 1, 0, -1 do
                    if old.assigned_units[j] == u.id then old.assigned_units:erase(j) end
                end
            end
            u.general_refs:erase(i)
            r:delete()
        end
    end
    local ref = df.general_ref_building_civzone_assignedst:new()
    ref.building_id = to.id
    u.general_refs:insert('#', ref)
    to.assigned_units:insert('#', u.id)
end

local function ensure_cavern_pens()
    if df.global.plotinfo.site_id ~= SITE then return 0 end
    local made = 0
    for _, p in ipairs(CAVERN_PENS) do
        local have = false
        for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if z.type == df.civzone_type.Pen and z.z == p[4] and z.x1 == p[2] and z.y1 == p[3] then
                if z.x2 == z.x1 and z.y2 == z.y1 then
                    dfhack.buildings.deconstruct(z)   -- a 1-tile leftover of the first try
                else
                    have = true
                end
            end
        end
        if not have then
            -- a full 20x20 grid of 'n' merges into one zone (the (WxH) form made one tile)
            local rows = {}
            for r = 1, 20 do
                local cells = {}
                for c = 1, 20 do cells[c] = (r == 1 and c == 1) and ('n{name="%s"}'):format(p[1]) or 'n' end
                rows[r] = table.concat(cells, ',')
            end
            local f = io.open('dfhack-config/blueprints/dfai-pasture.csv', 'w')
            f:write('#zone label(pasture)\n' .. table.concat(rows, '\n') .. '\n')
            f:close()
            dfhack.run_command_silent('quickfort', 'run', 'dfai-pasture.csv', '-c', ('%d,%d,%d'):format(p[2], p[3], p[4]))
            made = made + 1
        end
    end
    return made
end

-- autobutcher: each grazing species keeps its share of the grass; egg layers
-- keep a small flock (eggs, not 66 turkeys); the rest keep autobutcher's default
local function herd_targets(cap)
    local species = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isOwnCiv(u) and dfhack.units.isAnimal(u) and not dfhack.units.isDead(u) then
            local c = dfhack.units.getCasteRaw(u)
            local r = df.creature_raw.find(u.race)
            if c and r then
                if c.flags.GRAZER then species[r.creature_id] = 'grazer'
                elseif c.flags.LAYS_EGGS and not species[r.creature_id] then species[r.creature_id] = 'layer' end
            end
        end
    end
    local n = 0
    for _, k in pairs(species) do if k == 'grazer' then n = n + 1 end end
    local share = n > 0 and math.max(2, cap // n) or 2
    local fa = math.max(1, math.ceil(share * 0.75))
    local ma = math.max(1, share - fa)
    local set = 0
    for id, k in pairs(species) do
        if k == 'grazer' then
            dfhack.run_command_silent('autobutcher', 'target', '1', '0', tostring(fa), tostring(ma), id)
        else
            dfhack.run_command_silent('autobutcher', 'target', '2', '1', '5', '1', id)
        end
        set = set + 1
    end
    return ('autobutcher: %d grazing species at %d+%d adults each, egg layers at 5+1'):format(n, fa, ma)
end

function balance()
    local c = cfg()
    local made = c.cavern and ensure_cavern_pens() or 0
    local P = pens()
    local moved = 0
    -- indoor first: grazers in cavern pens come home as the indoor grass allows
    if not c.cavern then
        for _, from in ipairs(P) do
            if from.cavern then
                while #from.grazers > 0 do
                    local best, room
                    for _, to in ipairs(P) do
                        local spare = to.cap - #to.grazers
                        if not to.cavern and spare > 0 and (not best or spare > room) then best, room = to, spare end
                    end
                    if not best then break end
                    local u = table.remove(from.grazers)
                    assign(u, best.zone)
                    best.grazers[#best.grazers + 1] = u
                    moved = moved + 1
                end
            end
        end
    end
    for _, from in ipairs(P) do
        local extra = #from.grazers - math.max(from.cap, 1)
        while extra > 0 do
            local best, room
            for _, to in ipairs(P) do
                local spare = to.cap - #to.grazers
                if to ~= from and (c.cavern or not to.cavern) and spare > 0 and (not best or spare > room) then best, room = to, spare end
            end
            if not best then break end
            local u = table.remove(from.grazers)
            assign(u, best.zone)
            best.grazers[#best.grazers + 1] = u
            extra, moved = extra - 1, moved + 1
        end
    end
    -- the herd vs the indoor grass: order a new indoor pasture room when it's
    -- short by a pen's worth (one at a time), and trim the herd to fit
    local indoor_cap, grazers, short = 0, 0, 0
    for _, p in ipairs(P) do
        grazers = grazers + #p.grazers
        if c.cavern or not p.cavern then indoor_cap = indoor_cap + p.cap end
    end
    local free_grazers = 0
    for _, u in ipairs(df.global.world.units.active) do
        local cr = dfhack.units.getCasteRaw(u)
        if dfhack.units.isOwnCiv(u) and dfhack.units.isAnimal(u) and not dfhack.units.isDead(u) and cr and cr.flags.GRAZER then free_grazers = free_grazers + 1 end
    end
    short = free_grazers - indoor_cap
    local ordered = ''
    if not c.cavern and short >= 8 then
        local b = dfhack.persistent.getSiteData('dfai-build', {queue = {}})
        local pending = (b.current and b.current.kind == 'pasture')
        for _, k in ipairs(b.queue or {}) do if k == 'pasture' then pending = true end end
        if not pending and (c.ordered or 0) < 3 then
            dfhack.run_command_silent('dfai-build', 'new', 'pasture', '1')
            c.ordered = (c.ordered or 0) + 1
            dfhack.persistent.saveSiteData(KEY, c)
            ordered = '; ordered a new indoor pasture room'
        end
    end
    local butcher = herd_targets(math.max(indoor_cap + (c.cavern and 0 or 12), 8))
    local lines = {('%d grazers, indoor grass for %d%s; %s'):format(free_grazers, indoor_cap, ordered, butcher)}
    for _, p in ipairs(P) do
        local n = dfhack.df2utf(p.zone.name or '')
        lines[#lines + 1] = ('%s%d,%d,%d: %d grazers, grass for %d'):format(n ~= '' and (n .. ' ') or '', p.zone.x1, p.zone.y1, p.zone.z, #p.grazers, p.cap)
    end
    local out = ('%d pens made, %d grazers moved\n%s'):format(made, moved, table.concat(lines, '\n'))
    _G.dfai_pastures_last = out
    return out
end

if dfhack_flags and dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() pcall(balance) end)
    print('pastures: balancing daily')
elseif cmd == 'cavern' then
    local c = cfg()
    c.cavern = (({...})[2] == 'on')
    dfhack.persistent.saveSiteData(KEY, c)
    dfhack.timeout(1, 'ticks', function() pcall(balance) end)
    print(c.cavern and 'pastures: cavern pens in use' or 'pastures: indoor pens only; grazers come home as room allows')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function()
        local ok, r = pcall(balance)
        _G.dfai_pastures_last = ok and r or ('error: ' .. tostring(r))
    end)
    print('pastures: balancing on the next tick')
else
    print('pastures: ' .. (cfg().cavern and '[cavern pens on] ' or '[indoor] ') .. tostring(rawget(_G, 'dfai_pastures_last') or 'not run yet'):gsub('\n', ' | '))
end
