-- dfai-overlay-rumors: news and rumors the fortress has learned (from diplomats, liaisons, caravans, visitors).
-- DF keeps them on the fort government's rumor_info (Civilizations/World Info screen). Prints JSON.
-- Read-only, bounded loops only: an endless loop here freezes the whole game.
local json = require('json')
local tr = dfhack.translation and dfhack.translation.translateName or dfhack.TranslateName
local p = df.global.plotinfo
local out = {ok = true, rumors = {}, visits = {}, year = df.global.cur_year, tick = df.global.cur_year_tick}

local function u(s) return s and dfhack.df2utf(s) or nil end
local function race_of(race, plural)
  local cr = race and race >= 0 and df.creature_raw.find(race)
  return cr and u(cr.name[plural and 1 or 0]) or nil
end
local function race_adj(race)
  local cr = race and race >= 0 and df.creature_raw.find(race)
  return cr and u(cr.name[2]) or nil
end
local function ent(id)
  local e = id and id >= 0 and df.historical_entity.find(id)
  if not e then return nil end
  local n = tr(e.name, true)
  return {name = u(n ~= '' and n or nil), race = race_adj(e.race), kind = df.historical_entity_type[e.type]}
end
local function site(id)
  local s = id and id >= 0 and df.world_site.find(id)
  if not s then return nil end
  return {name = u(tr(s.name, true)), dwarvish = u(tr(s.name, false)), kind = df.world_site_type[s.type]}
end
local function hf(id)
  local h = id and id >= 0 and df.historical_figure.find(id)
  if not h then return nil end
  -- people go by their own-language name ("Ngumrash Ensebrab"); the English one is a translation
  local n, en = tr(h.name, false), tr(h.name, true)
  return {name = u(n ~= '' and n or nil), english = u(en ~= '' and en or nil), race = race_of(h.race)}
end
local function region(id)
  local regs = df.global.world.world_data.regions
  local r = id and id >= 0 and id < #regs and regs[id]
  if not r then return nil end
  return {name = u(tr(r.name, true))}
end
local function artifact(id)
  local a = id and id >= 0 and df.artifact_record.find(id)
  if not a then return nil end
  local item = a.item and dfhack.items.getDescription(a.item, 0, true) or nil
  return {name = u(tr(a.name, true)), item = u(item)}
end

local gov = df.historical_entity.find(p.group_id)
local evs = gov and gov.rumor_info and gov.rumor_info.events
if evs then
  -- newest-learned first
  local idx = {}
  for i = 0, #evs - 1 do idx[#idx + 1] = i end
  table.sort(idx, function(a, b)
    local x, y = evs[a], evs[b]
    if x.valid_year ~= y.valid_year then return x.valid_year > y.valid_year end
    return x.valid_year_tick > y.valid_year_tick
  end)
  -- newest 80, plus the newest of every other type so rare news still surfaces
  local pickset, have = {}, {}
  for n = 1, #idx do
    local x = evs[idx[n]]
    if n <= 80 or not have[x.type] then pickset[#pickset + 1] = idx[n]; have[x.type] = true end
    if #pickset >= 120 then break end
  end
  for n = 1, #pickset do
    local x = evs[pickset[n]]
    local t = df.entity_event_type[x.type]
    local d = t and x.data[t]
    local r = {type = t, learned = {x.valid_year, x.valid_year_tick}, happened = {x.year, x.year_tick}, outmoded = x.flag.outmoded}
    if d then
      local f = function(k) local ok, v = pcall(function() return d[k] end) return ok and v or nil end
      r.site = site(f('site_id') or f('from_site_id'))
      r.entity = ent(f('entity_id') or f('entity1_id') or f('reclaimer_entity_id') or f('army_entity_id') or f('refugee_entity_id'))
      r.entity2 = ent(f('evicted_entity_id') or f('entity2_id') or f('parent_entity_id') or f('behalf_entity_id') or f('refugee_entity_id'))
      r.hf = hf(f('histfig_id') or f('leader_hf') or f('attack_leader_hf') or f('army_leader_hf_id') or f('civ_leader_hf') or f('histfig1_id') or f('hist_figure_id'))
      r.hf2 = hf(f('former_histfig_id') or f('abductor_id') or f('attack_commander_hf') or f('histfig2_id') or f('civ_commander_hf'))
      r.region = region(f('region_id'))
      r.artifact = artifact(f('artifact_id'))
      if t == 'beast' and r.hf then r.beast = r.hf end
      if t == 'insurrection_end' then r.result = f('result') end
    end
    out.rumors[#out.rumors + 1] = r
  end
end

-- who brought news, and when: diplomat/liaison meetings and caravans
for i = 0, math.min(#p.dip_meeting_info - 1, 20) do
  local m = p.dip_meeting_info[i]
  local e0 = m.events[0]
  local who = hf(m.diplomat_id) or {}
  local un = df.unit.find(m.diplomat_id)
  out.visits[#out.visits + 1] = {kind = 'diplomat', civ = ent(m.civ_id), who = who.name, race = who.race,
    year = e0 and e0.year or nil, tick = e0 and e0.ticks or nil}
end
for i = 0, math.min(#p.caravans - 1, 20) do
  local c = p.caravans[i]
  out.visits[#out.visits + 1] = {kind = 'caravan', civ = ent(c.entity), year = df.global.cur_year,
    here = c.time_remaining > 0}
end
print(json.encode(out))
