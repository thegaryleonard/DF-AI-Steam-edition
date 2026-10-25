# Designs scanned from the user's saves

Scanned 2026-10-23 with `tools/aiscan-designs.lua` and `tools/post_scan.py`, driven by
`tools/scan_one.sh`. Each save was loaded from the title screen, scanned read-only, and
DF was then closed without saving, so no save was modified.

Saves scanned (all forts DF 53.16 can load that have player buildings):
`region51`, `sswe`, `ffff`, `region52`, `region55`, `region49`.

## Folder contents

- `scans/<save>.json`: every cluster of water/mist machinery, garbage dumps and hatches.
  - Each cluster has an exact per-tile map for every z-level.
  - Map symbols: `#` wall, `C` constructed wall, `%` fortification, `.` floor, space = open, `1-7` water depth, `a-g` magma depth, `X<>` stairs, `P` screw pump, `*` gear, `-` axle, `M` windmill, `H` hatch, `=` bars, `g` grate, `G` floodgate, `L` lever, `_` pressure plate, `s` statue, `D` door, `w` workshop.
  - Also a building list with screw pump directions, lever targets and zones.
- `quickfort/scan_<save>_c<N>.csv`: the same clusters exported with DFHack `blueprint` (dig, smooth, carve, construct, build, place, zone). They replay exactly with `quickfort run`.
- `orders/orders_<save>.json`: the manager work orders of each fort (`orders export`). The other files in `orders/` are the order libraries the user had saved in `dfhack-config/orders`: `start`, `starter`, `starters`, `full`, `sss`, `stop`, `stopwork`, `decently`, `EX`, `33`, `saved`.
- `user_blueprints/*.csv`: the user's own quickfort blueprints from `dfhack-config/blueprints`: rooms, noblerooms, tombs, guilds, bedroomsquare, aroomset, layer1-6, dig.

## Mist generator: the user's standard design

The same machine appears in three forts: ffff cluster 1 (11 mist flows live), sswe cluster 2
(3 live), and region51 cluster 1 (dry). The best replay source is `quickfort/scan_ffff_c1.csv`
(z138 is the machine level).

Machine level P, built on the surface (windmills need open sky). Coordinates are
relative to the 2x2 centre at (0..1, 0..1), with flow running clockwise (ffff):

```
 y=-1   o  Pw Pw  o        o  = open corner tile (hole down to level P-1)
 y= 0  Ps  G  G  Pn        Pw = screw pump FromWest  at (0..1,-1)
 y= 1  Ps  G  G  Pn        Pn = screw pump FromNorth at (2, 0..1)
 y= 2   o  Pe Pe  o        Pe = screw pump FromEast  at (0..1, 2)
       x=-1 0  1  2        Ps = screw pump FromSouth at (-1, 0..1)
                           G  = gear assemblies (3 of the 4 centre tiles)
```

- **Power:** 4 windmills (sswe uses 6) in a 2x2 or 2x3 block next to the ring. They are linked to a centre gear through horizontal axles and gear assemblies.
- **Level P-1** (the room under the machine): a statue sits on each of the 4 tiles under the open corners. Statues are impassable, so nobody stands under the drop. The floor under the pumps must be open floor so each pump can pull its water back up from the tile beneath its intake end.
- **Water cycle:** each pump pushes water onto the next open corner. It falls one level and makes mist in the room below, then spreads on that floor to the next pump's intake.
- **Priming:** a 1-tile pond zone sits on one corner (ffff: the SW corner) and is filled by bucket. Only a few tiles' worth of water is needed. The loop holds it; stop filling once it runs, or the room below floods.
- **Placement in the user's forts:**
  - ffff: over a barracks / meeting hall.
  - sswe: over a corridor between bedroom blocks.
  - region51: over a statue room.
- sswe runs the same ring counter-clockwise (pumps FromNorth on the west side, and so on).

df-ai cannot build this yet. Its blueprints have no screw pump, horizontal axle, or
surface windmill on a floor. There are two ways to add it:
1. A C++ hook that runs `quickfort run <csv> --cursor x,y,z` for a planned room.
2. New layout types `screw_pump_from_{north,south,east,west}`, `axle_horizontal_{ns,ew}`, plus a windmill-on-floor build. Priming also needs a pond monitor that stops filling once the loop runs.

The user asked the df-ai code session to work this out.

## Garbage dump design (region51 cluster 2)

- A 3x3 dump zone in a small room at the top of a 1-tile chute.
- The chute is a walled shaft dropping several z-levels: z128 to z126 and below.
- A pressure plate sits on the tile next to the hole, and a lever is in the same room.
- Quickfort export: `quickfort/scan_region51_c2.csv`.

## Work orders: the user's standing pattern

This section is an overview. The exact amounts and conditions are in the JSON files, so check those before turning any of this into df-ai stock goals.
- Verified in `start.json`: Daily "LessThan 10 → make 10" for beds, empty barrels, empty bins, gems and others, plus 2 BREW_DRINK_FROM_PLANT orders at "drink < 10". The brewing orders are inactive in that set.
- Order counts per set: 14–16 (starter sets), 40–85 (full sets), and 114 in `33.json`, which includes 32 EngraveSlab orders. The big sets have 16 SmeltOre orders, one per ore.

Seen in `start`, `starters`, `full`, `sss`, `stopwork` and the forts:
- **Furniture:** keep 10 of each (Daily, "less than 10 → make 10"): bed, door, chest, cabinet, throne, table, weapon rack, armor stand, hatch cover, blocks, mechanisms, slab, goblet.
- **Containers:** barrels and bins kept at 10.
- **Drinks:** two drink reactions, each "less than 10 → 10". Some sets use "less than 100".
- **Smelting:** each ore smelted only if at least 5 boulders of it are on hand, at least 100 bars total exist, and fewer than 10 bars of that metal. Alloy reactions are gated the same way.
- **Fuel:** charcoal kept at 120–200 bars. Ash → potash and lye run below 10, or above 5 inputs.
- **Cloth:** spin thread at 5 or more wool; weave at 5 or more thread, up to 100 cloth; dye at 5 or more cloth with 3 or more dyes.
- **Crafts:** bone/stone crafts made when there are more than 10 inputs.
- **Steel gear:** keep 10 each of weapons, helms, breastplates, gloves, greaves, leggings and shoes.
- **Hospital:** splints and crutches kept at 1 or more, made only if 50 or more wood.
