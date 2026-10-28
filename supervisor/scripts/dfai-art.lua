-- dfai-art: plain-English descriptions of artwork (statues, engravings)
-- from DF's art image records: who/what is shown, what they are doing, and
-- the historical event it commemorates. Used by the room tour (statue stops)
-- and the broadsheet's On Camera card.
--@ module = true

local function hf_name(id)
    local hf = df.historical_figure.find(id)
    if not hf then return nil end
    local n = dfhack.translation and dfhack.translation.translateName(hf.name, false) or dfhack.TranslateName(hf.name, false)
    if n == '' then
        local raw = df.creature_raw.find(hf.race)
        n = raw and ('a ' .. raw.name[0]) or 'someone'
    end
    return dfhack.df2utf(n)
end

local function creature_word(race, caste, plural)
    local raw = df.creature_raw.find(race)
    if not raw then return 'a creature' end
    local c = raw.caste[caste]
    local nm = c and c.caste_name[plural and 1 or 0] or raw.name[plural and 1 or 0]
    return plural and nm or ((nm:match('^[aeiouAEIOU]') and 'an ' or 'a ') .. nm)
end

local function item_word(e)
    local ok, s = pcall(function()
        local def = dfhack.items.getSubtypeDef(e.item_type, e.item_subtype)
        local name = def and def.name or df.item_type[e.item_type]:lower()
        local mat = dfhack.matinfo.decode(e.mat_type, e.mat_index)
        return (mat and (mat:toString() .. ' ') or '') .. name
    end)
    s = ok and s or 'an object'
    return (s:match('^[aeiou]') and 'an ' or 'a ') .. s
end

local function plant_word(id, plural)
    local p = df.plant_raw.find(id)
    if not p then return 'plants' end
    return plural and p.name_plural or ((p.name:match('^[aeiou]') and 'an ' or 'a ') .. p.name)
end

local SHAPES = {}
local function shape_word(e)
    local s = df.global.world.raws.descriptors.shapes[e.shape_id]
    if not s then return 'a shape' end
    local nm = s.name[e.count > 1 and 1 or 0] or s.name[0]
    if e.count > 1 then return tostring(e.count) .. ' ' .. nm end
    return (nm:match('^[aeiou]') and 'an ' or 'a ') .. nm
end

-- one element -> phrase
local function element_text(e)
    local t = e:getType()
    if t == df.art_image_element_type.CREATURE then
        if e.histfig ~= -1 then return hf_name(e.histfig) or creature_word(e.race, e.caste) end
        return creature_word(e.race, e.caste)
    elseif t == df.art_image_element_type.ITEM then
        return item_word(e)
    elseif t == df.art_image_element_type.PLANT then
        return plant_word(e.plant_id, (e.count or 1) > 1)
    elseif t == df.art_image_element_type.TREE then
        return plant_word(e.plant_id, (e.count or 1) > 1)
    elseif t == df.art_image_element_type.SHAPE then
        return shape_word(e)
    end
    return 'something'
end

local VERB = {
    -- transitive (subject verb object)
    Admiring = 'admiring', Attacking = 'attacking', Beating = 'beating', Bowing = 'bowing to',
    Embracing = 'embracing', Kicking = 'kicking', Killing = 'killing', Mocking = 'mocking',
    Murdering = 'murdering', Praying = 'praying to', Shaking = 'shaking hands with',
    Striking = 'striking', Surrendering = 'surrendering to', Wrestling = 'wrestling with',
    Making = 'making', Holding = 'holding',
    -- intransitive
    Laughing = 'laughing', Crying = 'crying', Mourning = 'in mourning', Praying2 = 'praying',
    Meditating = 'meditating', Dancing = 'dancing', Cowering = 'cowering', Rejoicing = 'rejoicing',
    Shrieking = 'shrieking', Prostrating = 'prostrate', Smiling = 'smiling', Frowning = 'frowning',
    Resting = 'resting', Scowling = 'scowling', Screaming = 'screaming', Singing = 'singing',
}
local function verb_word(name)
    if not name then return nil end
    return VERB[name] or name:gsub('(%u)', function(c) return ' ' .. c:lower() end):gsub('^ ', '')
end

-- the art image behind an item (statue, figurine, engraving ref)
function image_of(item)
    local ref = item and item.image
    if not ref or ref.id == -1 then return nil end
    local chunk = df.art_image_chunk.find(ref.id)
    local m = chunk and chunk.images[ref.subid]
    return m and m.art_image or nil   -- the chunk holds members; the image hangs off each
end

local function event_text(img)
    if not img.event or img.event == -1 then return nil end
    local ev = df.history_event.find(img.event)
    if not ev then return nil end
    local ok, s = pcall(function()
        local t = ev:getType()
        if t == df.history_event_type.HIST_FIGURE_DIED then
            local v, k = hf_name(ev.victim_hf), ev.slayer_hf ~= -1 and hf_name(ev.slayer_hf)
            return ('the death of %s%s in the year %d'):format(v or 'someone', k and (' at the hands of ' .. k) or '', ev.year)
        elseif t == df.history_event_type.MASTERPIECE_CREATED_ITEM or t == df.history_event_type.ARTIFACT_CREATED then
            return ('a masterwork made in the year %d'):format(ev.year)
        end
        local nm = df.history_event_type[t]:lower():gsub('_', ' ')
        return ('the %s of the year %d'):format(nm, ev.year)
    end)
    return ok and s or nil
end

-- full description: "Depicts X attacking Y, and Z. The artwork relates to ..."
function describe_image(img)
    if not img then return nil end
    local parts = {}
    local by_id = {}
    for _, e in ipairs(img.elements) do by_id[e.id] = e end
    local used = {}
    local phrases = {}
    for _, p in ipairs(img.properties) do
        local pt = p:getType()
        local ok = pcall(function()
            if pt == df.art_image_property_type.transitive_verb then
                local a, b = by_id[p.subject], by_id[p.object]
                if a and b then
                    phrases[#phrases + 1] = ('%s %s %s'):format(element_text(a), verb_word(df.art_image_property_verb[p.verb]), element_text(b))
                    used[a.id], used[b.id] = true, true
                end
            elseif pt == df.art_image_property_type.intransitive_verb then
                local a = by_id[p.subject]
                if a then
                    phrases[#phrases + 1] = ('%s %s'):format(element_text(a), verb_word(df.art_image_property_verb[p.verb]))
                    used[a.id] = true
                end
            end
        end)
    end
    for _, e in ipairs(img.elements) do
        if not used[e.id] then phrases[#phrases + 1] = element_text(e) end
    end
    if #phrases == 0 then return nil end
    local list = phrases[1]
    if #phrases == 2 then list = phrases[1] .. ' and ' .. phrases[2]
    elseif #phrases > 2 then list = table.concat(phrases, ', ', 1, #phrases - 1) .. ' and ' .. phrases[#phrases] end
    local out = 'It depicts ' .. list .. '.'
    local ev = event_text(img)
    if ev then out = out .. ' It commemorates ' .. ev .. '.' end
    local nm = dfhack.translation and dfhack.translation.translateName(img.name, true) or dfhack.TranslateName(img.name, true)
    return out, (nm ~= '' and dfhack.df2utf(nm) or nil)
end

-- who a statue shows. DF 53 keeps only the subject's words on the item
-- ("Atir Oilloves", "shortfin mako sharks"); the full scene sits on disk until
-- a player opens it. So we tell the subject's own story from the records.
local QUALITY = {[0] = '', 'well-crafted', 'finely-crafted', 'superior', 'exceptional', 'masterful'}
local subject_cache = {}

local function name_of_hf(hf, english)
    local n = dfhack.translation and dfhack.translation.translateName(hf.name, english or false) or dfhack.TranslateName(hf.name, english or false)
    return dfhack.df2utf(n)
end
local function hf_named(hf, name)
    return name_of_hf(hf) == name or name_of_hf(hf, true) == name
end

local function find_hf_by_name(name)
    if subject_cache[name] ~= nil then return subject_cache[name] or nil end
    -- units first (the fort's own, alive or dead), then all of history once
    for _, u in ipairs(df.global.world.units.all) do
        if u.hist_figure_id ~= -1 then
            local hf = df.historical_figure.find(u.hist_figure_id)
            if hf and hf_named(hf, name) then subject_cache[name] = hf return hf end
        end
    end
    for _, hf in ipairs(df.global.world.history.figures) do
        if hf.name.has_name and hf_named(hf, name) then subject_cache[name] = hf return hf end
    end
    subject_cache[name] = false
end

local function race_name(race, plural)
    local raw = df.creature_raw.find(race)
    return raw and raw.name[plural and 1 or 0] or 'creature'
end

local function hf_story(hf)
    local bits = {}
    local race = race_name(hf.race)
    local prof = hf.profession ~= -1 and df.profession.attrs[hf.profession].caption or nil
    local who = (race:match('^[aeiou]') and 'an ' or 'a ') .. race
    if prof and prof ~= '' and prof:lower() ~= 'peasant' and prof:lower() ~= 'child' then who = who .. ' ' .. prof:lower() end
    local civ = hf.civ_id ~= -1 and df.historical_entity.find(hf.civ_id)
    local ours = hf.civ_id == df.global.plotinfo.civ_id
    if civ and not ours then
        who = who .. ' of ' .. dfhack.df2utf(dfhack.translation and dfhack.translation.translateName(civ.name, true) or dfhack.TranslateName(civ.name, true))
    end
    bits[#bits + 1] = (hf.born_year >= 0 and ('%s, born in the year %d'):format(who, hf.born_year) or who)
    if hf.died_year >= 0 then
        local how
        local u = df.unit.find(hf.unit_id)
        local inc = u and u.counters.death_id >= 0 and df.incident.find(u.counters.death_id)
        if inc then
            local k = inc.criminal ~= -1 and df.unit.find(inc.criminal)
            if k then
                local khf = k.hist_figure_id ~= -1 and df.historical_figure.find(k.hist_figure_id)
                local kn = khf and name_of_hf(khf) or ''
                local kr = race_name(k.race)
                how = 'killed by ' .. (kn ~= '' and (kn .. ', a ' .. kr) or ((kr:match('^[aeiou]') and 'an ' or 'a ') .. kr))
            end
        end
        bits[#bits + 1] = ('who died in the year %d%s'):format(hf.died_year, how and (', ' .. how) or '')
    elseif hf.unit_id ~= -1 then
        local u = df.unit.find(hf.unit_id)
        if u and dfhack.units.isCitizen(u) then bits[#bits + 1] = 'still living here among us'
        else bits[#bits + 1] = 'still alive somewhere in the world' end
    end
    local kills = 0
    pcall(function() kills = #hf.info.kills.killed_race end)
    return table.concat(bits, ', ') .. '.'
end

local function creature_story(words)
    local w = words:gsub('^an? ', ''):lower()
    for _, raw in ipairs(df.global.world.raws.creatures.all) do
        for _, c in ipairs(raw.caste) do
            if c.caste_name[0]:lower() == w or c.caste_name[1]:lower() == w then
                if c.description ~= '' then return dfhack.df2utf(c.description) end
            end
        end
        if raw.name[0]:lower() == w or raw.name[1]:lower() == w then
            local c = raw.caste[0]
            if c and c.description ~= '' then return dfhack.df2utf(c.description) end
        end
    end
end

-- what the subject did: who they killed (named victims first), from history
local function deeds(hf)
    local k = hf.info and hf.info.kills
    if not k then return nil end
    local named = {}
    for _, evid in ipairs(k.events) do
        local ev = df.history_event.find(evid)
        if ev and ev:getType() == df.history_event_type.HIST_FIGURE_DIED then
            local v = df.historical_figure.find(ev.victim_hf)
            if v then named[#named + 1] = name_of_hf(v, true):gsub(' the .*$', '') end
        end
    end
    local others = 0
    for _, c in ipairs(k.killed_count) do others = others + c end
    local total = #named + others
    if total == 0 then return nil end
    local list = {table.unpack(named, 1, math.min(4, #named))}
    local text = ('In life %s killed %d %s'):format(name_of_hf(hf, true):match('^(%S+)'), total, total == 1 and 'creature' or 'creatures')
    if #list > 0 then text = text .. ', among them ' .. table.concat(list, ', ') .. (#named > #list and ' and others' or '') end
    return text .. '.'
end

-- the scene the game would show: who struck the subject down, from history
local function scene_from_history(hf)
    if hf.died_year < 0 then return nil end
    local u = df.unit.find(hf.unit_id)
    local inc = u and u.counters.death_id >= 0 and df.incident.find(u.counters.death_id)
    local k = inc and inc.criminal ~= -1 and df.unit.find(inc.criminal)
    local khf = k and k.hist_figure_id ~= -1 and df.historical_figure.find(k.hist_figure_id)
    if not khf then return nil end
    local a, b = name_of_hf(khf, true):gsub(' the .*$', ''), name_of_hf(hf, true):gsub(' the .*$', '')
    return ('The artwork relates to the death of %s at the hands of %s in the year %d.'):format(b, a, hf.died_year)
end

-- a statue building -> {item, subject, story, maker, quality, ...}
function statue_card(b)
    local it = b and b.contained_items[0] and b.contained_items[0].item
    if not it then return nil end
    local subject = dfhack.df2utf(it.description or '')
    local story, kind, deed, relates
    -- the full scene, only if the game happens to have it loaded; never fatal
    local okd, text = pcall(function() return describe_image(image_of(it)) end)
    if not okd then text = nil end
    if subject ~= '' then
        local hf = find_hf_by_name(subject)
        if hf then
            story, kind = subject .. ' was ' .. hf_story(hf), 'figure'
            deed = deeds(hf)
            relates = scene_from_history(hf)
        else
            story, kind = creature_story(subject), 'creature'
        end
    end
    local maker = it.maker ~= -1 and df.historical_figure.find(it.maker)
    local maker_job
    local mu = maker and df.unit.find(maker.unit_id)
    if mu then maker_job = dfhack.df2utf(dfhack.units.getProfessionName(mu)):lower() end
    -- how many statues of the same subject the fort has (the masons have favourites)
    local same = 0
    if subject ~= '' then
        for _, o in ipairs(df.global.world.items.other.STATUE) do
            if o.description == it.description then same = same + 1 end
        end
    end
    local mat = dfhack.matinfo.decode(it)
    local desc = dfhack.df2utf(dfhack.items.getDescription(it, 0, true))
    local marks = '[%-%+%*' .. string.char(0xe2, 0x89, 0xa1, 0xe2, 0x98, 0xbc) .. ']'
    desc = desc:gsub('^[%-%+%*\226\137\161\226\152\188]+', ''):gsub('[%-%+%*\226\137\161\226\152\188]+$', '')
    return {
        id = b.id,
        item = desc,
        subject = subject ~= '' and subject or nil,
        story = story,
        scene = text,
        kind = kind,
        material = mat and mat:toString() or nil,
        quality = QUALITY[it.quality] or '',
        maker = maker and name_of_hf(maker) or nil,
        maker_job = maker_job,
        value = dfhack.items.getValue(it),
        deeds = deed,
        relates = relates,
        copies = same,
        pos = {x = b.centerx, y = b.centery, z = b.z},
    }
end

if dfhack_flags and dfhack_flags.module then return end
for _, b in ipairs(df.global.world.buildings.other.STATUE) do
    local c = statue_card(b)
    if c then print(('%d @%d,%d,%d  %s (%s) by %s\n   %s'):format(c.id, c.pos.x, c.pos.y, c.pos.z, c.item, c.quality, tostring(c.maker), tostring(c.story))) end
end
