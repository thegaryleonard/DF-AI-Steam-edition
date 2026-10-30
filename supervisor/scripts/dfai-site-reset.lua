-- dfai-site-reset: run first on every map load. DFHack's Lua state outlives a
-- map, so when a NEW fort loads (another site), the stream scripts' in-memory
-- state from the old fort (the room tour's season, kill-order bookkeeping,
-- "last seen" notes, camera locks...) would carry over - Hammerfaiths opened
-- with the room tour "showing Spring" because it still had Showerwheels'
-- season. When the site changed, every _G.dfai_* table is dropped; the
-- scripts started after this line in onMapLoad.init begin fresh.
local site = df.global.plotinfo.site_id
local last = rawget(_G, 'dfai_site_reset_last')
if last ~= nil and last ~= site then
    local n = 0
    for k in pairs(_G) do
        if type(k) == 'string' and k:find('^dfai_') and k ~= 'dfai_site_reset_last' then
            rawset(_G, k, nil)
            n = n + 1
        end
    end
    print(('dfai-site-reset: new fort (site %d, was %d): cleared %d bits of old-fort state'):format(site, last, n))
else
    print('dfai-site-reset: same fort')
end
rawset(_G, 'dfai_site_reset_last', site)
