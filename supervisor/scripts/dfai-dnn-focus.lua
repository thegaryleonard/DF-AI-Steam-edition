-- dfai-dnn-focus: DNN (the stream's news channel, supervisor/dnn.py) asks the camera to
-- look at the story it is reporting, for a short while.
--   dfai-dnn-focus <report id> [seconds] [title...]
-- Uses the announcement's own "zoom to" position (report.pos, the spot DF jumps to when
-- you click the announcement) and holds it through dfai-camera-lock with a wall-clock
-- end, so spectate, the room tour and every other camera mover leave it alone and pick
-- up again afterwards. Never takes the camera from a human or desk lock (any lock that
-- isn't DNN's own) or from the battle camera, and battles still break in (yield).
-- Prints OK x y z | BUSY why | NONE why.
local args = {...}
local id = tonumber(args[1] or '')
local secs = math.max(5, math.min(60, tonumber(args[2] or '') or 25))
local title = #args >= 3 and table.concat(args, ' ', 3) or 'DNN Live'
if not id then print('NONE usage: dfai-dnn-focus <report id> [seconds] [title]') return end
if not dfhack.isMapLoaded() then print('NONE no map') return end

local reps = df.global.world.status.reports
local r
for i = #reps - 1, math.max(0, #reps - 3000), -1 do
    if reps[i].id == id then r = reps[i] break end
    if reps[i].id < id then break end
end
if not r then print('NONE report not found') return end
local p = r.pos
if not p or p.x < 0 then print('NONE report has no position') return end
local fl = dfhack.maps.getTileFlags(p)
if not fl or fl.hidden then print('NONE position is hidden') return end

local L = rawget(_G, 'dfai_camlock')
if not L or not L.running then print('NONE camera lock not running') return end
if L.lock and L.lock.source ~= 'dnn' then print('BUSY camera locked: ' .. tostring(L.lock.title)) return end
local t = rawget(_G, 'dfai_tour')
if t and t.threat then print('BUSY battle camera') return end

local x, y, z = p.x, p.y, p.z
dfhack.timeout(1, 'ticks', function()
    reqscript('dfai-camera-lock').lock({x = x, y = y, z = z, title = title, line = 'DNN is live at the scene',
        until_wall = os.time() + secs, yield = true, source = 'dnn'})
end)
print(('OK %d %d %d'):format(x, y, z))
