-- dfai-instruments: the Instrument Collection (user: "if you ever get musical
-- instruments in caravans or crafted, you can place them in the big taverns
-- and people will play them. collect them all for something special!").
--
-- Every civilization in the world has its own instruments (103 kinds in The
-- Enchanted Planes). The collection counts the kinds the fort owns - made here,
-- bought from caravans, or carried home from raids - by the people who
-- invented them. Once a game day:
--   * new kinds are announced (and noted for the Herald);
--   * the public tavern is asked to keep the whole collection on show (one of
--     each kind, more than df-ai's 5), the other taverns and temples keep 5;
--   * one work order at a time makes the next of our own people's kinds the
--     fort doesn't have yet (pieces and assembly are the game's business);
--   * a people's set complete = "a full orchestra"; the whole world's = the
--     Grand Concert, a 7-day holiday the Herald calls the event of the age.
--
--   dfai-instruments start | now | status | json
--@module = true

local repeatUtil = require('repeat-util')
local json = require('json')
local KEY = 'dfai-instruments'
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'

local function load() return dfhack.persistent.getSiteData(KEY, {kinds = {}, sets = {}, news = {}}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function notify(msg) local f = io.open(NOTIFY, 'a') if f then f:write(msg .. '\n') f:close() end end
local function u8(s) return dfhack.df2utf(s or '') end

-- who invented a kind: its raw id is "ENT<entity id> IN.."
local function people_of(def)
    local id = tonumber((def.id or ''):match('^ENT(%d+)'))
    local e = id and df.historical_entity.find(id)
    return id, e
end
local function people_name(e)
    if not e then return 'a forgotten people' end
    local n = u8(dfhack.translation.translateName(e.name, true))
    local race = df.creature_raw.find(e.race)
    return n ~= '' and n or ((race and race.name[2] or 'unknown') .. ' civilization'), race and race.name[2] or ''
end
local KIND = {PLAY_KEYBOARD_INSTRUMENT = 'keyboard', PLAY_STRINGED_INSTRUMENT = 'strings', PLAY_WIND_INSTRUMENT = 'wind', PLAY_PERCUSSION_INSTRUMENT = 'percussion'}

-- the collection right now
function census()
    local defs = df.global.world.raws.itemdefs.instruments
    local owned, count = {}, {}
    for _, it in ipairs(df.global.world.items.other.INSTRUMENT) do
        if not it.flags.trader and not it.flags.garbage_collect then
            local st = it:getSubtype()
            owned[st] = true
            count[st] = (count[st] or 0) + 1
        end
    end
    local peoples, order = {}, {}
    for _, d in ipairs(defs) do
        local id, e = people_of(d)
        local key = tostring(id or '?')
        if not peoples[key] then
            local name, race = people_name(e)
            peoples[key] = {id = id, name = name, race = race, total = 0, have = 0, kinds = {}, ours = e and e.id == df.global.plotinfo.civ_id}
            order[#order + 1] = key
        end
        local p = peoples[key]
        p.total = p.total + 1
        local st = d.subtype
        if owned[st] then p.have = p.have + 1 end
        p.kinds[#p.kinds + 1] = {name = u8(d.name), kind = KIND[df.job_skill[d.music_skill]] or 'instrument', have = owned[st] and true or false, n = count[st] or 0, st = st}
    end
    local have, total = 0, #defs
    for _ in pairs(owned) do have = have + 1 end
    local out = {have = have, total = total, peoples = {}}
    for _, k in ipairs(order) do out.peoples[#out.peoples + 1] = peoples[k] end
    table.sort(out.peoples, function(a, b) if a.ours ~= b.ours then return a.ours end return a.have / a.total > b.have / b.total end)
    return out
end

-- the public tavern shows the collection, the rest keep 5
local function display(have)
    local site = dfhack.world.getCurrentSite()
    local pub
    for _, loc in ipairs(site and site.buildings or {}) do
        if df.abstract_building_inn_tavernst:is_instance(loc) and not loc.flags.DOES_NOT_EXIST and (not pub or loc.id < pub.id) then pub = loc end
    end
    if pub then
        local want = math.max(5, math.min(have, 60))
        if pub.contents.desired_instruments ~= want then
            pub.contents.desired_instruments = want
            pub.contents.need_more.instruments = true
        end
        return u8(dfhack.translation.translateName(pub.name, true)), pub.contents.count_instruments
    end
end

-- one instrument at a time for the next kind our own people know how to make,
-- through DFHack's "instruments order" (every piece, then the assembly)
local function pending_order()
    for _, o in ipairs(df.global.world.manager_orders.all) do
        if o.job_type == df.job_type.CustomReaction and o.amount_left > 0 then
            local code = o.reaction_name or ''
            for _, d in ipairs(df.global.world.raws.itemdefs.instruments) do
                if d.source_enid == df.global.plotinfo.civ_id and code:find(d.id, 1, true) then return u8(d.name) end
            end
        end
    end
end
local function order_next(c)
    local busy = pending_order()
    if busy then return busy end
    local owned = {}
    for _, p in ipairs(c.peoples) do for _, k in ipairs(p.kinds) do if k.have then owned[k.st] = true end end end
    for _, d in ipairs(df.global.world.raws.itemdefs.instruments) do
        if d.source_enid == df.global.plotinfo.civ_id and not owned[d.subtype] then
            local ok = pcall(dfhack.run_command_silent, 'instruments', 'order', dfhack.toSearchNormalized(d.name), '1', '-q')
            if ok and pending_order() then return u8(d.name) end
        end
    end
end

-- big instruments (a third of all kinds: organs, drums...) are PLACED_AS_BUILDING:
-- like a weapon rack they're installed, not just stored (user: "some instruments
-- are installed like how weapons racks are installed"). Each loose one gets
-- built in the music hall (dfai-build 'music'), else in the public tavern,
-- on every third tile so the patrons can walk between them.
local function free_big_instruments()
    local out = {}
    for _, i in ipairs(df.global.world.items.other.INSTRUMENT) do
        local f = i.flags
        if i.subtype and i.subtype.flags.PLACED_AS_BUILDING and not dfhack.items.getHolderUnit(i)
            and not f.in_job and not f.trader and not f.construction and not f.removed and not f.garbage_collect
            and not f.hostile and not f.owned and not f.forbid then
            -- loose, or just made and still sitting in its workshop
            local r = dfhack.items.getGeneralRef(i, df.general_ref_type.BUILDING_HOLDER)
            local hb = r and df.building.find(r.building_id)
            if not hb or hb:getType() == df.building_type.Workshop or hb:getType() == df.building_type.Furnace then
                out[#out + 1] = i
            end
        end
    end
    return out
end
local function slots()
    local boxes = {}
    local okb, build = pcall(reqscript, 'dfai-build')
    local bs = dfhack.persistent.getSiteData('dfai-build', {built = {}})
    for _, r in ipairs(bs.built or {}) do
        if r.kind == 'music' then boxes[#boxes + 1] = {r.box[1], r.box[2], r.box[3], r.box[4], r.z} end
    end
    if #boxes == 0 and okb and build.public_tavern then
        local _, zones = build.public_tavern()
        for _, z in ipairs(zones or {}) do boxes[#boxes + 1] = {z.x1, z.y1, z.x2, z.y2, z.z} end
    end
    local out = {}
    for _, b in ipairs(boxes) do
        for x = b[1] + 1, b[3] - 1, 3 do for y = b[2] + 1, b[4] - 1, 3 do
            local p = xyz2pos(x, y, b[5])
            local tt = dfhack.maps.getTileType(p)
            local bld = dfhack.buildings.findAtTile(p)
            if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR and not (bld and bld:getType() ~= df.building_type.Civzone
                and bld:getType() ~= df.building_type.Stockpile) and dfhack.maps.getTileFlags(p).flow_size == 0 then
                out[#out + 1] = p
            end
        end end
    end
    return out
end
function install()
    local items, places = free_big_instruments(), slots()
    local n = 0
    for i, it in ipairs(items) do
        local p = places[i]
        if not p then break end
        local b = dfhack.buildings.constructBuilding{type = df.building_type.Instrument, pos = p, items = {it}}
        if b then n = n + 1 end
    end
    return n, #items, #places
end

local function day()
    if not dfhack.isMapLoaded() then return end
    local s = load()
    local c = census()
    local first = next(s.kinds) == nil
    local new = {}
    for _, p in ipairs(c.peoples) do
        for _, k in ipairs(p.kinds) do
            if k.have and not s.kinds[tostring(k.st)] then
                s.kinds[tostring(k.st)] = df.global.cur_year * 403200 + df.global.cur_year_tick
                if not first then new[#new + 1] = ('the %s %s of %s'):format(k.name, k.kind, p.name) end
            end
        end
        local key = tostring(p.id)
        if p.have == p.total and p.total > 0 and not s.sets[key] then
            s.sets[key] = true
            if not first then
                dfhack.gui.showAnnouncement(('A full orchestra! The fort now owns every instrument of %s.'):format(dfhack.utf2df(p.name)), COLOR_LIGHTGREEN, true)
                notify(('**A full orchestra!** %s now owns all %d instruments of %s.'):format((function() local s = dfhack.world.getCurrentSite() return s and dfhack.df2utf(dfhack.translation.translateName(s.name, true)) or 'The fort' end)(), p.total, p.name))
                table.insert(s.news, 1, {what = 'set', text = ('every instrument of %s (%d)'):format(p.name, p.total), at = df.global.cur_year_tick})
            end
        end
    end
    for _, n in ipairs(new) do
        dfhack.gui.showAnnouncement(('New in the instrument collection: %s.'):format(dfhack.utf2df(n)), COLOR_LIGHTCYAN, false)
        table.insert(s.news, 1, {what = 'new', text = n, at = df.global.cur_year_tick, year = df.global.cur_year})
    end
    while #s.news > 12 do table.remove(s.news) end
    if c.have >= c.total and not s.grand then
        s.grand = true
        notify(('**THE GRAND CONCERT!** %s has collected all %d instruments in the world.'):format((function() local s = dfhack.world.getCurrentSite() return s and dfhack.df2utf(dfhack.translation.translateName(s.name, true)) or 'The fort' end)(), c.total))
        dfhack.run_command_silent('dfai-holiday', 'start', '7', 'The Grand Concert')
    end
    s.have, s.total = c.have, c.total
    s.tavern, s.on_show = display(c.have)
    s.ordering = order_next(c)
    local okn, n = pcall(install)
    if okn and n and n > 0 then s.installed = (s.installed or 0) + n end
    -- every fort gets a music hall beside its public tavern, once (dfai-build
    -- waits for the tavern itself)
    if not s.hall_ordered then
        local okb, build = pcall(reqscript, 'dfai-build')
        if okb and build.public_tavern and build.public_tavern() then
            dfhack.run_command_silent('dfai-build', 'new', 'music')
            s.hall_ordered = df.global.cur_year
        end
    end
    save(s)
end

function report()
    local s = load()
    local c = census()
    c.news, c.tavern, c.on_show, c.ordering, c.grand = s.news or {}, s.tavern, s.on_show, s.ordering, s.grand
    return c
end

function status()
    local s = load()
    local c = census()
    local full = 0
    for _, p in ipairs(c.peoples) do if p.have == p.total then full = full + 1 end end
    return ('instrument collection: %d of %d kinds, from %d peoples (%d full set%s)%s%s'):format(c.have, c.total, #c.peoples, full, full == 1 and '' or 's',
        s.tavern and ('; %s shows %d'):format(s.tavern, s.on_show or 0) or '', s.ordering and ('; making a ' .. s.ordering) or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() pcall(day) end)
    dfhack.timeout(1, 'ticks', function() pcall(day) end)
    print('instruments: collecting')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(day) if not ok then print(e) end end)
    print('instruments: counting on the next tick')
elseif cmd == 'json' then
    print(json.encode(report()))
else
    print(status())
end
