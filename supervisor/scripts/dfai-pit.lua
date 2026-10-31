-- dfai-pit: the execution pit and the refuse chute, done properly, for any
-- fort (user: "a pit at the bottom of the pit where things that survive can
-- run around. the refuse should still fall under a bridge tile that is up
-- until cycled to destroy refuse, executions can just drop down and splat or
-- survive or fly or whatever but they are still locked in").
--
-- df-ai digs its pit as a 1x3 shaft: the hatch drop (P), the builders' stair
-- (S, capped at the top) and the refuse chute (R) side by side, all landing on
-- one floor. This script finds that shaft by its zones (a dump zone two tiles
-- from a hatch, the stair between) and rebuilds the bottom:
--
--   the pen     one level below the shaft floor, a 5x5 room under the drop:
--               the pit's floor is channelled, so whatever is thrown in lands
--               in the pen. Its only way in was a spur stair for the miners,
--               which gets capped with a constructed floor: nothing walks out,
--               fliers only reach the sealed shaft
--   the crusher at the foot of the chute, a 2-tile drawbridge kept RAISED:
--               refuse lands on the floor under it; lowering it destroys
--               whatever is there, then it goes back up
--   the chute   dwarves won't dump into open space, so the chute gets a hatch:
--               they dump on it and it's opened to drop the load
-- Our own dead are never crushed (they belong in coffins, or they come back).
--   dfai-pit start | now | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-pit'
local Sh = df.tiletype_shape
local DIG = df.tile_dig_designation

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function attrs(x, y, z) local tt = dfhack.maps.getTileType(x, y, z) return tt and df.tiletype.attrs[tt] end
local function shape(x, y, z) local a = attrs(x, y, z) return a and a.shape end
local function rock(x, y, z)
    local a = attrs(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    return a and a.shape == Sh.WALL and a.material ~= df.tiletype_material.CONSTRUCTION and f.flow_size == 0 and not f.water_table
end
local function is_construction(x, y, z) local a = attrs(x, y, z) return a and a.material == df.tiletype_material.CONSTRUCTION end
local function open(x, y, z) local s = shape(x, y, z) return s == Sh.EMPTY end
local function floorish(x, y, z) local s = shape(x, y, z) return s and s ~= Sh.WALL and s ~= Sh.EMPTY end
local function designate(x, y, z, d)
    local f = dfhack.maps.getTileFlags(x, y, z)
    if f and f.dig ~= d then
        f.dig = d
        dfhack.maps.getTileBlock(x, y, z).flags.designated = true
    end
end
local function built(b) return b and b:getBuildStage() >= b:getMaxBuildStage() end
local function trigger(id, state) return dfhack.run_command_silent('ai', 'trigger', tostring(id), state and '1' or '0') end
local function hatch_at(x, y, z)
    for _, h in ipairs(df.global.world.buildings.other.HATCH) do
        if h.x1 == x and h.y1 == y and h.z == z then return h end
    end
end
local function bridge_at(x, y, z)
    for _, b in ipairs(df.global.world.buildings.other.BRIDGE) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and b.z == z then return b end
    end
end
local function units_on(x, y, z, citizens_only)
    for _, u in ipairs(df.global.world.units.active) do
        if u.pos.x == x and u.pos.y == y and u.pos.z == z and not dfhack.units.isDead(u) and (not citizens_only or dfhack.units.isCitizen(u)) then return u end
    end
end
local function items_at(x, y, z, filter)
    local n = 0
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if not blk then return 0 end
    for _, id in ipairs(blk.items) do
        local it = df.item.find(id)
        if it and it.pos.x == x and it.pos.y == y and it.pos.z == z and it.flags.on_ground and not it.flags.in_job and (not filter or filter(it)) then n = n + 1 end
    end
    return n
end
-- the remains of one of our own: never crushed
local function our_dead_at(x, y, z)
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if not blk then return nil end
    for _, id in ipairs(blk.items) do
        local it = df.item.find(id)
        if it and it.pos.x == x and it.pos.y == y and it.pos.z == z and (df.item_corpsest:is_instance(it) or df.item_corpsepiecest:is_instance(it)) then
            local hf = it.hist_figure_id and df.historical_figure.find(it.hist_figure_id)
            if hf and hf.civ_id == df.global.plotinfo.civ_id then return dfhack.df2utf(dfhack.translation.translateName(hf.name, true)) end
        end
    end
end

-- ---- find the shaft ----
local plan_ok
local function find_shaft()
    for _, zn in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if zn.type == df.civzone_type.Dump and zn.x1 == zn.x2 and zn.y1 == zn.y2 then
            local rx, ry, zt = zn.x1, zn.y1, zn.z
            for _, u in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                local px, py = rx + 2 * u[1], ry + 2 * u[2]
                if hatch_at(px, py, zt) and open(px, py, zt - 1) then
                    local zb = zt - 1
                    while zb > 0 and open(px, py, zb) do zb = zb - 1 end
                    if floorish(px, py, zb) or open(px, py, zb) then
                        local d = {-u[1], -u[2]}                 -- pit -> stair -> refuse
                        local sx, sy = px + d[1], py + d[2]
                        -- the side for the miners' spur and the pen's sides
                        local first
                        for _, e in ipairs({{d[2], d[1]}, {-d[2], -d[1]}}) do
                            local sh = {p = {px, py}, s = {sx, sy}, r = {rx, ry}, d = d, e = e, zt = zt, zb = zb}
                            first = first or sh
                            if plan_ok(sh) then return sh end
                        end
                        return first
                    end
                end
            end
        end
    end
end

-- the pen: 5x5 at zb-1, from under the stair (a=-1) away from the chute (a=3)
local function pen_tiles(sh)
    local t, p, d, e = {}, sh.p, sh.d, sh.e
    for a = -1, 3 do
        for b = -2, 2 do t[#t + 1] = {p[1] - a * d[1] + b * e[1], p[2] - a * d[2] + b * e[2]} end
    end
    return t
end
local function spur(sh) return sh.s[1] + sh.e[1], sh.s[2] + sh.e[2] end
local function crusher(sh)   -- the 2 bridge tiles: the chute's foot and one beyond
    return {sh.r[1], sh.r[2]}, {sh.r[1] + sh.d[1], sh.r[2] + sh.d[2]}
end

plan_ok = function(sh)
    local zp = sh.zb - 1
    for _, t in ipairs(pen_tiles(sh)) do
        if not (rock(t[1], t[2], zp) or floorish(t[1], t[2], zp)) then return false, ('the pen space at %d,%d,%d is not solid rock'):format(t[1], t[2], zp) end
    end
    local _, beyond = crusher(sh)
    if not (rock(beyond[1], beyond[2], sh.zb) or floorish(beyond[1], beyond[2], sh.zb)) then return false, 'no rock beyond the chute for the crusher' end
    local sx, sy = spur(sh)
    if not (rock(sx, sy, sh.zb) or shape(sx, sy, sh.zb) == Sh.STAIR_DOWN or is_construction(sx, sy, sh.zb)) then return false, 'no rock beside the stair for the miners\' spur' end
    return true
end

local function bridge_dir(d)
    local D = df.building_bridgest.T_direction
    if d[1] == 1 then return D.Right elseif d[1] == -1 then return D.Left elseif d[2] == 1 then return D.Down else return D.Up end
end

local function step(s)
    local sh = s.shaft
    if not sh then
        sh = find_shaft()
        if not sh then return 'no execution pit with a refuse chute yet' end
        local ok, why = plan_ok(sh)
        if not ok then return 'pit found, but ' .. why end
        s.shaft, s.phase = sh, 'open'
    end
    local zp = sh.zb - 1
    local sx, sy = spur(sh)
    local cr, beyond = crusher(sh)
    local function removing(x, y, z)
        local l = df.global.world.jobs.list.next
        while l do
            local j = l.item
            if j and j.job_type == df.job_type.RemoveConstruction and j.pos.x == x and j.pos.y == y and j.pos.z == z then return true end
            l = l.next
        end
    end
    -- the builders' way down: df-ai capped the shaft stair with a constructed
    -- floor; it's swapped for a constructed down stair while the work goes on
    -- and capped again at the end
    if s.phase == 'open' then
        local x, y, z = sh.s[1], sh.s[2], sh.zt
        local st = shape(x, y, z)
        if st == Sh.STAIR_DOWN or st == Sh.STAIR_UPDOWN then s.phase = 'dig'
        elseif st == Sh.FLOOR and is_construction(x, y, z) then
            if not removing(x, y, z) then dfhack.constructions.designateRemove(xyz2pos(x, y, z)) end
            return 'opening the stair into the pit shaft for the builders'
        elseif st == Sh.EMPTY then
            if not dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = df.construction_type.DownStair, pos = xyz2pos(x, y, z)})
            end
            return 'a stair down into the pit shaft for the builders'
        else
            return 'pit: the shaft stair top is something unexpected (' .. tostring(df.tiletype_shape[st]) .. ')'
        end
    end
    if s.phase == 'dig' then
        -- the miners' spur stair down beside the shaft stair, the pen, and the
        -- tile beyond the chute's foot for the crusher
        local left = 0
        if shape(sx, sy, sh.zb) ~= Sh.STAIR_DOWN then left = left + 1 designate(sx, sy, sh.zb, DIG.DownStair) end
        if shape(sx, sy, zp) ~= Sh.STAIR_UP then left = left + 1 designate(sx, sy, zp, DIG.UpStair) end
        for _, t in ipairs(pen_tiles(sh)) do
            if not (t[1] == sx and t[2] == sy) and rock(t[1], t[2], zp) then left = left + 1 designate(t[1], t[2], zp, DIG.Default) end
        end
        if rock(beyond[1], beyond[2], sh.zb) then left = left + 1 designate(beyond[1], beyond[2], sh.zb, DIG.Default) end
        if left > 0 then return ('digging the pen under the pit: %d tiles left'):format(left) end
        s.phase = 'drop'
    end
    if s.phase == 'drop' then
        -- open the pit's floor into the pen
        if not open(sh.p[1], sh.p[2], sh.zb) then
            designate(sh.p[1], sh.p[2], sh.zb, DIG.Channel)
            return 'opening the pit floor into the pen'
        end
        s.phase = 'cap'
    end
    if s.phase == 'cap' then
        -- nobody of ours may be left down in the pen
        for _, t in ipairs(pen_tiles(sh)) do
            local u = units_on(t[1], t[2], zp, true)
            if u then return 'waiting for ' .. dfhack.df2utf(dfhack.units.getReadableName(u)) .. ' to climb out of the pen' end
        end
        if shape(sx, sy, sh.zb) == Sh.STAIR_DOWN then
            designate(sx, sy, sh.zb, DIG.Channel)
            return 'closing the miners\' stair into the pen'
        elseif open(sx, sy, sh.zb) then
            if not dfhack.buildings.findAtTile(xyz2pos(sx, sy, sh.zb)) then
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = df.construction_type.Floor, pos = xyz2pos(sx, sy, sh.zb)})
            end
            return 'flooring over the miners\' stair: the pen is sealed once it is built'
        end
        s.phase = 'crusher'
    end
    if s.phase == 'crusher' then
        local b = bridge_at(cr[1], cr[2], sh.zb)
        if b and b.x2 - b.x1 + b.y2 - b.y1 == 0 then
            -- an old 1-tile smasher here: fine as it is (it crushes when raised)
            s.bridge, s.one_tile, s.phase = b.id, true, 'reseal'
        elseif built(b) then
            s.bridge, s.phase = b.id, 'reseal'
            trigger(b.id, false)    -- state 0 raises a drawbridge (tested): up, waiting
        elseif not b then
            local x1, y1 = math.min(cr[1], beyond[1]), math.min(cr[2], beyond[2])
            pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Bridge, pos = xyz2pos(x1, y1, sh.zb),
                width = sh.d[1] ~= 0 and 2 or 1, height = sh.d[2] ~= 0 and 2 or 1, direction = bridge_dir(sh.d)})
            return 'building the crusher at the foot of the chute'
        else
            return 'building the crusher at the foot of the chute'
        end
    end
    if s.phase == 'reseal' then
        -- cap the shaft stair again: nobody of ours left below
        local x, y, z = sh.s[1], sh.s[2], sh.zt
        for zz = sh.zb, z - 1 do
            for _, t in ipairs({sh.p, sh.s, sh.r, {sx, sy}}) do
                local u = units_on(t[1], t[2], zz, true)
                if u then return 'waiting for ' .. dfhack.df2utf(dfhack.units.getReadableName(u)) .. ' to come up out of the shaft' end
            end
        end
        local st = shape(x, y, z)
        if st == Sh.FLOOR then s.phase = 'hatch'
        elseif st == Sh.STAIR_DOWN and is_construction(x, y, z) then
            if not removing(x, y, z) then dfhack.constructions.designateRemove(xyz2pos(x, y, z)) end
            return 'taking the builders\' stair out of the shaft'
        elseif st == Sh.EMPTY then
            if not dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then
                pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Construction, subtype = df.construction_type.Floor, pos = xyz2pos(x, y, z)})
            end
            return 'capping the shaft stair again'
        else
            return 'pit: can\'t cap the shaft stair (' .. tostring(df.tiletype_shape[st]) .. ')'
        end
    end
    if s.phase == 'hatch' then
        local h = hatch_at(sh.r[1], sh.r[2], sh.zt)
        if built(h) then s.hatch, s.phase = h.id, 'running'
        elseif not h then
            if is_construction(sh.r[1], sh.r[2], sh.zt) and shape(sh.r[1], sh.r[2], sh.zt) == Sh.FLOOR then
                dfhack.constructions.designateRemove(xyz2pos(sh.r[1], sh.r[2], sh.zt))
                return 'taking up the floor over the chute for a hatch'
            end
            pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Hatch, pos = xyz2pos(sh.r[1], sh.r[2], sh.zt)})
            return 'a hatch over the refuse chute'
        else
            return 'a hatch over the refuse chute'
        end
    end
    if s.phase == 'running' then
        if not hatch_at(sh.r[1], sh.r[2], sh.zt) then s.phase = 'hatch' return 'the chute hatch is gone: rebuilding' end
        -- drop the load (state 0 opens a hatch; it swings shut by itself)
        local load_n = items_at(sh.r[1], sh.r[2], sh.zt)
        if s.hatch and load_n > 0 and not units_on(sh.r[1], sh.r[2], sh.zt) then
            trigger(s.hatch, false)
            s.dropped = (s.dropped or 0) + load_n
            dfhack.timeout(150, 'ticks', function() pcall(function() local st = load() step(st) save(st) end) end)
        end
        -- crush what lies under the raised bridge: lower it, then raise it again
        local n = items_at(cr[1], cr[2], sh.zb)
        local ours = n > 0 and our_dead_at(cr[1], cr[2], sh.zb)
        local note = ''
        if ours then
            note = (': not crushing, the remains of %s lie there'):format(ours)
        elseif s.bridge and n > 0 and not units_on(cr[1], cr[2], sh.zb, true) and not s.cycling then
            s.cycling = true
            local id = s.bridge
            if s.one_tile then
                trigger(id, false)      -- the old 1-tile kind crushes on the way up
                dfhack.timeout(200, 'ticks', function() trigger(id, true) local st = load() st.cycling = nil save(st) end)
            else
                trigger(id, true)       -- down onto the refuse...
                dfhack.timeout(200, 'ticks', function() trigger(id, false) local st = load() st.cycling = nil save(st) end)   -- ...and back up
            end
            s.crushed = (s.crushed or 0) + n
        end
        local alive = 0
        for _, t in ipairs(pen_tiles(sh)) do
            for _, u in ipairs(df.global.world.units.active) do
                if u.pos.x == t[1] and u.pos.y == t[2] and u.pos.z == zp and not dfhack.units.isDead(u) then alive = alive + 1 end
            end
        end
        return ('running: %d in the pen alive, %d items crushed, %d dropped down the chute%s'):format(alive, s.crushed or 0, s.dropped or 0, note)
    end
    return tostring(s.phase)
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local s = load()
    local ok, res = pcall(step, s)
    s.last = ok and res or ('error: ' .. tostring(res))
    save(s)
end

function status() return 'pit: ' .. tostring(load().last or 'not checked yet') end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 300, 'ticks', tick)
    print('pit: watching')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', tick)
    print('pit: checking on the next tick')
elseif cmd == 'find' then
    local sh = find_shaft()
    if not sh then print('no pit found') return end
    local ok, why = plan_ok(sh)
    print(('pit %d,%d stair %d,%d chute %d,%d top %d bottom %d; spur %d,%d; %s'):format(sh.p[1], sh.p[2], sh.s[1], sh.s[2], sh.r[1], sh.r[2], sh.zt, sh.zb, sh.s[1] + sh.e[1], sh.s[2] + sh.e[2], ok and 'plan fits' or why))
else
    print(status())
end
