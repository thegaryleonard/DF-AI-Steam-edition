-- dfai-ascii: switch the game between its graphics and Classic ASCII glyphs,
-- live, the way a player would: Esc menu > Settings > Video > "Use Classic
-- ASCII glyphs" > Done > Return to game. The clicks are simulated inside DF
-- (DFHack _MOUSE_L at a grid position), not the real mouse. Each step checks
-- the game state before the next, and backs out if anything looks wrong.
-- Positions are for the stream window (174x83 grid, 1396x1000).
--
-- Schedule (user: "the last 5 minutes of specific hours"): dfhack-config/
-- dfai-ascii.json {"hours": [20, 21], "minutes": 5}; checked every half
-- minute by "dfai-ascii start"; outside those minutes the game goes back to
-- graphics, unless someone asked for ASCII on demand ("dfai-ascii on" holds
-- until "dfai-ascii off" or "dfai-ascii auto").
--@module = true
--[====[
dfai-ascii
==========
    dfai-ascii on | off | auto | status | start
]====]

local gui = require('gui')
local json = require('json')
local KEY = 'dfai-ascii'
local CFG = dfhack.getDFPath() .. '/dfhack-config/dfai-ascii.json'
local STATE = dfhack.getDFPath() .. '/dfhack-config/dfai-ascii-state.json'
local GRID_W, GRID_H = 174, 83
local P = {settings = {86, 48}, toggle = {82, 47}, done = {138, 7}, ret = {86, 51}}

local function is_ascii() return not df.global.init.display.flag.USE_GRAPHICS end
local function mi() return df.global.game.main_interface end
local function read(path, default)
    local ok, d = pcall(json.decode_file, path)
    return ok and type(d) == 'table' and d or default
end
local function state() return read(STATE, {mode = 'auto'}) end
local function save_state(s) json.encode_file(s, STATE) end

local function click(p)
    local g = df.global.gps
    g.mouse_x, g.mouse_y = p[1], p[2]
    pcall(function() g.precise_mouse_x, g.precise_mouse_y = p[1] * 8 + 4, p[2] * 12 + 6 end)
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
end

-- the Esc menu's rows move (a siege adds "Succumb to the invasion", a new fort
-- has none of the old fort's extra lines): find the button by its words
local function find_text(text, fallback)
    local g = df.global.gps
    for y = 0, g.dimy - 1 do
        local r = {}
        for x = 0, g.dimx - 1 do
            local t = dfhack.screen.readTile(x, y)
            r[#r + 1] = (t and t.ch and t.ch >= 32 and t.ch < 127) and string.char(t.ch) or ' '
        end
        local x = table.concat(r):find(text, 1, true)
        if x then return {x - 1 + #text // 2, y} end
    end
    return fallback
end

local busy = false
local function bail(why)
    pcall(function() mi().settings.open = false end)
    pcall(function() mi().options.open = false end)
    busy = false
    local s = state() s.last = 'gave up: ' .. why s.at = os.time() save_state(s)
end

-- the step chain; each step runs a few frames after the last and checks it
local function switch(want_ascii, why)
    if busy or is_ascii() == want_ascii then return end
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local g = df.global.gps
    if g.dimx ~= GRID_W or g.dimy ~= GRID_H then
        local s = state() s.last = ('window is %dx%d, not the stream size; not clicking'):format(g.dimx, g.dimy) save_state(s)
        return
    end
    if mi().options.open or mi().settings.open then return end   -- someone is in the menus: leave it
    busy = true
    local steps = {
        function()   -- the Esc menu (Esc itself isn't taken from simulated input)
            -- opening it this way shows the menu's last contents; if that isn't
            -- the plain fort menu (e.g. the save-timeline choices left over from
            -- the abandon-and-new-world run) don't click blind - rebuilding the
            -- list by hand crashed the game
            local o = mi().options
            local has = false
            for _, v in ipairs(o.option) do if v == df.main_menu_option_type.SETTINGS then has = true end end
            if #o.option == 0 then
                -- after a load DF builds this list on the first real Esc press.
                -- Put back the list DF itself built last time (remembered below);
                -- never a made-up one (that crashed the game)
                local saved = state().menu
                if not saved or #saved == 0 then return 'the Esc menu is not built yet (press Esc once by hand after a load)' end
                for _, e in ipairs(saved) do o.option:insert('#', e[1]) o.option_index:insert('#', e[2]) end
                has = true
            end
            if not has then return 'the Esc menu holds something else (press Esc once by hand, then retry)' end
            o.open = true
        end,
        function() if not mi().options.open then return 'no Esc menu' end click(find_text('Settings', P.settings)) end,
        function() if not mi().settings.open then return 'no settings screen' end
            if mi().settings.current_mode ~= 0 then return 'not on the Video tab' end click(P.toggle) end,
        function() if is_ascii() ~= want_ascii then return 'the switch did not change' end click(P.done) end,
        function() if mi().settings.open then mi().settings.open = false end click(find_text('Return to game', P.ret)) end,
        function() if mi().options.open then mi().options.open = false end
            busy = false
            -- the settings screen's Done re-applies the game's own FPS cap (100):
            -- the stream runs at 20
            pcall(function() reqscript('dfai-fps').apply() end)
            local s = state() s.last = (want_ascii and 'switched to ASCII' or 'switched to graphics') .. (why and (' (' .. why .. ')') or '') s.at = os.time() save_state(s)
        end,
    }
    local i = 0
    local function run()
        i = i + 1
        local ok, err = pcall(steps[i])
        if not ok then return bail(tostring(err)) end
        if err then return bail(err) end
        if i < #steps then dfhack.timeout(6, 'frames', run) end
    end
    dfhack.timeout(1, 'frames', run)
end

local function scheduled_now()
    local c = read(CFG, {hours = {}, minutes = 5})
    local t = os.date('*t')
    for _, h in ipairs(c.hours or {}) do
        -- "the last N minutes of hour h": h:(60-N) to h:59
        if t.hour == h and t.min >= 60 - (c.minutes or 5) then return true end
    end
    return false
end

-- remember DF's own fort Esc menu whenever it's built, for the next load
local function remember_menu(s)
    local o = mi().options
    if o.context ~= df.options_context_type.MAIN_DWARF or #o.option == 0 or (s.menu and #s.menu == #o.option) then return end
    local has, m = false, {}
    for i, v in ipairs(o.option) do m[#m + 1] = {v, o.option_index[i]} if v == df.main_menu_option_type.SETTINGS then has = true end end
    if has then s.menu = m save_state(s) end
end

local function tick()
    local s = state()
    pcall(remember_menu, s)
    -- a remembered menu: no need to wait out a back-off from "not built yet"
    if s.menu and s.last and s.last:find('not built yet') then s.last = nil save_state(s) end
    -- after a failed try, wait 30 min before opening the Esc menu again (user:
    -- "a little popup ... with the current track name ... up and gone real
    -- fast": every 30 s it flashed the Esc menu and gave up)
    if s.last and s.last:find('^gave up') and s.at and os.time() - s.at < 1800 then return end
    if s.mode == 'on' then switch(true, 'on demand')
    elseif s.mode == 'off' then switch(false, 'on demand')
    else switch(scheduled_now(), 'schedule') end
end

local function status()
    local s, c = state(), read(CFG, {hours = {}, minutes = 5})
    local hrs = {}
    for _, h in ipairs(c.hours or {}) do hrs[#hrs + 1] = ('%d:%02d'):format(h, 60 - (c.minutes or 5)) end
    return ('ascii: game shows %s; mode %s; schedule %s; %s'):format(is_ascii() and 'ASCII' or 'graphics', s.mode or 'auto',
        #hrs > 0 and ('last ' .. (c.minutes or 5) .. ' min of the hour at ' .. table.concat(hrs, ', ')) or 'none', s.last or '')
end

if dfhack_flags.module then return end
local cmd = ({...})[1]
if cmd == 'on' or cmd == 'off' or cmd == 'auto' then
    local s = state() s.mode = cmd save_state(s)
    dfhack.timeout(1, 'ticks', tick)
    print('ascii: ' .. (cmd == 'auto' and 'following the schedule' or ('switching ' .. cmd)))
elseif cmd == 'start' then
    -- 'frames' keeps it running while paused; the menus pause nothing
    require('repeat-util').scheduleEvery(KEY, 600, 'frames', tick)
    print('ascii: watching the schedule')
else
    print(status())
end
