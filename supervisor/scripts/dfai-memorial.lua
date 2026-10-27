-- The memorial (user: "sprinkle in statues... dig one square out of a wall and
-- place them there so they look inset"; statues that tell the fort's story).
--
-- Showerwheels (site 350): the fallen of the beast hunt, in microcline, each in
-- a niche cut into the walls of the public tavern, The Ominous Sack (z171).
--
--   dfai-memorial start | status
--
-- phases: dig (one wall tile per niche; rock behind each, so they stay
-- niches) -> carve (statue jobs at a mason's shop with the subject set via
-- job.art_spec, all in one stone) -> place (each finished statue goes into its
-- own niche by name: the order on the wall is fixed) -> done.
--@ module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-memorial'
local SITE = 350
local Z = 171
local STONE = 'MICROCLINE'
local SHOP = 8162                -- mason's workshop by the mist chamber
local NOTIFY = (os.getenv('LOCALAPPDATA') or '') .. '/hermes/cache/dfai_notify.txt'
-- niche = wall tile cut out; subject = historical figure id
local NICHES = {
    {54, 127, 3217},   -- Tobul "Diamondcloistered", elite wrestler
    {56, 127, 6916},   -- Dumed "Tamedpaddles", elite wrestler
    {58, 127, 6921},   -- Morul "Rewardpaddles", elite wrestler
    {60, 127, 6955},   -- Onul "Helmbands", elite wrestler
    {62, 127, 6958},   -- Olon "Romanticgranite", elite wrestler
    {64, 127, 7186},   -- Fikod "Autumnalceiling", wrestler
    {53, 124, 6865},   -- Erith "Axerose", axe lord
    {53, 126, 7189},   -- Melbil "Neutralshoots", hammerdwarf
    -- the mist chamber (z174, floor already there): the beasts and their slayers
    {30, 118, 97, 174},    -- Osel "Witchsplashed the Washed", forgotten beast
    {33, 118, 4711, 174},  -- Solon "Greatercrafted", who slew Osel and fell
    {30, 121, 64, 174},    -- Rulush, forgotten beast
    {33, 121, 6825, 174},  -- Lorbam "Craftmob", who slew Rulush
}
local function nz(n) return n[4] or Z end

local function load() return dfhack.persistent.getSiteData(KEY, {}) end
local function save(s) dfhack.persistent.saveSiteData(KEY, s) end
local function notify(msg)
    local f = io.open(NOTIFY, 'a')
    if f then f:write(msg .. '\n') f:close() end
end
local function shape(x, y, z) return df.tiletype.attrs[dfhack.maps.getTileType(x, y, z)].shape end
local function hf_name(id)
    local hf = df.historical_figure.find(id)
    return hf and dfhack.df2utf(dfhack.translation.translateName(hf.name, true)) or tostring(id)
end
local function stone_index()
    for i, r in ipairs(df.global.world.raws.inorganics) do if r.id == STONE then return i end end
    return -1
end

local function designate(x, y, z)
    local f = dfhack.maps.getTileFlags(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    f.dig = df.tile_dig_designation.Default
    local ev
    for _, v in ipairs(b.block_events) do
        if v:getType() == df.block_square_event_type.designation_priority then ev = v break end
    end
    if not ev then
        b.block_events:insert('#', {new = df.block_square_event_designation_priorityst})
        ev = b.block_events[#b.block_events - 1]
    end
    ev.priority[x % 16][y % 16] = 1000
    b.flags.designated = true
end

local function carve(hf_id, mat_index)
    local shop = df.building.find(SHOP)
    if not shop then return false end
    local j = df.job:new()
    j.job_type = df.job_type.ConstructStatue
    j.pos = xyz2pos(shop.centerx, shop.centery, shop.z)
    -- the stone goes on the JOB: a workshop job takes its material from
    -- job.mat_type/mat_index, and a material on the job_item alone is ignored
    -- (the first statues came out basalt, diorite and even iron ore)
    j.mat_type = 0
    j.mat_index = mat_index
    local ji = df.job_item:new()
    ji.item_type = df.item_type.BOULDER
    ji.item_subtype = -1
    ji.mat_type = 0
    ji.mat_index = mat_index
    ji.quantity = 1
    ji.vector_id = df.job_item_vector_id.BOULDER
    ji.flags3.hard = true
    j.job_items.elements:insert('#', ji)
    j.art_spec.type = df.job_art_specifier_type.HistoricalFigure
    j.art_spec.id = hf_id
    j.art_spec.subid = -1
    dfhack.job.linkIntoWorld(j, true)
    dfhack.job.assignToWorkshop(j, shop)
    return true
end

local function carving_for(hf_id)
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j.job_type == df.job_type.ConstructStatue and j.art_spec.type == df.job_art_specifier_type.HistoricalFigure and j.art_spec.id == hf_id then return true end
        l = l.next
    end
end

-- a finished, free statue of this figure
local function statue_of(hf_id)
    local name = hf_name(hf_id)
    for _, it in ipairs(df.global.world.items.other.STATUE) do
        if not it.flags.in_building and not it.flags.in_job and not it.flags.garbage_collect
            and dfhack.df2utf(it.description) == name then return it end
    end
end

local function place(s, mat)
        local done, waiting = 0, {}
        for _, n in ipairs(NICHES) do
            local k = tostring(n[3])
            if shape(n[1], n[2], nz(n)) == df.tiletype_shape.WALL then waiting[#waiting + 1] = hf_name(n[3]):match('^(%S+)') goto continue end
            local b = dfhack.buildings.findAtTile(xyz2pos(n[1], n[2], nz(n)))
            if b and df.building_statuest:is_instance(b) and b:getBuildStage() == 0 and #b.contained_items == 0 and not s.placed[k] then
                dfhack.buildings.deconstruct(b)
                b = nil
            end
            if b and df.building_statuest:is_instance(b) then
                if b:getBuildStage() >= b:getMaxBuildStage() then done = done + 1 end
                s.placed[k] = true
            else
                local it = statue_of(n[3])
                if it then
                    it.flags.forbid = false
                    local ok, nb = pcall(dfhack.buildings.constructBuilding,
                        {type = df.building_type.Statue, pos = xyz2pos(n[1], n[2], nz(n)), items = {it}})
                    if ok and nb then s.placed[k] = true end
                elseif not carving_for(n[3]) then
                    carve(n[3], mat)   -- lost or cancelled: carve again
                end
                waiting[#waiting + 1] = hf_name(n[3]):match('^(%S+)')
            end
            ::continue::
        end
        if done == #NICHES then
            s.phase = 'done'
            local names = {}
            for _, n in ipairs(NICHES) do if not n[4] then names[#names + 1] = hf_name(n[3]) end end
            notify(('**A memorial for the fallen.** Eight microcline statues now stand in niches cut into the walls of The Ominous Sack, one for each dwarf who died in the beast hunt: %s. In the mist chamber, the two beasts stand beside the dwarves who slew them. The camera visits them all with their stories.')
                :format(table.concat(names, ', ')))
            -- generic statues held back for the story ones can go anywhere now
            for _, it in ipairs(df.global.world.items.other.STATUE) do
                if it.flags.forbid and not it.flags.in_building and not it.flags.in_job then
                    local mine = false
                    for _, n in ipairs(NICHES) do if dfhack.df2utf(it.description) == hf_name(n[3]) then mine = true end end
                    if not mine then it.flags.forbid = false end
                end
            end
        end
        save(s)
        return ('statues: %d of %d standing (memorial and mist chamber)%s'):format(done, #NICHES, #waiting > 0 and ('; waiting on ' .. table.concat(waiting, ', ')) or '')
    end

local function step()
    if df.global.plotinfo.site_id ~= SITE then return 'not this fort' end
    local s = load()
    s.phase = s.phase or 'dig'
    s.placed = s.placed or {}
    s.ordered = s.ordered or {}
    local mat = stone_index()
    -- claim finished memorial statues at once, so no other planned statue takes them
    for _, n in ipairs(NICHES) do
        local it = statue_of(n[3])
        if it then it.flags.forbid = true end
    end

    if s.phase == 'dig' then
        local left = 0
        for _, n in ipairs(NICHES) do
            if shape(n[1], n[2], nz(n)) == df.tiletype_shape.WALL then
                left = left + 1
                if dfhack.maps.getTileFlags(n[1], n[2], nz(n)).dig == df.tile_dig_designation.No then designate(n[1], n[2], nz(n)) end
            end
        end
        -- carving starts at once, alongside the digging
        for _, n in ipairs(NICHES) do
            local k = tostring(n[3])
            if not s.ordered[k] and not s.placed[k] and not carving_for(n[3]) and not statue_of(n[3]) and carve(n[3], mat) then s.ordered[k] = true end
        end
        if left == 0 then s.phase = 'place' end
        local res = place(s, mat)
        save(s)
        local niches = 0
        for _, n in ipairs(NICHES) do if not n[4] then niches = niches + 1 end end
        return ('cutting niches: %d of %d left; %s'):format(left, niches, res)
    end

    if s.phase == 'place' then return place(s, mat) end
    return s.phase
end

local function tick()
    local ok, res = pcall(step)
    _G.dfai_memorial_last = ok and res or ('error: ' .. tostring(res))
end

if dfhack_flags and dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 600, 'ticks', tick)
    dfhack.timeout(1, 'ticks', tick)
    print('memorial: started')
else
    print(('memorial: %s; last: %s'):format(load().phase or 'not started', tostring(rawget(_G, 'dfai_memorial_last'))))
end
