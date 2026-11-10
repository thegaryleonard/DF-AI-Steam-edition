-- dfai-ghost-watch: the fort's restless dead, and the memorial slabs that put
-- them to rest (user: "a 'ghost watch' card on the overseer desk that has a
-- ghost and slab status tracker watcher thing").
--
-- Every game day, for each ghost on the map and EVERY fort dwarf who has
-- died without a memorial slab set (buried or not: user, "you can make slabs
-- for everyone before they are buried just to be safe") it follows the slab:
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
local QUEUE_PER_DAY = 10     -- new slab orders a day (each takes a mason a while)
local ENGRAVER_CAP = 6       -- most engravers asked of autolabor while slabs wait

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

-- every EngraveSlab job: do now, and to the front of its workshop's queue
-- (behind only another slab job). Returns how many wait for an engraver.
function prioritise_slabs()
    local waiting = 0
    local l = df.global.world.jobs.list.next
    while l do
        local j = l.item
        if j and j.job_type == df.job_type.EngraveSlab then
            j.flags.do_now = true
            if not dfhack.job.getWorker(j) then waiting = waiting + 1 end
            local b = dfhack.job.getHolder(j)
            if b then
                local idx
                for i, bj in ipairs(b.jobs) do if bj == j then idx = i break end end
                -- the front job may be worked: never move a job past a worked one
                local front = b.jobs[0]
                if idx and idx > 0 and front.job_type ~= df.job_type.EngraveSlab and not dfhack.job.getWorker(front) then
                    b.jobs:erase(idx)
                    b.jobs:insert(0, j)
                end
            end
        end
        l = l.next
    end
    return waiting
end

-- autolabor's ENGRAVER minimum: raised to the waiting slab jobs (capped)
-- while any wait, put back to what it was once none do
function engravers(waiting)
    local st = dfhack.persistent.getSiteData(KEY .. '-labor', {})
    local cur = dfhack.run_command_silent('autolabor', 'list'):match('ENGRAVER:%s+minimum (%d+)')
    cur = tonumber(cur)
    if not cur then return end
    if waiting > 0 then
        local want = math.min(ENGRAVER_CAP, math.max(waiting, cur))
        if st.old == nil then st.old = cur end
        if want > cur then dfhack.run_command_silent('autolabor', 'ENGRAVER', tostring(want), '200') end
    elseif st.old ~= nil then
        dfhack.run_command_silent('autolabor', 'ENGRAVER', tostring(st.old), '200')
        st.old = nil
    end
    dfhack.persistent.saveSiteData(KEY .. '-labor', st)
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
    -- and every fort dwarf who died without a slab set, in a coffin or not:
    -- a slab first, the burial after (a body can still go missing)
    for _, u in ipairs(df.global.world.units.all) do
        if dfhack.units.isDead(u) and dfhack.units.isDwarf(u) and not seen[u.hist_figure_id] then
            local hf = df.historical_figure.find(u.hist_figure_id)
            if hf and ours(hf) and not I.set[u.hist_figure_id] then
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
        elseif queued < QUEUE_PER_DAY and queue_slab(r.hf) then r.slab = 'on order (just queued)' queued = queued + 1 need_blank = need_blank + 1
        else r.slab = 'none' end
        r.body = I.coffin[r.hf] and 'in a coffin' or 'not in a coffin'
    end
    -- blank slabs for the engravers
    local short = math.min(need_blank, 10) - I.blank - I.blank_ordered
    if short > 0 then
        dfhack.run_command_silent('workorder', ('{"job":"ConstructSlab","amount_total":%d,"material":"INORGANIC"}'):format(short))
    end
    -- slabs come first (user: "deffo prioritize ghosts"): every slab job is
    -- marked do-now and moved to the front of its workshop's queue (a shop
    -- only posts its front job), and autolabor is asked for more engravers
    -- while slab jobs wait; the old minimum comes back when they're done
    local waiting = prioritise_slabs()
    engravers(waiting)
    -- coffins that nobody can be buried in (no tomb zone)
    pcall(dfhack.run_command_silent, 'burial')
    local ghosts = 0
    for _, r in ipairs(rows) do if r.ghost then ghosts = ghosts + 1 end end
    G.rows, G.blank, G.at = rows, I.blank, df.global.cur_year_tick
    if #rows == 0 then
        G.last = 'No ghosts. Every dead dwarf of the fort has a memorial slab set.'
    else
        local parts = {}
        for i, r in ipairs(rows) do
            if i > 6 then parts[#parts + 1] = ('and %d more'):format(#rows - 6) break end
            parts[#parts + 1] = ('%s%s: slab %s, body %s'):format(r.name, r.ghost and (' (' .. r.kind:gsub('(%l)(%u)', '%1 %2'):lower() .. ')') or '', r.slab, r.body)
        end
        G.last = ('%d ghost%s walking; %d dead without a memorial slab set yet; %d blank slabs; %d slab job%s waiting for an engraver%s. %s'):format(ghosts, ghosts == 1 and '' or 's', #rows - ghosts, I.blank, waiting, waiting == 1 and '' or 's',
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
