# tlg01: a Twisted Logic Gaming style fort plan

`plans/tlg01.json` and the `rooms/*/tlg01_*` room types lay out a fort the way
Twisted Logic Gaming builds one in *Strike The Earth: Panama Canal* (DF Steam,
Ep01-Ep10). The notes taken from those transcripts, with timestamps, are in this folder.

Everything is generated: edit `tools/gen_tlg01.py`, then run

    python tools/gen_tlg01.py
    python tools/bpcheck.py --plan tlg01 --sims 20 --map tlg01_map.txt

`bpcheck.py` re-implements the C++ blueprint loader and the room placement
algorithm (flat test map, no caverns or water). It reports the same load errors
as `ai validate`, checks that every exit and limit refers to a real room or tag,
and checks that simulated embarks reach every minimum in `limits`.

## What follows TLG

| TLG practice | Where it shows up |
|---|---|
| Central 5x5 stair core, stairs in an X (four corners + centre) "to limit interactions" (Ep02) | `tlg01_start`, `tlg01_hub` |
| 11x11 hub: 3-wide halls in a cross, a 5x5 room in each corner; everything close to the stairs (Ep02) | every level of `tlg01_start` and `tlg01_hub`; the corner slots take workshops, hospital, jail, tombs, farms (`tlg01_hub_room` tag) |
| 3-wide main halls, no 1-wide hallways (Ep02, Ep05) | hubs, `tlg01_corridor`, `tlg01_bedrooms` |
| Odd room sizes, 3x3 minimum (Ep06) | 3x3 bedrooms, 5x5 corners, 7x7 hospital, 11x11 halls |
| Every workshop in its own room with a door, to lock in a failed mood (Ep02, Ep06) | `tlg01_workshop_3x3`: two cells, each `[pile][3x3 shop][pile]` behind a door |
| Stockpiles wrapped around / next to their workshops (Ep02, Ep06) | 1x3 input piles both sides of every shop; the starting carpenter and mason are ringed by wood / stone piles |
| Same workshops grouped together (4 craftsdwarf, 6 masons, 3 carpenters...) | each workshop blueprint is a pair of the same shop; limits allow 2-3 pairs of the busy ones |
| First year: food pile, carpenter, mason, farm, still + 5x5 drink room, 5x5 dormitory (Ep01-03) | start hub levels 1-2 and the first priorities |
| Manager and broker offices side by side (Ep02) | two 3x3 offices on hub level 2 |
| Individual 3x3 bedrooms: bed, cabinet, coffer, statue by the door; ~50 plus spares (Ep06) | `tlg01_bedroom`, `tlg01_bedrooms` (blocks of 6) |
| Dining hall rows `chair table table chair | aisle | chair table table chair`, 11x11 halls (Ep06, Ep08) | `tlg01_location` (tavern, temple, library, guildhall) |
| Mass-casualty hospital, beds for a quarter of the fort (Ep09) | `tlg01_infirmary` 7x7, 8 beds, 2 traction benches; splint/crutch stock goals |
| Tomb hall: centre aisle, tombs down both sides (Ep06) | `tlg01_cemetery` 5x9, 16 coffins, chains on |
| Keep dwarves inside; underground plump helmets, few surface plots (Ep03, Ep10) | outdoor farm limits cut to 0-4 / 0-6; more underground plots |
| Drink work orders well above need (Ep02: 20 when < 150; Ep09: < 300) | `stock_goals.drink` 100 + 3 per dwarf; extra barrels, bins, bags |
| Trapped entrance (stonefall hallway, Ep01-09) | ring of cage traps round the entrance, armed by "Entrance Static Defenses" (df-ai has no stonefall traps) |

## What does not (df-ai limits)

- No ramp entrance, drawbridge, lever room or airlocks: df-ai blueprints cannot
  express bridges/levers wiring, so the entrance is df-ai's stair entrance.
- The trade depot stays outdoors (TLG puts it underground off the ramp).
- The well cannot be forced to sit next to the hospital; both attach near the hubs.
- Stonefall/weapon traps, minecart drains, river U-pipes, swim trainers and magma
  work are out of scope for the blueprint format.
- Population cap (TLG uses 50) is a `d_init` setting, not a blueprint.

## Source gap

Only the Panama Canal series (Ep01-10, ~19 hours) plus some short Steam-era
videos were transcribed; YouTube rate-limited the rest of the channel (the
v47 Tutorial Fortress series, military / health care / FPS guides).
