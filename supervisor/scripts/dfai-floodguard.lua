-- dfai-floodguard: never let the cistern's inlet and outlet stand open together
-- while there is water behind the inlet (that floods the levels above the
-- cistern through the wells). Checks every 50 ticks.
--   dfai-floodguard start | stop | status
local GLOBAL_KEY = 'dfai-floodguard'
local args = {...}
state = state or {on = false, closed = 0, cancelled = 0}

local function gates()
    -- the reserve inlet: the floodgate with water on its outer side; outlet: the other
    local fg = df.global.world.buildings.other.FLOODGATE
    if #fg < 2 then return end
    return fg
end

local function lever_for(gate_id)
    for _, l in ipairs(df.global.world.buildings.other.TRAP) do
        if l.trap_type == df.trap_type.Lever then
            for _, m in ipairs(l.linked_mechanisms) do
                for _, r in ipairs(m.general_refs) do
                    if r:getType() == df.general_ref_type.BUILDING_TRIGGERTARGET and r.building_id == gate_id then return l end
                end
            end
        end
    end
end

local function is_open(g) return not (g.gate_flags.closed or g.gate_flags.closing) or g.gate_flags.opening end

local function check()
    local fg = gates()
    if not fg then return end
    local open = {}
    for _, g in ipairs(fg) do if is_open(g) then open[#open + 1] = g end end
    if #open < #fg then return end
    -- all open: shut the one with fed water around it (the inlet)
    local best, bw
    for _, g in ipairs(fg) do
        local w = 0
        for dx = -1, 1 do for dy = -1, 1 do
            local f = dfhack.maps.getTileFlags(g.x1 + dx, g.y1 + dy, g.z)
            if f then w = w + f.flow_size end
        end end
        if not bw or w > bw then best, bw = g, w end
    end
    local l = best and lever_for(best.id)
    if l then
        -- drop queued pulls on that lever, then pull it ourselves
        for i = #l.jobs - 1, 0, -1 do dfhack.job.removeJob(l.jobs[i]) state.cancelled = state.cancelled + 1 end
        dfhack.run_command_silent('lever', 'pull', '--id', tostring(l.id), '--instant')
        state.closed = state.closed + 1
        print(('floodguard: both cistern gates were open; closed floodgate %d'):format(best.id))
    end
end

local function loop()
    if not state.on then return end
    pcall(check)
    dfhack.timeout(50, 'ticks', loop)
end

if args[1] == 'start' then
    if not state.on then state.on = true loop() end
    print('floodguard: on')
elseif args[1] == 'stop' then
    state.on = false print('floodguard: off')
else
    print(('floodguard: %s; closed a gate %d times'):format(state.on and 'on' or 'off', state.closed))
end
