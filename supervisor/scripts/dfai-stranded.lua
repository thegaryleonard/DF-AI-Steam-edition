-- dfai-stranded: gets dwarves down off the curtain wall.
-- A builder standing beside a wall section as it goes up is pushed onto its
-- top, and the top of a wall is cut off from the ground: Channelevened lost 15
-- dwarves to thirst up there. A citizen standing on a built wall whose
-- walking area isn't the fort's gets the wall tile under them taken down by
-- a dwarf from the ground; they drop one level (no harm) and walk home, and
-- dfai-walls puts the section back up later.
--   dfai-stranded start | status
--@module = true

local repeatUtil = require('repeat-util')
local KEY = 'dfai-stranded'
state = state or {last = 'watching', rescued = 0, asked = {}}

local function fort_group()
    local count = {}
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        local g = dfhack.maps.getWalkableGroup(u.pos)
        if g ~= 0 then count[g] = (count[g] or 0) + 1 end
    end
    local best, n = nil, 0
    for g, c in pairs(count) do if c > n then best, n = g, c end end
    return best
end

local function constructed_wall(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    local a = tt and df.tiletype.attrs[tt]
    return a and a.shape == df.tiletype_shape.WALL and a.material == df.tiletype_material.CONSTRUCTION
end

local function tick()
    if df.global.gamemode ~= df.game_mode.DWARF or not dfhack.isMapLoaded() then return end
    local ok, err = pcall(function()
        local fg = fort_group()
        if not fg then return end
        local now = df.global.world.frame_counter
        local up = 0
        for _, u in ipairs(dfhack.units.getCitizens(true)) do
            local p = u.pos
            if not u.flags1.caged and dfhack.maps.getWalkableGroup(p) ~= fg and constructed_wall(p.x, p.y, p.z - 1) then
                up = up + 1
                local k = tostring(u.id)
                local asked = state.asked[k]
                if not asked or now - asked > 2400 then
                    local below = xyz2pos(p.x, p.y, p.z - 1)
                    if dfhack.constructions.designateRemove(below) then
                        state.asked[k] = now
                        state.rescued = state.rescued + 1
                        dfhack.gui.showAnnouncement(('%s is stuck on top of the wall; the section under them is coming down.')
                            :format(dfhack.df2utf(dfhack.units.getReadableName(u))), COLOR_YELLOW, false)
                    end
                end
            end
        end
        state.last = up > 0 and ('%d dwarves stuck on the wall top; getting them down'):format(up) or 'nobody stuck on the wall'
    end)
    if not ok then state.last = 'error: ' .. tostring(err) end
end

function status() return ('stranded: %s (%d rescues so far)'):format(state.last, state.rescued) end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 300, 'ticks', tick)
    dfhack.timeout(5, 'ticks', tick)
    print('stranded: watching')
else
    print(status())
end
