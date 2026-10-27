-- Projects for the stream camera's mission mode (dfai-room-tour.lua).
--@module = true
--[====[
dfai-projects
=============
A project is a titled box of tiles where work happens (a rescue ramp, the deep
shaft, a new hall). The room tour follows the dwarf working inside the box
under a "PROJECT:" banner and shows the finished result.

    dfai-projects add <key> "<title>" x1 y1 z1 x2 y2 z2 [manual]
    dfai-projects done <key>
    dfai-projects remove <key>
    dfai-projects list

"manual" projects are finished only by "done"; other projects finish on their
own once the box has had work in it and no dig/build jobs remain there.
Kept in the save (site data), so they survive reloads.
]====]

local KEY = 'dfai-projects'

local function load() local d = dfhack.persistent.getSiteData(KEY, {}) d.list = d.list or {} return d end
local function save(d) dfhack.persistent.saveSiteData(KEY, d) end

function list() return load().list end

function add(key, title, x1, y1, z1, x2, y2, z2, manual)
    local d = load()
    for i = #d.list, 1, -1 do if d.list[i].key == key then table.remove(d.list, i) end end
    table.insert(d.list, {key = key, title = title,
        box = {math.min(x1, x2), math.min(y1, y2), math.min(z1, z2), math.max(x1, x2), math.max(y1, y2), math.max(z1, z2)},
        manual = manual and true or nil, added = os.time()})
    save(d)
end

function update(key, fields)
    local d = load()
    for _, p in ipairs(d.list) do
        if p.key == key then for k, v in pairs(fields) do p[k] = v end end
    end
    save(d)
end

function done(key) update(key, {done = true, done_at = os.time()}) end

function remove(key)
    local d = load()
    for i = #d.list, 1, -1 do if d.list[i].key == key then table.remove(d.list, i) end end
    save(d)
end

-- finished projects are kept an hour (for the completion shot), then dropped
function prune()
    local d, now, changed = load(), os.time(), false
    for i = #d.list, 1, -1 do
        local p = d.list[i]
        if (p.done and now - (p.done_at or now) > 3600) or now - (p.added or now) > 3 * 86400 then
            table.remove(d.list, i); changed = true
        end
    end
    if changed then save(d) end
end

-- finished projects that drew a crowd: permanent tour stops
function promoted() return load().promoted or {} end

function promote(key, name, kind, box)
    local d = load()
    d.promoted = d.promoted or {}
    for _, p in ipairs(d.promoted) do if p.key == key then return end end
    table.insert(d.promoted, {key = key, name = name, kind = kind, box = box,
        x = (box[1] + box[4]) // 2, y = (box[2] + box[5]) // 2, z = box[3]})
    save(d)
end

-- finished projects for the Herald's Works desk (supervisor/herald_works.py)
local DONE_FILE = dfhack.getDFPath() .. '/dfhack-config/dfai-projects-done.json'
function log_done(entry)
    local json = require('json')
    local ok, data = pcall(json.decode_file, DONE_FILE)
    local s = dfhack.world.getCurrentSite()
    if not ok or type(data) ~= 'table' or data.site_id ~= (s and s.id) then data = {site_id = s and s.id, done = {}} end
    entry.at = os.time()
    table.insert(data.done, entry)
    while #data.done > 20 do table.remove(data.done, 1) end
    json.encode_file(data, DONE_FILE)
end

if dfhack_flags.module then return end

local args = {...}
local cmd = args[1]
if cmd == 'add' then
    local n = {}
    for i = 4, 9 do n[#n + 1] = tonumber(args[i]) end
    if #n < 6 then qerror('usage: dfai-projects add <key> "<title>" x1 y1 z1 x2 y2 z2 [manual]') end
    add(args[2], args[3], n[1], n[2], n[3], n[4], n[5], n[6], args[10] == 'manual')
    print('project added: ' .. args[3])
elseif cmd == 'done' then done(args[2]) print('project done: ' .. tostring(args[2]))
elseif cmd == 'remove' then remove(args[2]) print('project removed: ' .. tostring(args[2]))
elseif cmd == 'promoted' then
    for _, p in ipairs(promoted()) do print(p.key, p.name, p.x, p.y, p.z) end
else
    for _, p in ipairs(list()) do
        local b = p.box
        print(('%-14s %-40s %d,%d,%d..%d,%d,%d %s%s'):format(p.key, p.title, b[1], b[2], b[3], b[4], b[5], b[6],
            p.manual and 'manual ' or '', p.done and 'DONE' or (p.seen_work and 'working' or 'waiting')))
    end
end
