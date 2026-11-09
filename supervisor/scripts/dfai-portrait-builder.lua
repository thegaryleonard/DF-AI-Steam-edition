-- dfai-portrait-builder: has DF build its own portrait for the dwarf on camera.
--@ module = true
--
-- DF only makes a unit's 96x96 portrait while the unit sheet is drawn. This
-- overlay widget draws nothing; in the render pass (where DF builds
-- portraits itself) it asks the dfai_portrait plugin to build the portrait of
-- the followed unit (or the unit in _G.dfai_portrait_want), at most once per
-- unit per minute. dfai-portrait.lua then copies the pixels for the broadsheet.
--   overlay enable dfai-portrait-builder.builder

local overlay = require('plugins.overlay')

-- the plugin's functions; when it isn't usable (e.g. a DF version it
-- doesn't know yet) ask again every 5 minutes, so a fixed plugin is picked
-- up without reloading this widget
local plugin, checked = nil, 0
local function lib()
    if not plugin and os.time() - checked >= 300 then
        checked = os.time()
        local t = {}
        if pcall(dfhack.open_plugin, t, 'dfai_portrait') and t.status and t.status() == 'ok' then
            plugin = t
        end
    end
    return plugin
end

state = rawget(_G, 'dfai_portrait_state') or {tried = {}, frame = 0, built = 0}
rawset(_G, 'dfai_portrait_state', state)

Builder = defclass(nil, overlay.OverlayWidget)
Builder.ATTRS{
    desc = 'Builds DF portraits for the stream broadsheet (draws nothing).',
    default_pos = {x = 1, y = -1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 1, h = 1},
}

function Builder:render(dc)
    state.frame = state.frame + 1
    if state.frame % 30 ~= 0 then return end
    local p = lib()
    if not p then return end
    local want = rawget(_G, 'dfai_portrait_want')
    local id = want or df.global.plotinfo.follow_unit
    if not id or id == -1 then return end
    local u = df.unit.find(id)
    if not u then return end
    if u.portrait_texpos ~= 0 and not u.flags4.portrait_must_be_refreshed then
        if want == id then rawset(_G, 'dfai_portrait_want', nil) end
        return
    end
    local now = os.time()
    if (state.tried[id] or 0) > now - 60 then return end
    state.tried[id] = now
    local ok, tp = pcall(p.build, id)
    if ok and tp and tp ~= 0 then state.built = state.built + 1 end
    if want == id then rawset(_G, 'dfai_portrait_want', nil) end
end

OVERLAY_WIDGETS = {builder = Builder}
