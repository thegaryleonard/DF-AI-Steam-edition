-- dfai-overlay-state: print one JSON snapshot of the fort for the stream overlay.
-- Read-only and cheap (no history scans); history/artifact data is cached
-- separately by dfai-overlay-history.
local json = require('json')

local function name_of(hfname, english)
  return dfhack.df2utf(dfhack.translation.translateName(hfname, english or false))
end

local function unit_card(u)
  if not u then return nil end
  local soul = u.status.current_soul
  local card = {
    id = u.id,
    name = dfhack.df2utf(dfhack.units.getReadableName(u)),
    profession = dfhack.df2utf(dfhack.units.getProfessionName(u)),
    age = math.floor(dfhack.units.getAge(u) or 0),
    stress = soul and soul.personality.stress or 0,
    job = u.job.current_job and dfhack.df2utf(dfhack.job.getName(u.job.current_job)) or 'Idle',
    skills = {}, thoughts = {}, family = {},
  }
  if soul then
    local sk = {}
    for _, s in ipairs(soul.skills) do
      if s.rating > 0 then
        sk[#sk + 1] = { name = df.job_skill.attrs[s.id].caption_noun, level = s.rating }
      end
    end
    table.sort(sk, function(a, b) return a.level > b.level end)
    for i = 1, math.min(5, #sk) do card.skills[i] = sk[i] end
    local em = soul.personality.emotions
    for i = #em - 1, math.max(0, #em - 12), -1 do
      local e = em[i]
      if e.type ~= df.emotion_type.ANYTHING and e.thought ~= -1 then card.thoughts[#card.thoughts + 1] = {
        emotion = df.emotion_type[e.type] or '?',
        about = df.unit_thought_type[e.thought] or '?',
        strength = e.strength,
      } end
    end
  end
  -- extras for the spectator card (bottom of the broadsheet)
  card.race = dfhack.df2utf(dfhack.units.getRaceReadableName and dfhack.units.getRaceReadableName(u) or '')
  card.male = u.sex == 1
  card.citizen = dfhack.units.isCitizen(u)
  -- creatures off the street (forgotten beasts above all): their physical description
  if not card.citizen then
    local raw = df.creature_raw.find(u.race)
    local caste = raw and raw.caste[u.caste]
    if caste and caste.description ~= '' then card.description = dfhack.df2utf(caste.description) end
    if dfhack.units.isForgottenBeast and dfhack.units.isForgottenBeast(u) then card.race = 'Forgotten Beast'
    elseif dfhack.units.isGreatDanger(u) then card.danger = true end
  end
  -- only wounds that still hurt or bleed (old healed scars stay in body.wounds)
  card.wounds = 0
  for _, w in ipairs(u.body.wounds) do
    local live = false
    for _, wp in ipairs(w.parts) do if (wp.bleeding or 0) > 0 or (wp.pain or 0) > 0 then live = true end end
    if live then card.wounds = card.wounds + 1 end
  end
  card.unconscious = u.flags1.has_mood == false and (u.counters.unconscious or 0) > 0
  card.hungry = (u.counters2.hunger_timer or 0) > 50000
  card.thirsty = (u.counters2.thirst_timer or 0) > 25000
  card.tired = (u.counters2.sleepiness_timer or 0) > 57600
  card.strange_mood = (u.mood ~= -1 and df.mood_type[u.mood]) or nil
  local sq = df.squad.find(u.military.squad_id)
  card.squad = sq and dfhack.df2utf(dfhack.translation and dfhack.translation.translateName(sq.name, true) or dfhack.TranslateName(sq.name, true)) or nil
  if sq and sq.alias ~= '' then card.squad = dfhack.df2utf(sq.alias) end
  if sq and (card.squad == nil or card.squad == '') then card.squad = 'Squad ' .. sq.id end
  card.needs = {}
  if soul then
    local nd = {}
    for _, n in ipairs(soul.personality.needs) do
      if n.focus_level < -1000 then
        local label = df.need_type[n.id] or '?'
        if n.id == df.need_type.PrayOrMeditate then
          local d = df.historical_figure.find(n.deity_id)
          label = d and ('Pray to ' .. name_of(d.name, false)) or 'Pray or meditate'
        end
        nd[#nd + 1] = { name = label, focus = n.focus_level }  -- name_of already returns UTF-8
      end
    end
    table.sort(nd, function(a, b) return a.focus < b.focus end)
    for i = 1, math.min(4, #nd) do card.needs[i] = nd[i].name end
  end
  local hf = df.historical_figure.find(u.hist_figure_id)
  if hf then
    card.born = hf.born_year
    for _, l in ipairs(hf.histfig_links) do
      local o = df.historical_figure.find(l.target_hf)
      card.family[#card.family + 1] = {
        relation = df.histfig_hf_link_type[l:getType()],
        name = o and name_of(o.name, true) or '?',
        alive = o and o.died_year == -1 or false,
      }
    end
  end
  return card
end

local out = { ok = dfhack.isMapLoaded() }
if out.ok then
  local site = df.global.world.world_data.active_site[0]
  local citizens = {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(u) then citizens[#citizens + 1] = u end
  end
  local months = { 'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
                   'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian' }
  local tick = df.global.cur_year_tick
  out.fort = {
    name = site and name_of(site.name, true) or '?',
    dwarvish = site and name_of(site.name, false) or '?',
    world = name_of(df.global.world.world_data.name, true),
    year = df.global.cur_year,
    tick = df.global.cur_year_tick,
    month = months[tick // 33600 + 1],
    day = (tick % 33600) // 1200 + 1,
    population = #citizens,
    age_days = df.global.plotinfo.fortress_age // 1200,   -- days since embark: running stories can't predate the fort
  }
  -- weather at the fort: current_weather is a 5x5 grid of none/rain/snow
  local wx = { rain = 0, snow = 0, clear = 0 }
  local cw = df.global.current_weather
  for x = 0, 4 do for y = 0, 4 do
    local v = cw[x][y]
    if v == df.weather_type.Rain then wx.rain = wx.rain + 1
    elseif v == df.weather_type.Snow then wx.snow = wx.snow + 1
    else wx.clear = wx.clear + 1 end
  end end
  local seasons = { 'Spring', 'Summer', 'Autumn', 'Winter' }
  local part = ({ 'Early ', 'Mid', 'Late ' })[(tick // 33600) % 3 + 1]
  out.weather = {
    kind = (wx.snow > wx.rain and wx.snow > 0) and 'snow' or (wx.rain > 0 and 'rain' or 'clear'),
    amount = math.max(wx.rain, wx.snow) / 25,
    season = part .. (part == 'Mid' and string.lower(seasons[tick // 100800 + 1]) or seasons[tick // 100800 + 1]),
  }
  local follow = df.unit.find(df.global.plotinfo.follow_unit)
  if not follow or not dfhack.units.isCitizen(follow) then
    -- rotate through citizens every ~2 minutes of wall time when nobody is followed
    follow = #citizens > 0 and citizens[(os.time() // 120) % #citizens + 1] or nil
  end
  out.dwarf = unit_card(follow)
  -- the room tour (dfai-room-tour) has the camera: show the room on the card
  local tour = rawget(_G, 'dfai_tour')
  if tour and tour.current then
    out.tour = { name = tour.current.name, kind = tour.current.kind, detail = tour.current.detail }
    if tour.current.statue then out.tour.statue = tour.current.statue end
    -- live facts for the On Camera card: who is here and what the workshop is making
    local okl, live = pcall(function()
      local p = tour.current.pos
      if not p then return nil end
      local L = { present = {}, people = 0, animals = 0 }
      local b = dfhack.buildings.findAtTile(p)
      if b and #b.jobs > 0 then
        local j = b.jobs[0]
        L.job = dfhack.df2utf(dfhack.job.getName(j))
        local w = dfhack.job.getWorker(j)
        if w then L.worker = dfhack.df2utf(dfhack.units.getReadableName(w)):gsub(',.*$', ''):gsub('%s*"[^"]*"', '') end
        L.queued = #b.jobs
      end
      for _, u in ipairs(df.global.world.units.active) do
        if u.pos.z == p.z and math.abs(u.pos.x - p.x) <= 7 and math.abs(u.pos.y - p.y) <= 7
            and dfhack.units.isAlive(u) and not dfhack.units.isHidden(u) then
          if dfhack.units.isCitizen(u) or dfhack.units.isVisitor(u) then
            L.people = L.people + 1
            if #L.present < 3 then
              local cj = u.job.current_job
              L.present[#L.present + 1] = {
                name = dfhack.df2utf(dfhack.units.getReadableName(u)):gsub(',.*$', ''):gsub('%s*"[^"]*"', ''),
                doing = cj and dfhack.df2utf(dfhack.job.getName(cj)) or nil }
            end
          elseif dfhack.units.isAnimal(u) then
            L.animals = L.animals + 1
          end
        end
      end
      return L
    end)
    if okl then out.tour.live = live end
  end
  -- the unit the spectator camera is actually following (any creature), for the on-camera card
  local cam = df.unit.find(df.global.plotinfo.follow_unit)
  if cam then
    local okc, c = pcall(unit_card, cam)
    out.followed = okc and c or { id = cam.id, name = dfhack.df2utf(dfhack.units.getReadableName(cam)) }
  end
  out.names = {}   -- citizen names for the Herald's letters and bylines
  for i = 1, math.min(#citizens, 60) do
    out.names[i] = dfhack.df2utf(dfhack.units.getReadableName(citizens[i])):gsub(',.*$', ''):gsub('%s*"[^"]*"', '')
  end
  out.events = {}
  local reps = df.global.world.status.reports
  -- scan well past combat spam (one fight can log hundreds of non-announcement reports)
  for i = #reps - 1, math.max(0, #reps - 2000), -1 do
    if #out.events >= 8 then break end
    local r = reps[i]
    local text = dfhack.df2utf(r.text)
    if r.flags.announcement and #out.events < 8 and not text:find(' cancels ') then
      out.events[#out.events + 1] = { text = text, year = r.year, type = df.announcement_type[r.type], id = r.id }
    end
  end
  -- big events for the Herald's illustrated "Breaking News" (deaths, sieges, moods, artifacts, migrants...)
  local BIG = {}
  for _, n in ipairs{'CITIZEN_DEATH','PET_DEATH','BERSERK_CITIZEN','CITIZEN_TANTRUM','POSSESSED_TANTRUM','STRANGE_MOOD',
      'ARTIFACT_BEGUN','MADE_ARTIFACT','NAMED_ARTIFACT','MEGABEAST_ARRIVAL','WEREBEAST_ARRIVAL','BEAST_AMBUSH','NIGHT_ATTACK_STARTS',
      'GHOST_ATTACK','BUILDING_TOPPLED_BY_GHOST','MIGRANT_ARRIVAL','MIGRANT_ARRIVAL_NAMED','D_MIGRANTS_ARRIVAL','CARAVAN_ARRIVAL',
      'FIRST_CARAVAN_ARRIVAL','BIRTH_CITIZEN','MARRIAGE','CAVE_COLLAPSE','STRUCK_DEEP_METAL','FEATURE_DISCOVERY',
      'MASTERPIECE_CRAFTED','SOLDIER_BECOMES_MASTER','AMBUSH_DEFENDER','AMBUSH_RESIDENT'} do BIG[n] = true end
  out.big = {}
  local seen_type = {}   -- newest one of each kind, so a run of masterpieces doesn't crowd out a death
  for i = #reps - 1, math.max(0, #reps - 300), -1 do
    local r = reps[i]
    if #out.big >= 6 then break end
    local tn = df.announcement_type[r.type]
    if r.flags.announcement and tn then
      local text = (BIG[tn] or tn:find('SIEGE') or tn:find('INVASION')) and dfhack.df2utf(r.text)
      if not text then
        -- sieges have no single announcement type; catch them by wording
        local t = dfhack.df2utf(r.text)
        if t:find('vile force') or t:find('siege') then text = t; tn = 'SIEGE' end
      end
      if text and not seen_type[tn] then
        seen_type[tn] = true
        out.big[#out.big + 1] = { id = r.id, type = tn, text = text, year = r.year, tick = r.time }
      end
    end
  end
end
-- the holiday (party mode): live numbers for the Herald's article and timer
if out.ok then
  local okh, hol = pcall(reqscript, 'dfai-holiday')
  if okh and hol.report then
    local okr, r = pcall(hol.report)
    if okr then out.holiday = r end
  end
end
print(json.encode(out))
