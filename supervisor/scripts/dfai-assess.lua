-- aitest-assess: one-shot read-only fort assessment for retire/next-fort planning
local w = df.global.world
local civ = df.global.plotinfo.civ_id
local function line(...) print(table.concat({...}, '\t')) end
local function kv(t) local o = {} for k, v in pairs(t) do o[#o + 1] = k .. '=' .. v end table.sort(o) return table.concat(o, ' ') end

line('date', df.global.cur_year, df.global.cur_year_tick, 'fps', df.global.enabler.calculated_fps)
local cit = dfhack.units.getCitizens(true)
line('citizens', #cit)

local dead, causes = 0, {}
for _, u in ipairs(w.units.all) do
  if u.civ_id == civ and dfhack.units.isDead(u) and dfhack.units.isDwarf(u) then
    dead = dead + 1
    local inc = df.incident.find(u.counters.death_id)
    local c = inc and df.death_type[inc.death_cause] or '?'
    causes[c] = (causes[c] or 0) + 1
  end
end
line('dead dwarves', dead, kv(causes))

local st, mil, idle = {}, 0, 0
for _, u in ipairs(cit) do
  local s = u.status.current_soul and u.status.current_soul.personality.stress or 0
  local b = s > 50000 and 'breaking' or s > 25000 and 'very' or s > 10000 and 'stressed' or 'ok'
  st[b] = (st[b] or 0) + 1
  if u.military.squad_id ~= -1 then mil = mil + 1 end
  if not u.job.current_job then idle = idle + 1 end
end
line('stress', kv(st)); line('military', mil, 'idle now', idle)

local m = {}
for _, b in ipairs(w.buildings.all) do local t = df.building_type[b:getType()]; m[t] = (m[t] or 0) + 1 end
line('buildings', kv(m))
local z = {}
for _, b in ipairs(w.buildings.other.ACTIVITY_ZONE) do local t = df.civzone_type[b.type]; z[t] = (z[t] or 0) + 1 end
line('zones', kv(z))

local inv = 0
for _, u in ipairs(w.units.active) do if dfhack.units.isInvader(u) then inv = inv + 1 end end
line('invaders active', inv, 'active units', #w.units.active, 'items', #w.items.all)

-- stress causes: top negative thoughts across citizens
local th = {}
for _, u in ipairs(cit) do
  local soul = u.status.current_soul
  if soul then
    for _, e in ipairs(soul.personality.emotions) do
      if e.strength > 0 and e.type >= 0 and df.emotion_type.attrs[e.type].divider > 0 then
      end
      local name = df.unit_thought_type[e.thought] or tostring(e.thought)
      local emo = df.emotion_type[e.type] or '?'
      local neg = ({ANGER=1,ANGUISH=1,ANNOYANCE=1,BITTERNESS=1,DESPAIR=1,DISAPPOINTMENT=1,DISGUST=1,DISMAY=1,DISTRESS=1,FEAR=1,FRUSTRATION=1,GRIEF=1,GRUMPINESS=1,HORROR=1,IRRITATION=1,LONELINESS=1,MISERY=1,REGRET=1,SADNESS=1,SHAME=1,TERROR=1,UNEASINESS=1,EMBARRASSMENT=1,DEJECTION=1,PANIC=1,RAGE=1,HOPELESSNESS=1,INSULT=1,VEXATION=1,REPENTANCE=1,AGONY=1,WRATH=1,ALARM=1})[emo]
      if neg then th[name] = (th[name] or 0) + 1 end
    end
  end
end
local arr = {}
for k, v in pairs(th) do arr[#arr + 1] = {k, v} end
table.sort(arr, function(a, b) return a[2] > b[2] end)
local o = {} for i = 1, math.min(12, #arr) do o[#o + 1] = arr[i][1] .. '=' .. arr[i][2] end
line('top bad thoughts', table.concat(o, ' '))

-- food/drink
local function count(id, f) local n = 0 for _, it in ipairs(w.items.other[id]) do if not f or f(it) then n = n + it:getStackSize() end end return n end
line('food', 'meals', count('FOOD'), 'drinks', count('DRINK'), 'meat', count('MEAT'), 'fish', count('FISH') + count('FISH_RAW'), 'plants', count('PLANT'), 'seeds', count('SEEDS'))

-- site position for the "close by" next embark
local site = w.world_data.active_site[0]
line('site', dfhack.translation.translateName(site.name, true), 'region pos', site.pos.x, site.pos.y, 'world', dfhack.translation.translateName(w.world_data.name, true), 'save', w.cur_savegame.save_dir)
