-- dfai-spectate-keeper: turn spectate back on when nobody is using the game.
-- Spectate disengages when a person moves the map. If the view then sits
-- still (no scrolling, no menus) for IDLE_CHECKS checks in a row, the person
-- has left, so resume spectating.
--   dfai-spectate-keeper start | stop | status
local CHECK_FRAMES = 1200     -- about 12-20 s at stream frame rates
local IDLE_CHECKS = 8         -- ~2-3 minutes of an untouched view

keeper = keeper or {running = false, last = nil, still = 0}

local function view()
  return ('%d,%d,%d'):format(df.global.window_x, df.global.window_y, df.global.window_z)
end

local function spectate_on()
  local ok, plugin = pcall(require, 'plugins.spectate')
  if ok and plugin and plugin.isEnabled then return plugin.isEnabled() end
  local out = dfhack.run_command_silent('spectate')
  return out and out:find('spectate is:%s*enabled') ~= nil
end

local function tick()
  if not keeper.running then return end
  dfhack.timeout(CHECK_FRAMES, 'frames', tick)
  if not dfhack.isMapLoaded() or not dfhack.gui.matchFocusString('dwarfmode/Default') then
    keeper.still = 0
    return
  end
  if spectate_on() then keeper.still, keeper.last = 0, nil return end
  local v = view()
  keeper.still = (v == keeper.last) and keeper.still + 1 or 0
  keeper.last = v
  if keeper.still >= IDLE_CHECKS then
    dfhack.run_command('enable', 'spectate')
    keeper.still = 0
  end
end

local cmd = ({...})[1] or 'status'
if cmd == 'start' then
  if not keeper.running then keeper.running = true; keeper.still = 0; tick() end
  print('dfai-spectate-keeper: running')
elseif cmd == 'stop' then
  keeper.running = false
  print('dfai-spectate-keeper: stopped')
else
  print('dfai-spectate-keeper: ' .. (keeper.running and 'running' or 'stopped'))
end
