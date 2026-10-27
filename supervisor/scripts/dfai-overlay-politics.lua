-- dfai-overlay-politics: local, military and world politics plus the fort's work orders, for the Herald.
-- Read-only and bounded: every loop has a hard cap (an endless loop here freezes the game).
local json = require('json')
local tr = dfhack.translation and dfhack.translation.translateName or dfhack.TranslateName
local p, w = df.global.plotinfo, df.global.world
local out = {ok = true, local_posts = {}, civ_posts = {}, squads = {}, relations = {}, orders = {}, crimes = {}, mandates = {}}

local function u(s) return s and s ~= '' and dfhack.df2utf(s) or nil end
local function safe(f, ...) local ok, v = pcall(f, ...) if ok then return v end return nil end
local function race_adj(race) local cr = race and race >= 0 and df.creature_raw.find(race) return cr and u(cr.name[2]) end
local function hfname(id)
  if type(id) ~= 'number' then return nil end
  local h = id >= 0 and df.historical_figure.find(id)
  if not h then return nil end
  return {name = u(tr(h.name, false)), english = u(tr(h.name, true)), race = race_adj(h.race), id = id,
          here = safe(function() return df.unit.find(h.unit_id) ~= nil end) or false}
end
local function posts(ent, max)
  local res = {}
  if not ent then return res end
  local P = ent.positions
  for i = 0, math.min(#P.assignments - 1, 60) do
    local a = P.assignments[i]
    local pos
    for j = 0, math.min(#P.own - 1, 120) do if P.own[j].id == a.position_id then pos = P.own[j] break end end
    if pos then
      local title = u(pos.name[0]) or u(pos.name_male[0]) or u(pos.code)
      res[#res + 1] = {title = title and title:lower() or '?', code = pos.code, holder = hfname(a.histfig), squad = a.squad_id >= 0 or nil}
      if #res >= max then break end
    end
  end
  return res
end
local gov, civ = df.historical_entity.find(p.group_id), df.historical_entity.find(p.civ_id)
out.government = gov and u(tr(gov.name, true))
out.civ = civ and {name = u(tr(civ.name, true)), race = race_adj(civ.race)}
out.local_posts = posts(gov, 30)
out.civ_posts = posts(civ, 12)

-- military: our squads, members, vacancies, current orders
local all = w.squads.all
for i = 0, math.min(#all - 1, 400) do
  local s = all[i]
  if s.entity_id == p.group_id then
    local sq = {id = s.id, abroad = s.assigned_army_controller_id ~= -1, name = u(tr(s.name, true)), dwarvish = u(tr(s.name, false)), alias = u(s.alias), members = {}, vacancies = 0, orders = {}}
    for j = 0, math.min(#s.positions - 1, 12) do
      local sp = s.positions[j]
      if sp.occupant >= 0 then
        local h = hfname(sp.occupant)
        if h then
          local unit = safe(function() return df.unit.find(df.historical_figure.find(sp.occupant).unit_id) end)
          h.profession = unit and u(dfhack.units.getProfessionName(unit)) or nil
          h.alive = unit and not dfhack.units.isDead(unit) or (unit == nil and nil)
          h.kills = safe(function()
            local k = df.historical_figure.find(sp.occupant).info.kills
            local n = 0
            if k then for x = 0, math.min(#k.killed_count - 1, 200) do n = n + k.killed_count[x] end end
            return n
          end) or 0
          h.leader = (j == 0) or nil
          sq.members[#sq.members + 1] = h
        end
      else
        sq.vacancies = sq.vacancies + 1
      end
    end
    for j = 0, math.min(#s.orders - 1, 6) do
      local t = safe(function() return df.squad_order_type[s.orders[j]:getType()] end)
      if t then sq.orders[#sq.orders + 1] = t end
    end
    sq.routine = safe(function() return u(p.alerts.routines[s.cur_routine_idx].name) end)
    out.squads[#out.squads + 1] = sq
    if #out.squads >= 12 then break end
  end
end

-- world politics: how our civilization stands with everyone it knows
if civ then
  local st = civ.relations.diplomacy.state
  for i = 0, math.min(#st - 1, 80) do
    local d = st[i]
    local e = df.historical_entity.find(d.group_id)
    local rel = df.diplomacy_state_type[d.relation]
    if e and rel and rel ~= 'NoContact' then
      out.relations[#out.relations + 1] = {name = u(tr(e.name, true)), race = race_adj(e.race), kind = df.historical_entity_type[e.type], relation = rel}
    end
  end
end

-- work orders from the manager
local mo = w.manager_orders.all
for i = 0, math.min(#mo - 1, 80) do
  local o = mo[i]
  local job = o.reaction_name ~= '' and u(o.reaction_name) or safe(function() return df.job_type.attrs[o.job_type].caption end) or df.job_type[o.job_type]
  local mat = (o.mat_type >= 0) and safe(function() return dfhack.matinfo.decode(o.mat_type, o.mat_index):toString() end) or nil
  out.orders[#out.orders + 1] = {job = job, material = u(mat), left = o.amount_left, total = o.amount_total,
    frequency = df.workquota_frequency_type and df.workquota_frequency_type[o.frequency] or nil}
end

-- justice: the latest crimes on file
local cr = w.crimes.all
for i = #cr - 1, math.max(0, #cr - 8), -1 do
  local c = cr[i]
  out.crimes[#out.crimes + 1] = {kind = safe(function() return df.crime_type[c.mode] end) or tostring(c.mode),
    criminal = hfname(safe(function() return c.criminal_hf.hfid end)) or hfname(safe(function() return df.unit.find(c.criminal).hist_figure_id end)),
    victim = hfname(safe(function() return c.victim_hf.hfid end)) or hfname(safe(function() return df.unit.find(c.victim).hist_figure_id end)), discovered = c.discovered_year >= 0 or nil, year = c.event_year}
end

-- noble mandates
local md = w.mandates.all
for i = 0, math.min(#md - 1, 10) do
  local m = md[i]
  out.mandates[#out.mandates + 1] = {noble = m.unit and u(dfhack.units.getReadableName(m.unit)) or nil,
    mode = safe(function() return df.mandate_type[m.mode] end), item = df.item_type[m.item_type],
    material = (m.mat_type >= 0) and safe(function() return dfhack.matinfo.decode(m.mat_type, m.mat_index):toString() end) or nil,
    left = m.amount_remaining, total = m.amount_total}
end
out.petitions = #p.petitions
print(json.encode(out))
