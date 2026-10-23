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
  local follow = df.unit.find(df.global.plotinfo.follow_unit)
  if not follow or not dfhack.units.isCitizen(follow) then
    -- rotate through citizens every ~2 minutes of wall time when nobody is followed
    follow = #citizens > 0 and citizens[(os.time() // 120) % #citizens + 1] or nil
  end
  out.dwarf = unit_card(follow)
  out.events = {}
  local reps = df.global.world.status.reports
  for i = #reps - 1, math.max(0, #reps - 40), -1 do
    local r = reps[i]
    local text = dfhack.df2utf(r.text)
    if r.flags.announcement and #out.events < 8 and not text:find(' cancels ') then
      out.events[#out.events + 1] = { text = text, year = r.year }
    end
  end
end
print(json.encode(out))
