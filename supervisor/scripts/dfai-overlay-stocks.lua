-- dfai-overlay-stocks: fortress resource levels for the overlay's
-- "Agriculture Report" card. Counts usable (not rotten, not traders',
-- not forbidden garbage) items by category. Read-only.
local json = require('json')
local T = df.item_type
local cat = {
  [T.MEAT] = 'meat', [T.FISH] = 'fish', [T.FISH_RAW] = 'fish',
  [T.PLANT] = 'plants', [T.PLANT_GROWTH] = 'plants', [T.FOOD] = 'meals',
  [T.CHEESE] = 'meals', [T.EGG] = 'eggs', [T.DRINK] = 'drinks', [T.SEEDS] = 'seeds',
  [T.WOOD] = 'wood', [T.BOULDER] = 'stone', [T.BLOCKS] = 'blocks', [T.BAR] = 'bars',
  [T.CLOTH] = 'cloth', [T.SKIN_TANNED] = 'leather', [T.THREAD] = 'thread',
  [T.ROUGH] = 'gems', [T.SMALLGEM] = 'gems',
}
local out = { ok = dfhack.isMapLoaded() }
if out.ok then
  local c = {}
  for _, i in ipairs(df.global.world.items.other.IN_PLAY) do
    local k = cat[i:getType()]
    if k then
      local f = i.flags
      if not (f.rotten or f.trader or f.garbage_collect or f.removed or f.dump or f.construction or f.hidden) then
        c[k] = (c[k] or 0) + i:getStackSize()
      end
    end
  end
  out.stocks = c
  out.farms = #df.global.world.buildings.other.FARM_PLOT
  local animals = {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isOwnCiv(u) and dfhack.units.isAnimal(u) and not dfhack.units.isDead(u) then
      local r = df.creature_raw.find(u.race)
      local n = r and r.name[1] or '?'
      animals[n] = (animals[n] or 0) + 1
    end
  end
  out.animals = animals
end
print(json.encode(out))
