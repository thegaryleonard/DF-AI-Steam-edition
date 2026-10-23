-- dfai-overlay-history: one-time scan of world history for the stream overlay.
-- Prints JSON {artifacts=[{name, dwarvish, item, story=[sentences]}...]}.
-- Reads plain event fields only: never call history_event:getSentence with a
-- nil context, which crashes DF 53.
local json = require('json')
local tr = function(n, en) return dfhack.df2utf(dfhack.translation.translateName(n, en)) end
local function hf(id)
  local h = id and id >= 0 and df.historical_figure.find(id)
  return h and tr(h.name, true) or nil
end
local function site(id)
  local s = id and id >= 0 and df.world_site.find(id)
  return s and tr(s.name, true) or nil
end
local function ent(id)
  local e = id and id >= 0 and df.historical_entity.find(id)
  return e and tr(e.name, true) or nil
end
local function field(e, f)
  local ok, v = pcall(function() return e[f] end)
  return ok and type(v) == 'number' and v or nil
end

local T = df.history_event_type
local function sentence(e)
  local t = e:getType()
  local who = hf(field(e, 'histfig')) or hf(field(e, 'creator_hfid')) or ent(field(e, 'entity'))
  local where = site(field(e, 'site'))
  local at = where and (' at ' .. where) or ''
  if t == T.ARTIFACT_CREATED then
    return (who and (who .. ' created it') or 'It was created') .. at
  elseif t == T.ARTIFACT_STORED then
    return (who and (who .. ' stored it') or 'It was stored') .. at
  elseif t == T.ARTIFACT_LOST then
    return 'It was lost' .. at
  elseif t == T.ARTIFACT_FOUND then
    return (who and (who .. ' found it') or 'It was found') .. at
  elseif t == T.ARTIFACT_GIVEN then
    return 'It was given away' .. (who and (' by ' .. who) or '') .. at
  elseif t == T.ARTIFACT_POSSESSED then
    return (who and (who .. ' took possession of it') or 'Someone took possession of it') .. at
  elseif t == T.ARTIFACT_CLAIM_FORMED then
    return who and (who .. ' laid claim to it') or nil
  elseif t == T.ARTIFACT_DESTROYED then
    return 'It was destroyed' .. at
  elseif t == T.ARTIFACT_RECOVERED then
    return (who and (who .. ' recovered it') or 'It was recovered') .. at
  elseif t == T.ARTIFACT_COPIED then
    return 'A copy was made' .. at
  elseif t == T.ARTIFACT_TRANSFORMED then
    return 'It was transformed' .. at
  end
  return nil
end

local byart = {}
local ev = df.global.world.history.events
for i = 0, #ev - 1 do
  local e = ev[i]
  local a = field(e, 'artifact')
  if a and a >= 0 then
    byart[a] = byart[a] or {}
    table.insert(byart[a], e)
  end
end

local list = {}
for _, a in ipairs(df.global.world.artifacts.all) do
  if a.name.has_name and byart[a.id] then
    local story, claims, first, last = {}, 0, nil, nil
    for _, e in ipairs(byart[a.id]) do
      first = first or e.year
      last = e.year
      if e:getType() == T.ARTIFACT_CLAIM_FORMED then
        claims = claims + 1
      else
        local s = sentence(e)
        if s then story[#story + 1] = { year = e.year, text = s } end
      end
    end
    if claims > 0 then
      story[#story + 1] = { year = last, text = ('Claimed by ' .. claims .. ' different figures and powers between ' .. first .. ' and ' .. last) }
    end
    list[#list + 1] = {
      id = a.id,
      name = tr(a.name, true),
      dwarvish = tr(a.name, false),
      item = a.item and dfhack.df2utf(dfhack.items.getDescription(a.item, 0, true)) or '?',
      events = #byart[a.id],
      story = story,
    }
  end
end
table.sort(list, function(x, y) return x.events > y.events end)
local top = {}
for i = 1, math.min(40, #list) do top[i] = list[i] end
print(json.encode({ world = tr(df.global.world.world_data.name, true), artifacts = top }))
