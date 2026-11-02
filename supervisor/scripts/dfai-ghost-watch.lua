-- dfai-ghost-watch: the fort's restless dead, and the memorial slabs that put
-- them to rest (user: "a 'ghost watch' card on the overseer desk that has a
-- ghost and slab status tracker watcher thing").
--
-- Every game day, for each ghost on the map (and each fort dwarf who died in
-- the last two years and isn't resting yet) it follows the slab:
--   none -> on order -> being carved -> engraved, waiting to be set -> set
-- and the body: in a coffin, unburied, or lost. It fixes the gaps it safely
-- can: a missing EngraveSlab order is queued for that dwarf (the order df-ai
-- makes at a death can be lost or cancelled), blank slabs are ordered when the
-- engravers have none, and unzoned coffins get tomb zones (DFHack burial).
-- df-ai itself sets the engraved slabs (stocks update_slabs).
--   dfai-ghost-watch start | now | status | json
--@module = true

local json = require('json')
local repeatUtil = require('repeat-util')
local KEY = 'dfai-ghost-watch'
local RECENT_YEARS = 2

G = rawget(_G, 'dfai_ghost_watch') or {last = 'not checked yet', rows = {}}
rawset(_G, 'dfai_ghost_watch', G)

local function name_of(hf)
    return hf and dfhack.df2utf(dfhack.translation.translateName(hf.name, false)) or '?'
end
local function ours(hf)
    if not hf then return false end
    for _, l in ipairs(hf.entity_links) do
        if l.entity_id == df.global.plotinfo.group_id then return true end
    end
    return false
end

-- slabs, coffins, orders and jobs, indexed by historical figure
local function index()
    local I = {engraved = {}, set = {}, ordered = {}, carving = {}, coffin = {}, blank = 0, blank_ordered = 0}
    for _, it in ipairs(df.global.world.items.other.SLAB) do
        if it.engraving_type == df.slab_engraving_type.Memorial then
            local b = dfhack.items.getHolderBuilding(it)
            if b and b:getType() == df.building_type.Slab then I.set[it.topic] = true
            else I.engraved[it.topic] = true end
        elseif it.engraving_type == df.slab_engraving_type.Slab and not it.flags.in_job and not it.flags.forbid and not it.flags.in_building then
            I.blank = I.blank + 1
        end
    end
    for _, mo in ipairs(df.global.world.manager_orders.all) do
        if mo.job_type == df.job_type.EngraveSlab and mo.amount_left > 0 then I.ordered[mo.specdata.hist_figure_id] = true end
        if mo.job_type == df.job_type.ConstructSlab then I.blank_ordered = I.blank_ordered + mo.amount_left end
    end
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and j.job_type == df.job_type.EngraveSlab then
            local w = dfhack.job.getWorker(j)
            I.carving[j.specdata.hist_figure_id] = w and dfhack.df2utf(dfhack.units.getReadableName(w)) or 'waiting for an engraver'
        end
        l = l.next
    end
    for _, b in ipairs(df.global.world.buildings.other.COFFIN or {}) do
        for _, ci in ipairs(b.contained_items) do
            local it = ci.item
            if df.item_corpsest:is_instance(it) or df.item_corpsepiecest:is_instance(it) then
                local u = df.unit.find(it.unit_id)
                if u then I.coffin[u.hist_figure_id] = true end
            end
        end
    end
    return I
end

local function queue_slab(hfid)
    dfhack.run_command_silent('workorder', '{"job":"EngraveSlab","amount_total":1}')
    local A = df.global.world.manager_orders.all
    local mo = A[#A - 1]
    if mo and mo.job_type == df.job_type.EngraveSlab then mo.specdata.hist_figure_id = hfid return true end
end

local function step()
    if not dfhack.isMapLoaded() or df.global.gamemode ~= df.game_mode.DWARF then return end
    local I = index()
    local rows, seen = {}, {}
    -- the ghosts walking the fort
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isGhost(u) then   -- ghosts count as dead: 'not isDead' hid all of them
            local hf = df.historical_figure.find(u.hist_figure_id)
            seen[u.hist_figure_id] = true
            rows[#rows + 1] = {hf = u.hist_figure_id, name = name_of(hf), ghost = true,
                kind = u.ghost_info and df.ghost_type[u.ghost_info.type] or 'ghost'}
        end
    end
    -- and fort dwarves who died lately and aren't resting yet
    local now = df.global.cur_year
    for _, u in ipairs(df.global.world.units.all) do
        if dfhack.units.isDead(u) and dfhack.units.isDwarf(u) and not seen[u.hist_figure_id] then
            local hf = df.historical_figure.find(u.hist_figure_id)
            if hf and ours(hf) and hf.died_year >= now - RECENT_YEARS and not I.set[u.hist_figure_id] and not I.coffin[u.hist_figure_id] then
                seen[u.hist_figure_id] = true
                rows[#rows + 1] = {hf = u.hist_figure_id, name = name_of(hf), ghost = false}
            end
        end
    end
    -- each one's slab and body, and the fixes
    local queued, need_blank = 0, 0
    for _, r in ipairs(rows) do
        if I.set[r.hf] then r.slab = 'set'
        elseif I.engraved[r.hf] then r.slab = 'engraved, waiting to be set'
        elseif I.carving[r.hf] then r.slab = 'being carved (' .. I.carving[r.hf] .. ')'
        elseif I.ordered[r.hf] then r.slab = 'on order' need_blank = need_blank + 1
        elseif queued < 5 and queue_slab(r.hf) then r.slab = 'on order (just queued)' queued = queued + 1 need_blank = need_blank + 1
        else r.slab = 'none' end
        r.body = I.coffin[r.hf] and 'in a coffin' or 'not in a coffin'
    end
    -- blank slabs for the engravers
    local short = math.min(need_blank, 10) - I.blank - I.blank_ordered
    if short > 0 then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructSlab","amount_total":%d,"material":"INORGANIC"}'):format(short))
    end
    -- coffins that nobody can be buried in (no tomb zone)
    pcall(dfhack.run_command_silent, 'burial')
    local ghosts = 0
    for _, r in ipairs(rows) do if r.ghost then ghosts = ghosts + 1 end end
    G.rows, G.blank, G.at = rows, I.blank, df.global.cur_year_tick
    if #rows == 0 then
        G.last = 'No ghosts. Every recent dead dwarf has a slab set or a coffin.'
    else
        local parts = {}
        for i, r in ipairs(rows) do
            if i > 6 then parts[#parts + 1] = ('and %d more'):format(#rows - 6) break end
            parts[#parts + 1] = ('%s%s: slab %s, body %s'):format(r.name, r.ghost and (' (' .. r.kind:gsub('(%l)(%u)', '%1 %2'):lower() .. ')') or '', r.slab, r.body)
        end
        G.last = ('%d ghost%s walking; %d dead with no slab set and no coffin yet (could rise); %d blank slabs%s. %s'):format(ghosts, ghosts == 1 and '' or 's', #rows - ghosts, I.blank,
            (queued > 0 and ('; queued %d slab%s'):format(queued, queued > 1 and 's' or '') or '') .. (short > 0 and ('; ordered %d blank'):format(short) or ''),
            table.concat(parts, '; '))
    end
end

function status() return 'ghost watch: ' .. G.last end

if dfhack_flags.module then return end
local cmd = ({...})[1] or 'status'
if cmd == 'start' then
    repeatUtil.scheduleEvery(KEY, 1200, 'ticks', function() local ok, e = pcall(step) if not ok then G.last = 'error: ' .. tostring(e) end end)
    dfhack.timeout(1, 'ticks', function() pcall(step) end)
    print('ghost watch: daily')
elseif cmd == 'now' then
    dfhack.timeout(1, 'ticks', function() local ok, e = pcall(step) if not ok then G.last = 'error: ' .. tostring(e) end end)
    print('ghost watch: checking on the next tick')
elseif cmd == 'json' then
    print(json.encode({rows = G.rows, blank = G.blank, last = G.last}))
else
    print(status())
end
