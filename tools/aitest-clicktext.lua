-- aitest-clicktext <text> [occurrence]: find <text> on the DF screen and click it.
-- prints the screen lines containing it; "aitest-clicktext --dump" prints the whole screen.
local gui = require 'gui'
local args = {...}
local gps = df.global.gps
local function line(y)
    local t = {}
    for x = 0, gps.dimx - 1 do
        local p = dfhack.screen.readTile(x, y)
        local ch = p and p.ch or 32
        if ch < 32 or ch > 126 then ch = 32 end
        t[#t + 1] = string.char(ch)
    end
    return table.concat(t)
end
if args[1] == '--dump' then
    for y = 0, gps.dimy - 1 do
        local l = line(y)
        if l:match('%S') then print(('%3d %s'):format(y, l)) end
    end
    return
end
local want, nth = args[1], tonumber(args[2] or '1')
local n = 0
for y = 0, gps.dimy - 1 do
    local l = line(y)
    local s = 1
    while true do
        local i = l:find(want, s, true)
        if not i then break end
        n = n + 1
        if n == nth then
            local tx, ty = i - 1 + math.min(2, #want - 1), y
            local tw, th = gps.screen_pixel_x // gps.dimx, gps.screen_pixel_y // gps.dimy
            gps.mouse_x, gps.mouse_y = tx, ty
            gps.precise_mouse_x, gps.precise_mouse_y = tx * tw + tw // 2, ty * th + th // 2
            df.global.enabler.mouse_lbut = 1
            df.global.enabler.mouse_lbut_down = 1
            gui.simulateInput(dfhack.gui.getCurViewscreen(), '_MOUSE_L')
            df.global.enabler.mouse_lbut = 0
            df.global.enabler.mouse_lbut_down = 0
            print(('clicked "%s" at tile %d,%d: %s'):format(want, tx, ty, l))
            return
        end
        s = i + 1
    end
end
print(('text "%s" not found (%d matches)'):format(want, n))
