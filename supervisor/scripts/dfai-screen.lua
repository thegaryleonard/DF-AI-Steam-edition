-- dfai-screen: read or click on-screen text (works at any window size).
--   dfai-screen dump            print every row that has text
--   dfai-screen click <text>    left-click the first occurrence of <text>
--   dfai-screen find <text>     print "FOUND x y" or "NOTFOUND"
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

local function find(text)
  for y = 0, gps.dimy - 1 do
    local x = row(y):find(text, 1, true)
    if x then return x - 1 + #text // 2, y end
  end
end

local function click(tx, ty)
  local tw, th = gps.screen_pixel_x // gps.dimx, gps.screen_pixel_y // gps.dimy
  gps.mouse_x, gps.mouse_y = tx, ty
  gps.precise_mouse_x, gps.precise_mouse_y = tx * tw + tw // 2, ty * th + th // 2
  local e = df.global.enabler
  e.mouse_lbut, e.mouse_lbut_down = 1, 1
  require('gui').simulateInput(dfhack.gui.getCurViewscreen(), '_MOUSE_L')
  e.mouse_lbut, e.mouse_lbut_down = 0, 0
end

local cmd, text = args[1], table.concat(args, ' ', 2)
if cmd == 'dump' then
  for y = 0, gps.dimy - 1 do
    local l = row(y)
    if l:find('%S') then print(y, (l:gsub('%s+$', ''))) end
  end
elseif cmd == 'find' or cmd == 'click' then
  local x, y = find(text)
  if not x then print('NOTFOUND ' .. text) return end
  if cmd == 'click' then click(x, y) end
  print('FOUND ' .. x .. ' ' .. y)
else
  qerror('usage: dfai-screen dump | find <text> | click <text>')
end
