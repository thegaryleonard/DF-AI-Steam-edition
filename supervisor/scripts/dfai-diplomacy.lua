-- dfai-diplomacy: advance a pending diplomat meeting by one step.
-- In DF 53 a liaison/diplomat meeting waits behind a DIPLOMACY alert until a
-- player clicks it; df-ai never did, so every diplomat "could not complete a
-- meeting and has left unhappy". Run repeatedly (the supervisor does) until it
-- prints IDLE. Prints the meeting text so it shows up in logs.
local gps = df.global.gps
local d = df.global.game.main_interface.diplomacy
local p = df.global.plotinfo

local function row(y)
  local s = {}
  for x = 0, gps.dimx - 1 do
    local t = dfhack.screen.readTile(x, y)
    s[#s + 1] = (t and t.ch and t.ch >= 32 and t.ch < 127) and string.char(t.ch) or ' '
  end
  return table.concat(s)
end

local function click_text(text)
  for y = 0, gps.dimy - 1 do
    local x = row(y):find(text, 1, true)
    if x then
      local tx = x - 1 + #text // 2
      local tw, th = gps.screen_pixel_x // gps.dimx, gps.screen_pixel_y // gps.dimy
      gps.mouse_x, gps.mouse_y = tx, y
      gps.precise_mouse_x, gps.precise_mouse_y = tx * tw + tw // 2, y * th + th // 2
      local e = df.global.enabler
      e.mouse_lbut, e.mouse_lbut_down = 1, 1
      require('gui').simulateInput(dfhack.gui.getCurViewscreen(), '_MOUSE_L')
      e.mouse_lbut, e.mouse_lbut_down = 0, 0
      return true
    end
  end
  return false
end

local function said()
  local t = {}
  for _, w in ipairs(d.text.word) do t[#t + 1] = w.str end
  return dfhack.df2utf(table.concat(t, ' '))
end

if not d.open then
  if #p.dipscript_popups > 0 then
    print(click_text('DIPLOMACY') and 'OPENED meeting' or 'WAITING (DIPLOMACY alert not on screen)')
  else
    print('IDLE')
  end
elseif d.selecting_land_holder_position then
  -- land holder (baron etc.) appointment: not handled yet; leave it for a human
  print('NEEDS-HUMAN land holder selection: ' .. said())
elseif d.taking_requests then
  print(click_text('Done') and 'REQUESTS done (none requested)' or 'STUCK on requests screen')
else
  local text = said()
  -- answers to requests that come with a choice. The elves' tree-felling cap is
  -- refused: wood is the fort's charcoal for smelting and armor, and a little
  -- conflict is welcome on stream. Anything unknown takes the first answer
  -- rather than freezing the game (DF waits forever on this screen).
  local CHOICES = {
    {'We cannot stop production', 'REFUSED tree cap: '},
    {'We will not be bound', 'REFUSED: '},
  }
  for _, c in ipairs(CHOICES) do
    if click_text(c[1]) then print(c[2] .. text) return end
  end
  if click_text('Okay') then print('SAID ' .. text) return end
  for y = 0, gps.dimy - 1 do
    local r = row(y)
    local opt = r:match('^        (%u.+[%.!])%s*$')
    if opt and #opt > 12 and not text:find(opt, 1, true) then
      if click_text(opt) then print('CHOSE "' .. opt .. '" for: ' .. text) return end
    end
  end
  print('STUCK ' .. text)
end
