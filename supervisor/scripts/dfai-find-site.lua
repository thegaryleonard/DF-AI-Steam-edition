-- dfai-find-site: find a spot for a multi-level quickfort project.
-- usage: dfai-find-site <w> <h> <depth> <cx> <cy> <cz> [<reserved rects file>]
-- Searches outward from (cx,cy) on surface level cz for a w x h footprint
-- whose top level is flat, open-sky, building/water/tree-free floor and whose
-- next <depth> levels are solid wall (so the project digs into virgin ground).
-- The optional file lists reserved rectangles, one "x1 y1 z1 x2 y2 z2" per
-- line (df-ai's planned rooms), which the footprint must not overlap.
-- Prints "SITE x y z" (top-left of the footprint, top level) or "NOSITE".
local args = {...}
local w, h, depth = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
local cx, cy, cz = tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
local reserved = {}
if args[7] then
  local f = io.open(args[7])
  if f then
    for line in f:lines() do
      local a = {}
      for n in line:gmatch('-?%d+') do a[#a + 1] = tonumber(n) end
      if #a == 6 then reserved[#reserved + 1] = a end
    end
    f:close()
  end
end

local function shape(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  if not tt then return nil end
  return df.tiletype_shape.attrs[df.tiletype.attrs[tt].shape].basic_shape
end

local function natural_wall(x, y, z)
  if shape(x, y, z) ~= df.tiletype_shape_basic.Wall then return false end
  local flags = dfhack.maps.getTileFlags(x, y, z)
  if not flags or flags.water_table then return false end
  local mat = df.tiletype.attrs[dfhack.maps.getTileType(x, y, z)].material
  return mat ~= df.tiletype_material.CONSTRUCTION and mat ~= df.tiletype_material.FEATURE
     and mat ~= df.tiletype_material.TREE
end

local function top_ok(x, y, z)
  -- a hillside wall with open sky above is fine too: quickfort digs it to a sky-lit floor
  if natural_wall(x, y, z) then
    local above = shape(x, y, z + 1)
    return above == nil or above == df.tiletype_shape_basic.Open
  end
  if shape(x, y, z) ~= df.tiletype_shape_basic.Floor then return false end
  local flags, occ = dfhack.maps.getTileFlags(x, y, z)
  if not flags or not flags.outside or flags.flow_size > 0 or flags.liquid_type then return false end
  if occ and occ.building ~= 0 then return false end
  local tt = dfhack.maps.getTileType(x, y, z)
  local mat = df.tiletype.attrs[tt].material
  if mat == df.tiletype_material.TREE or mat == df.tiletype_material.PLANT and df.tiletype.attrs[tt].shape == df.tiletype_shape.SAPLING then return false end
  -- open sky above (nothing built over it)
  local above = shape(x, y, z + 1)
  return above == nil or above == df.tiletype_shape_basic.Open
end

local function solid(x, y, z)
  if shape(x, y, z) ~= df.tiletype_shape_basic.Wall then return false end
  local flags = dfhack.maps.getTileFlags(x, y, z)
  if flags and flags.water_table then return false end   -- aquifer
  local tt = dfhack.maps.getTileType(x, y, z)
  local mat = df.tiletype.attrs[tt].material
  return mat ~= df.tiletype_material.CONSTRUCTION and mat ~= df.tiletype_material.FEATURE
end

local function overlaps(x1, y1, z1, x2, y2, z2)
  for _, r in ipairs(reserved) do
    if x1 <= r[4] and x2 >= r[1] and y1 <= r[5] and y2 >= r[2] and z1 <= r[6] and z2 >= r[3] then
      return true
    end
  end
  return false
end

local function fits(x0, y0)
  if overlaps(x0 - 1, y0 - 1, cz - depth, x0 + w, y0 + h, cz) then return false end
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      if not top_ok(x, y, cz) then return false end
      for d = 1, depth do
        if not solid(x, y, cz - d) then return false end
      end
    end
  end
  return true
end

local mx, my = df.global.world.map.x_count, df.global.world.map.y_count
for r = 0, math.max(mx, my) do
  for dy = -r, r do
    for dx = -r, r do
      if math.max(math.abs(dx), math.abs(dy)) == r then
        local x0, y0 = cx + dx - w // 2, cy + dy - h // 2
        if x0 >= 2 and y0 >= 2 and x0 + w < mx - 2 and y0 + h < my - 2 and fits(x0, y0) then
          print(('SITE %d %d %d'):format(x0, y0, cz))
          return
        end
      end
    end
  end
end
print('NOSITE')
