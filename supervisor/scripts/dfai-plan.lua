-- dfai-plan: what df-ai has planned, for the other scripts (shared helper).
-- Every script that picks a new site in rock asks before it digs: a room laid
-- on ground df-ai planned but hadn't dug yet (a music hall over the hospital
-- and its well shaft) breaks both.
--   reqscript('dfai-plan').planned_room_at(x1, y1, x2, y2, z) -> description or nil
--   dfai-plan at X Y Z      (from the console)
--@module = true

local ok_plugin, DFAI = pcall(require, 'plugins.df-ai')

function planned_room_at(x1, y1, x2, y2, z)
    if not ok_plugin or not DFAI.planned_room_at then return nil end
    local ok, d = pcall(DFAI.planned_room_at, math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2), z)
    if ok and d and d ~= '' then return d end
end

-- any tile of a vertical column (x, y, zlo..zhi) on planned ground
function planned_column(x, y, zlo, zhi)
    for z = zlo, zhi do
        local d = planned_room_at(x, y, x, y, z)
        if d then return d, z end
    end
end

if dfhack_flags and dfhack_flags.module then return end
local args = {...}
if args[1] == 'at' and #args >= 4 then
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    print(planned_room_at(x, y, x, y, z) or 'nothing planned there')
else
    print('dfai-plan at X Y Z')
end
