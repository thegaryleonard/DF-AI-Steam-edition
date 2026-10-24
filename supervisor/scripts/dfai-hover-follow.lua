-- dfai-hover-follow: keep spectate's hover panel up on the unit being followed.
-- The panel only shows for the unit under the mouse, so while the camera is
-- following someone we park the game's mouse on that unit. A real mouse move
-- (the user taking over) suspends this for a couple of minutes.
--   dfai-hover-follow start | stop | status
--@ module = true
local GLOBAL_KEY = 'dfai-hover-follow'
local TICK_FRAMES = 6
local USER_PAUSE_MS = 120000

state = state or {running = false, ours = nil, user_until = 0}

local gps = df.global.gps

local function set_mouse_px(px, py)
  local tw, th = gps.screen_pixel_x // gps.dimx, gps.screen_pixel_y // gps.dimy
  gps.precise_mouse_x, gps.precise_mouse_y = px, py
  gps.mouse_x, gps.mouse_y = px // tw, py // th
end

local function map_at_px(px, py)
  set_mouse_px(px, py)
  return dfhack.gui.getMousePos()
end

-- find the screen pixel over map tile (x, y): sample the mapping at two
-- points per axis (it is linear within the viewport) and solve
local function pixel_for(x, y)
  local cx, cy = gps.screen_pixel_x // 2, gps.screen_pixel_y // 2
  local a = map_at_px(cx, cy)
  local b = map_at_px(cx + 200, cy + 200)
  if not a or not b or b.x == a.x or b.y == a.y then return nil end
  local sx, sy = 200 / (b.x - a.x), 200 / (b.y - a.y)          -- pixels per map tile
  local px = math.floor(cx + (x - a.x) * sx + sx / 2)
  local py = math.floor(cy + (y - a.y) * sy + sy / 2)
  if px < 0 or py < 0 or px >= gps.screen_pixel_x or py >= gps.screen_pixel_y then return nil end
  return px, py
end

local function tick()
  if not state.running then return end
  dfhack.timeout(TICK_FRAMES, 'frames', tick)
  if not dfhack.isMapLoaded() or not dfhack.gui.matchFocusString('dwarfmode/Default') then return end
  local now = dfhack.getTickCount()
  -- someone moved the real mouse since our last placement: back off
  if state.ours and (gps.precise_mouse_x ~= state.ours[1] or gps.precise_mouse_y ~= state.ours[2]) then
    state.user_until = now + USER_PAUSE_MS
    state.ours = nil
  end
  if now < state.user_until then return end
  local u = df.unit.find(df.global.plotinfo.follow_unit)
  if not u then state.ours = nil return end
  local px, py = pixel_for(u.pos.x, u.pos.y)
  if not px then state.ours = nil return end
  set_mouse_px(px, py)
  state.ours = {px, py}
end

if dfhack_flags and dfhack_flags.module then return end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
  if not state.running then
    state.running = true
    state.ours, state.user_until = nil, 0
    tick()
  end
  print('dfai-hover-follow: running')
elseif cmd == 'stop' then
  state.running = false
  print('dfai-hover-follow: stopped')
else
  print('dfai-hover-follow: ' .. (state.running and 'running' or 'stopped'))
end
