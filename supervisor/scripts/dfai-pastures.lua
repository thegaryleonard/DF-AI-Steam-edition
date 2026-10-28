-- Pasture balancer (user: "your indoor livestock pen is out of cave moss, dudes
-- ate it all. need a bigger livestock pen").
--
-- Two big pens on the cave grass of the first cavern (opened by the beast hunt),
-- and once a game day every pen is weighed up: a pen with more grazers than its
-- grass can feed (one grazer per GRASS_PER tiles) sends the extras to the pen
-- with the most grass to spare. Only grazers in pens move; owned pets, caged and
-- tame-but-wild animals stay where they are.
--
--   dfai-pastures start | now | status
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-pastures'
local SITE = 350
local GRASS_PER = 6
local CAVERN_PENS = {    -- name, x, y, z (top-left corner of a 20x20 zone)
    {'Cavern Pasture (North)', 41, 59, 129},
    {'Cavern Pasture (East)', 60, 84, 127},
}

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
            out[#out + 1] = {zone = z, grass = grass, grazers = grazers, cap = grass // GRASS_PER}
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

function balance()
    local made = ensure_cavern_pens()
    local P = pens()
    local moved = 0
    for _, from in ipairs(P) do
        local extra = #from.grazers - math.max(from.cap, 1)
        while extra > 0 do
            local best, room
            for _, to in ipairs(P) do
                local spare = to.cap - #to.grazers
                if to ~= from and spare > 0 and (not best or spare > room) then best, room = to, spare end
            end
            if not best then break end
            local u = table.remove(from.grazers)
            assign(u, best.zone)
            best.grazers[#best.grazers + 1] = u
            extra, moved = extra - 1, moved + 1
        end
    end
    local lines = {}
    for _, p in ipairs(P) do
        local n = dfhack.df2utf(p.zone.name or '')
        lines[#lines + 1] = ('%s%d,%d,%d: %d grazers, grass for %d'):format(n ~= '' and (n .. ' ') or '', p.zone.x1, p.zone.y1, p.zone.z, #p.grazers, p.cap)
    end
    return ('%d pens made, %d grazers moved\n%s'):format(made, moved, table.concat(lines, '\n'))
end

if dfhack_flags and dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() pcall(balance) end)
    print('pastures: balancing daily')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function()
        local ok, r = pcall(balance)
        _G.dfai_pastures_last = ok and r or ('error: ' .. tostring(r))
    end)
    print('pastures: balancing on the next tick')
else
    print('pastures: ' .. tostring(rawget(_G, 'dfai_pastures_last') or 'not run yet'))
end
