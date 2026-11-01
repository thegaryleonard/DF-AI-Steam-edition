-- dfai-fps: the game's FPS cap, from the Overseer's Desk, kept across
-- reloads, the ASCII switch and new forts.
-- Dynamic mode (owner: "100 during normal idle work times and then battles
-- drop down to 20fps"): the fort runs at the normal cap, and drops to the
-- battle cap while there is a fight on (invaders on the map, or a hostile
-- creature close to a citizen), so viewers can follow it. Back to normal
-- after a calm spell, so it doesn't flap.
--   dfai-fps                 what it is now
--   dfai-fps set N           normal cap (5-200)
--   dfai-fps battle N        cap during fights (5-200)
--   dfai-fps calm N          game days of quiet before speeding up again (0-7)
--   dfai-fps dynamic on|off  switch between caps by itself, or always normal
--   dfai-fps apply           put the right cap back now
--   dfai-fps start           the watcher (every 50 ticks; onMapLoad)
--@module = true

local json = require('json')
local repeatUtil = require('repeat-util')
local FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-fps.json'
local LO, HI = 5, 200
local KEY = 'dfai-fps'

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, math.floor(n))) end

function config()
    local ok, d = pcall(json.decode_file, FILE)
    d = ok and type(d) == 'table' and d or {}
    return {
        fps = clamp(tonumber(d.fps) or 20, LO, HI),
        battle = clamp(tonumber(d.battle) or 20, LO, HI),
        dynamic = d.dynamic == true,
        calm = clamp(tonumber(d.calm) or 1, 0, 7),
    }
end
local function save(c) json.encode_file(c, FILE) end

F = rawget(_G, 'dfai_fps_state') or {fight = false, quiet_since = nil, why = nil}
rawset(_G, 'dfai_fps_state', F)

-- a fight: an active invader we can see, or something hostile within 15
-- tiles (and 3 levels) of a citizen. Caged, chained and hidden ones don't count.
local function fight_now()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return nil end
    local cits = dfhack.units.getCitizens(true)
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and not u.flags1.caged and not u.flags1.chained and not dfhack.units.isCitizen(u) then
            local f = dfhack.maps.getTileFlags(u.pos)
            if f and not f.hidden then
                local inv = dfhack.units.isInvader(u)
                if inv and u.flags1.active_invader then return 'invaders: ' .. dfhack.df2utf(dfhack.units.getReadableName(u)) end
                if inv or dfhack.units.isDanger(u) or dfhack.units.isGreatDanger(u) or dfhack.units.isAgitated(u) then
                    for _, c in ipairs(cits) do
                        if math.abs(c.pos.z - u.pos.z) <= 3 and math.abs(c.pos.x - u.pos.x) <= 15 and math.abs(c.pos.y - u.pos.y) <= 15 then
                            return dfhack.df2utf(dfhack.units.getReadableName(u)) .. ' near ' .. dfhack.df2utf(dfhack.units.getReadableName(c))
                        end
                    end
                end
            end
        end
    end
end

local function now() return df.global.cur_year * 403200 + df.global.cur_year_tick end

function target(c)
    c = c or config()
    if not c.dynamic then return c.fps end
    return F.fight and c.battle or c.fps
end
wanted = target

function apply(n)
    n = n or target()
    if df.global.enabler.fps ~= n then df.global.enabler.fps = n end
    df.global.init.fps_cap = n
    return n
end

local function tick()
    local c = config()
    if not c.dynamic then F.fight = false apply(c.fps) return end
    local why = fight_now()
    if why then
        if not F.fight then dfhack.gui.showAnnouncement('Battle speed: the game slows down so the fight can be watched.', COLOR_LIGHTRED, false) end
        F.fight, F.why, F.quiet_since = true, why, nil
    elseif F.fight then
        F.quiet_since = F.quiet_since or now()
        if now() - F.quiet_since >= c.calm * 1200 then
            F.fight, F.why, F.quiet_since = false, nil, nil
        end
    end
    apply(target(c))
end

function status()
    local c = config()
    local mode = not c.dynamic and ('fixed at %d'):format(c.fps)
        or F.fight and ('BATTLE speed %d (%s); back to %d after %d calm day%s'):format(c.battle, F.why or 'quiet now', c.fps, c.calm, c.calm == 1 and '' or 's')
        or ('normal speed %d; battles drop to %d'):format(c.fps, c.battle)
    return ('FPS cap %d, running at about %d: %s'):format(df.global.enabler.fps, df.global.enabler.calculated_fps, mode)
end

if dfhack_flags.module then return end
local args = {...}
local c = config()
local function num(i, what, lo, hi)
    local n = tonumber(args[i])
    if not n then qerror(('dfai-fps %s N (a number, %d-%d)'):format(what, lo, hi)) end
    return clamp(n, lo, hi)
end
if args[1] == 'set' then
    c.fps = num(2, 'set', LO, HI) save(c)
    dfhack.timeout(1, 'frames', function() apply() end)
    print(('Normal FPS cap set to %d%s'):format(c.fps, c.dynamic and (' (battles: %d)'):format(c.battle) or ''))
elseif args[1] == 'battle' then
    c.battle = num(2, 'battle', LO, HI) save(c)
    dfhack.timeout(1, 'frames', function() apply() end)
    print(('Battle FPS cap set to %d%s'):format(c.battle, c.dynamic and '' or ' (dynamic speed is off)'))
elseif args[1] == 'calm' then
    c.calm = num(2, 'calm', 0, 7) save(c)
    print(('Back to normal speed after %d calm game day%s'):format(c.calm, c.calm == 1 and '' or 's'))
elseif args[1] == 'dynamic' then
    c.dynamic = args[2] == 'on' or args[2] == 'true' or args[2] == '1'
    save(c)
    dfhack.timeout(1, 'ticks', function() pcall(tick) end)
    print(c.dynamic and ('Dynamic speed on: %d normally, %d in battles'):format(c.fps, c.battle) or ('Dynamic speed off: fixed at %d'):format(c.fps))
elseif args[1] == 'apply' then
    print(('FPS cap: %d'):format(apply()))
elseif args[1] == 'start' then
    repeatUtil.scheduleEvery(KEY, 50, 'ticks', function() pcall(tick) end)
    apply()
    print('dfai-fps: watching for battles (' .. (c.dynamic and 'dynamic on' or 'dynamic off') .. ')')
elseif args[1] == 'json' then
    print(json.encode({fps = c.fps, battle = c.battle, dynamic = c.dynamic, calm = c.calm, fight = F.fight, why = F.why, cap = df.global.enabler.fps, actual = df.global.enabler.calculated_fps}))
else
    print(status())
end
