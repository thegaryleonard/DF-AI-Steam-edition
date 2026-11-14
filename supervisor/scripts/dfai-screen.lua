-- dfai-screen: read or click on-screen text (works at any window size).
--   dfai-screen dump            print every row that has text
--   dfai-screen click <text>    left-click the first occurrence of <text>
--   dfai-screen clicklast <text> left-click the last (lowest) occurrence
--   dfai-screen find <text>     print "FOUND x y" or "NOTFOUND"
--   dfai-screen tile <x> <y>    left-click a screen tile (negative = from right/bottom)
--   dfai-screen rclick <x> <y>  right-click a screen tile ("Right click to abort")
--   dfai-screen size            tiles and pixels of the game window
local args = {...}
local gps = df.global.gps

local function row(y)
  local s = {}
  for x = 0, gps.dimx - 1 do
    local p = dfhack.screen.readTile(x, y)
    s[#s + 1] = (p and p.ch and p.ch >= 32 and p.ch < 127) and string.char(p.ch) or ' '
  end
  return table.concat(s)
end

local function find(text, last)
  local fx, fy
  for y = 0, gps.dimy - 1 do
    local x = row(y):find(text, 1, true)
    if x then
      fx, fy = x - 1 + #text // 2, y
      if not last then return fx, fy end
    end
  end
  return fx, fy
end

local function click(tx, ty, right)
  local tw, th = gps.screen_pixel_x // gps.dimx, gps.screen_pixel_y // gps.dimy
  gps.mouse_x, gps.mouse_y = tx, ty
  gps.precise_mouse_x, gps.precise_mouse_y = tx * tw + tw // 2, ty * th + th // 2
  local e = df.global.enabler
  if right then
    e.mouse_rbut, e.mouse_rbut_down = 1, 1
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(), '_MOUSE_R')
    e.mouse_rbut, e.mouse_rbut_down = 0, 0
  else
    e.mouse_lbut, e.mouse_lbut_down = 1, 1
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(), '_MOUSE_L')
    e.mouse_lbut, e.mouse_lbut_down = 0, 0
  end
end

local cmd, text = args[1], table.concat(args, ' ', 2)
if cmd == 'dump' then
  for y = 0, gps.dimy - 1 do
    local l = row(y)
    if l:find('%S') then print(y, (l:gsub('%s+$', ''))) end
  end
elseif cmd == 'find' or cmd == 'click' or cmd == 'clicklast' then
  local x, y = find(text, cmd == 'clicklast')
  if not x then print('NOTFOUND ' .. text) return end
  if cmd ~= 'find' then click(x, y) end
  print('FOUND ' .. x .. ' ' .. y)
elseif cmd == 'tile' or cmd == 'rclick' then
  -- click a screen tile: dfai-screen tile <x> <y>  (negative x/y count from the right/bottom)
  local x, y = tonumber(args[2]), tonumber(args[3])
  if x < 0 then x = gps.dimx + x end
  if y < 0 then y = gps.dimy + y end
  click(x, y, cmd == 'rclick')
  print('CLICKED ' .. x .. ' ' .. y)
elseif cmd == 'size' then
  print(gps.dimx, gps.dimy, gps.screen_pixel_x, gps.screen_pixel_y)
else
  qerror('usage: dfai-screen dump | find <text> | click <text> | tile <x> <y> | rclick <x> <y> | size')
end
