-- dfai-tavern-check: for every tavern, list its stockpiles (inside or touching
-- the zone) as drinks-only / meals-only / mixed, with barrel allowance, and the
-- free floor tiles a meals pile could go on.  "fix" places a meals pile where
-- one is missing and makes drink piles drinks-only with barrels.
local quickfort = reqscript('quickfort')
local fix = ({...})[1] == 'fix'
local site = dfhack.world.getCurrentSite()

local function on(v) return v == true or (type(v) == 'number' and v ~= 0) end
local function kind(sp)
    local fo = sp.settings.food
    if not sp.settings.flags.food then return 'other' end
    local d, other = 0, 0
    for _, v in ipairs(fo.drink_plant) do if on(v) then d = d + 1 end end
    for _, v in ipairs(fo.drink_animal) do if on(v) then d = d + 1 end end
    for _, l in ipairs({'meat', 'fish', 'unprepared_fish', 'egg', 'plants', 'cheese_plant', 'cheese_animal', 'seeds', 'leaves', 'powder_plant', 'powder_creature', 'glob', 'glob_paste', 'glob_pressed', 'liquid_plant', 'liquid_animal', 'liquid_misc'}) do
        local t = fo[l]
        if t then for _, v in ipairs(t) do if on(v) then other = other + 1 break end end end
    end
    if d > 0 and not fo.prepared_meals and other == 0 then return 'drinks' end
    if d == 0 and fo.prepared_meals and other == 0 then return 'meals' end
    return ('mixed(drinks %d meals %s other %d)'):format(d, tostring(fo.prepared_meals), other)
end

local function free(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt or df.tiletype.attrs[tt].shape ~= df.tiletype_shape.FLOOR then return false end
    local f, o = dfhack.maps.getTileFlags(x, y, z), dfhack.maps.getTileBlock(x, y, z).occupancy[x % 16][y % 16]
    return o.building == 0 and not f.hidden
end

for _, loc in ipairs(site.buildings) do
    if df.abstract_building_inn_tavernst:is_instance(loc) and not loc.flags.DOES_NOT_EXIST then
        for _, bid in ipairs(loc.contents.building_ids) do
            local z = df.building.find(bid)
            if z then
                print(('%s (%s) zone %d..%d,%d..%d z%d'):format(dfhack.df2utf(dfhack.translation.translateName(loc.name, true)),
                    loc.flags.VISITORS_ALLOWED and 'public' or 'citizens', z.x1, z.x2, z.y1, z.y2, z.z))
                local have = {}
                for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
                    if sp.z == z.z and sp.x2 >= z.x1 - 1 and sp.x1 <= z.x2 + 1 and sp.y2 >= z.y1 - 1 and sp.y1 <= z.y2 + 1 then
                        local k = kind(sp)
                        local tiles = (sp.x2 - sp.x1 + 1) * (sp.y2 - sp.y1 + 1)
                        print(('   pile %d %dx%d at %d,%d: %s, barrels %d'):format(sp.id, sp.x2 - sp.x1 + 1, sp.y2 - sp.y1 + 1, sp.x1, sp.y1, k, sp.storage.max_barrels))
                        have[k] = sp
                        if k:find('^mixed') and tostring(sp.name):find('tavern meals') then have.meals = sp end
                        if fix and k == 'drinks' and sp.storage.max_barrels < tiles then sp.storage.max_barrels = tiles; print('     barrels ->', tiles) end
                    end
                end
                if not have.meals then
                    -- a free 1xN strip inside the zone (along a wall, away from the tables)
                    local best
                    for y = z.y1, z.y2 do for x = z.x1, z.x2 do
                        for _, d in ipairs({{1, 0}, {0, 1}}) do
                            local n = 0
                            while n < 4 and free(x + d[1] * n, y + d[2] * n, z.z) and x + d[1] * n <= z.x2 and y + d[2] * n <= z.y2 do n = n + 1 end
                            if n >= 2 and (not best or n > best.n) then best = {x = x, y = y, d = d, n = n} end
                        end
                    end end
                    if not best then print('   no meals pile and no free strip')
                    else
                        local w, h = best.d[1] == 1 and best.n or 1, best.d[2] == 1 and best.n or 1
                        print(('   no meals pile; free strip %dx%d at %d,%d'):format(w, h, best.x, best.y))
                        if fix then
                            local ok, err = pcall(quickfort.apply_blueprint, {mode = 'place', data = ('f{name="tavern meals"}:=preparedmeals(%dx%d)'):format(w, h), pos = xyz2pos(best.x, best.y, z.z)})
                            print('     placed meals pile:', ok, err or '')
                        end
                    end
                end
            end
        end
    end
end
