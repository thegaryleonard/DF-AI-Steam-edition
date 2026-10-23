-- dfai-overlay-world: one-time dump of the world map for the stream overlay.
-- Prints JSON {w, h, elev, rain, temp, veg, fort={x,y,name}, sites=[...]}.
-- Per-tile arrays are row-major (y * w + x). Read-only; run once per world.
local json = require('json')
local wd = df.global.world.world_data
local w, h = wd.world_width, wd.world_height
local elev, rain, temp, veg, water = {}, {}, {}, {}, {}
for y = 0, h - 1 do
  for x = 0, w - 1 do
    local r = wd.region_map[x]:_displace(y)
    local i = y * w + x + 1
    elev[i] = r.elevation
    rain[i] = r.rainfall
    temp[i] = r.temperature
    veg[i] = r.vegetation
    water[i] = (r.flags.has_river and 1 or 0) + (r.flags.is_lake and 2 or 0)
  end
end

local function tr(n) return dfhack.df2utf(dfhack.translation.translateName(n, true)) end

local fort
local site = wd.active_site[0]
if site then
  fort = { x = site.pos.x, y = site.pos.y, name = tr(site.name) }
end

-- notable sites (towns, fortresses, hamlets, dark fortresses...) for labels
local keep = { PlayerFortress = true, DarkFortress = true, Fortress = true, MountainHall = true,
               Town = true, ForestRetreat = true, Tower = true, Monastery = true, Castle = true }
local sites = {}
for _, s in ipairs(wd.sites) do
  local t = df.world_site_type[s.type]
  if keep[t] and #sites < 120 then
    sites[#sites + 1] = { x = s.pos.x, y = s.pos.y, name = tr(s.name), type = t }
  end
end

print(json.encode({
  w = w, h = h, elev = elev, rain = rain, temp = temp, veg = veg, water = water,
  fort = fort, sites = sites, world = tr(wd.name),
}))
