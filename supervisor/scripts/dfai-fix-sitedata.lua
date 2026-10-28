-- dfai-fix-sitedata <key>: repair a site-data JSON blob that holds raw cp437
-- bytes (game names saved without dfhack.df2utf). Valid UTF-8 is kept; each
-- stray byte is converted from cp437. Run once; the reader then works again.
local key = ({...})[1]
if not key then qerror('usage: dfai-fix-sitedata <key>') end
local raw = dfhack.persistent.getSiteDataString(key)
if not raw then print('no data for ' .. key) return end
local out, i, n, fixed = {}, 1, #raw, 0
while i <= n do
    local c = raw:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3 or (c >= 0xF0 and c <= 0xF4) and 4 or 0
    local ok = len > 0 and i + len - 1 <= n
    for k = 1, len - 1 do
        local b = ok and raw:byte(i + k)
        if not b or b < 0x80 or b > 0xBF then ok = false break end
    end
    if ok then
        out[#out + 1] = raw:sub(i, i + len - 1)
        i = i + len
    else
        out[#out + 1] = dfhack.df2utf(string.char(c))
        fixed = fixed + 1
        i = i + 1
    end
end
local s = table.concat(out)
local good, t = pcall(require('json').decode, s)
if not good then print('still unreadable: ' .. tostring(t):sub(1, 200)) return end
dfhack.persistent.saveSiteData(key, t)
print(('%s: fixed %d byte(s)'):format(key, fixed))
