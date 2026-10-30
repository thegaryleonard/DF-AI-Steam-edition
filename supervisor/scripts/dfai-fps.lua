-- dfai-fps: the game's FPS cap, set from the Overseer's Desk and kept across
-- reloads, the ASCII switch and new forts (they all used to force 20).
--   dfai-fps            what it is now
--   dfai-fps set N      cap at N (5-100), remembered
--   dfai-fps apply      put the remembered cap back (default 20)
--@module = true

local json = require('json')
local FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-fps.json'
local DEFAULT, LO, HI = 20, 5, 100

function wanted()
    local ok, d = pcall(json.decode_file, FILE)
    local n = ok and type(d) == 'table' and tonumber(d.fps) or DEFAULT
    return math.max(LO, math.min(HI, math.floor(n)))
end

function apply(n)
    n = n or wanted()
    df.global.enabler.fps = n
    df.global.init.fps_cap = n
    return n
end

if dfhack_flags.module then return end
local args = {...}
if args[1] == 'set' then
    local n = tonumber(args[2])
    if not n then qerror('dfai-fps set N (a number, ' .. LO .. '-' .. HI .. ')') end
    n = math.max(LO, math.min(HI, math.floor(n)))
    json.encode_file({fps = n}, FILE)
    dfhack.timeout(1, 'frames', function() apply(n) end)
    print(('FPS cap set to %d (kept across reloads)'):format(n))
elseif args[1] == 'apply' then
    print(('FPS cap: %d'):format(apply()))
else
    print(('FPS cap %d (running at about %d)'):format(df.global.enabler.fps, df.global.enabler.calculated_fps))
end
