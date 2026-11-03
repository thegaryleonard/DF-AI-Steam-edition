# Planning overhaul: audit (Channelevened, year 130, 183 citizens)

Read-only audit of df-ai's saved plan (1243 rooms, 685 tasks) and the live
fort, Nov 2026. Each finding: what the plan waits on, why it can never
happen, the generic fix. Status: [x] fixed, [ ] open.

## A. The economy was dead: no wood for a year (root cause of most of the rest)

- [x] Both axes were invaders' drops marked for melting by dfai-armory; a tool
  marked for melting is never picked up. Armory never melts axes/picks;
  dfai-toollabor unmarks them.
- [x] autolabor counts only military *professions* as soldiers, so it gave
  woodcutting/mining to militia, who won't take tools. dfai-toollabor owns
  MINE/CUTWOOD/HUNT (autolabor disabled for them): civilians only, as many as
  there are tools, existing holders first.
- [ ] 2 axes, 3 picks for 183 dwarves; stocks wants 2 of each. Scale with
  population; order them before weapons when bars are short.
- [ ] Fuel chain: wood -> charcoal -> bars -> tools. Check coal/lignite and
  make the planner aware of the chain (no wood = no metal).
- Consequence: 145 beds, 35 cabinets, 30 chests missing in finished rooms
  (all wood); 141 cage traps (mechanisms: 1 left); 135 statues.

## B. Tasks that wait on something that can never happen

- [ ] 4 rooms stuck on tree trunks inside them (felling was dead; also: mark
  trees in a planned room for felling when it is designated).
- [ ] 12 deep-dig outpost corridors on hidden rock no miner can reach.
- [ ] 49 farm plots behind bucket irrigation, 3 at a time (47 waiting). With a
  working well/cistern the cap should rise; farms on soil need none.
- [ ] 557 furnish tasks with no recorded reason (never reached?): check the
  furniture task loop's budget and record why each waits.
- [ ] Stall detector: every task records "waiting since"; past a deadline it
  is replanned, dropped, or surfaced (watchdog), never left forever.

## C. Rooms over each other

- [x] dfai-build never sites a room on another zone's ground.
- [ ] One tile-ownership check shared by df-ai rooms, zones and dfai-build
  (df-ai's own planner too, including rooms not yet dug).

## D. Water (done this session)

- [x] Tap only fed water; replace a dead tap; wall it off first; hatch the
  tap stair; release the reserve when the tap dries; wells built when water
  arrives; stockpiles give up well tiles.

## E. Cost on the live stream

- [x] dfai-build search 36s -> 8s; keeps failed orders.
- [ ] Time budget for every map-wide search (spread over ticks).
