-- dfai-portrait: write a unit's picture as raw RGBA for the broadsheet's card.
--   dfai-portrait <unit id> <outfile>
-- Uses DF's portrait when it has been built, else the unit's sheet icon (map
-- sprite with what it's holding), else the plain map sprite. Read-only: copies
-- pixels out of the SDL surface DF already made; changes nothing in the game.
-- Output: "RGBA w h\n" + w*h*4 bytes. Prints "OK w h texpos" or "NONE why".
--
-- DF's real 96x96 portrait is built by the dfai_portrait plugin from the
-- render pass (dfai-portrait-builder.lua). Never build it from here: calling
-- DF's portrait code outside rendering, or from Lua, crashed the game.
local args = {...}

local function dump(texpos, out)
    local raws = df.global.enabler.textures.raws
    if not texpos or texpos <= 0 or texpos >= #raws then return nil, 'no texture' end
    local p = raws[texpos]
    if not p then return nil, 'null surface' end
    local i32 = df.reinterpret_cast('int32_t', p)
    local w, h, pitch = i32:_displace(4).value, i32:_displace(5).value, i32:_displace(6).value
    if w <= 0 or h <= 0 or w > 512 or h > 512 then return nil, 'bad size' end
    local fmtp = df.reinterpret_cast('uint64_t', p):_displace(1).value
    if df.reinterpret_cast('uint8_t', fmtp):_displace(17).value ~= 4 then return nil, 'not 32-bit' end
    local px = df.reinterpret_cast('uint32_t', df.reinterpret_cast('uint64_t', p):_displace(4).value)
    local stride, char, parts = pitch // 4, string.char, {}
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            local v = px:_displace(y * stride + x).value
            row[#row + 1] = char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)
        end
        parts[#parts + 1] = table.concat(row)
    end
    local f = assert(io.open(out, 'wb'))
    f:write(('RGBA %d %d\n'):format(w, h))
    f:write(table.concat(parts))
    f:close()
    return w, h
end

local u = df.unit.find(tonumber(args[1] or ''))
if not u or not args[2] then print('NONE no unit') return end
-- DF's own portrait (dfai-portrait-builder has DF make it), else the sprite
if u.portrait_texpos == 0 then rawset(_G, 'dfai_portrait_want', u.id) end
for _, tp in ipairs({u.portrait_texpos, u.sheet_icon_texpos, u.texpos[0][0]}) do
    local w, h = dump(tp, args[2])
    if w then print(('OK %d %d %d'):format(w, h, tp)) return end
end
print('NONE no picture yet')
