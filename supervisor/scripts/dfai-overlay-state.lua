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
    month = months[tick // 33600 + 1],
    day = (tick % 33600) // 1200 + 1,
    population = #citizens,
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
  out.names = {}   -- citizen names for the Herald's letters and bylines
  for i = 1, math.min(#citizens, 60) do
    out.names[i] = dfhack.df2utf(dfhack.units.getReadableName(citizens[i])):gsub(',.*$', ''):gsub('%s*"[^"]*"', '')
  end
  out.events = {}
  local reps = df.global.world.status.reports
  for i = #reps - 1, math.max(0, #reps - 40), -1 do
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
print(json.encode(out))
