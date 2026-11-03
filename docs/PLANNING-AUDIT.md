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
- [x] 2 axes, 3 picks for 183 dwarves; stocks wants 2 of each. Now 3 axes and
  4 picks per 100 dwarves on top of 2 spare, ordered before weapons while
  fewer than 2 are spare; melt-marked gear no longer counts as stock. The
  saved goal table no longer freezes goals at their founding values (the
  code's goals are floors). After: 239 logs (from 1), 5 picks, 3 axes.
- Consequence: 145 beds, 35 cabinets, 30 chests missing in finished rooms
  (all wood); 141 cage traps (mechanisms: 1 left); 135 statues.

## B. Tasks that wait on something that can never happen

- [x] 4 rooms stuck on tree trunks inside them: cleared once felling worked.
- [x] 12 deep-dig outpost corridors on hidden rock no miner can reach: parked
  by the stall detector (below).
- [x] 49 farm plots behind bucket irrigation, 3 at a time: the cap is now
  3 + 1 per 20 dwarves (12 at most). Mechanics 3-10 (2 for 141 traps).
- [x] 557 furnish tasks with no recorded reason: the reasons were never saved
  (the live ones had them). Saved now. They were: no statue (73), cabinet
  (34), chest (27), metal cage (18). Stock goals now follow what furniture
  waits for (up to 20 at a time), and statues can be ordered at all: df-ai
  had no order for them. After: 30 statues, 25 cabinets, 30 chests ordered.
- [x] Stall detector (digging): a room whose way in has no tile a miner can
  reach for two weeks is set aside (designations cleared) and retried every
  four weeks; `[STALL]` in the log. Furniture stalls are now covered by the
  demand-driven stock goals.

## C. Rooms over each other

- [x] dfai-build never sites a room on another zone's ground.
- [x] One check shared by the scripts: the plugin's `planned_room_at` (Lua),
  wrapped by `dfai-plan`. dfai-build, the well shaft and the catacombs never
  dig on ground df-ai has planned, dug or not.
- Not a bug: 8 bedrooms in one 5x5 box at the barracks level are a dorm (one
  bed each, each its own owner).

## D. Water (done this session)

- [x] Tap only fed water; replace a dead tap; wall it off first; hatch the
  tap stair; release the reserve when the tap dries; wells built when water
  arrives; stockpiles give up well tiles.

## E. Cost on the live stream

- [x] dfai-build search 36s -> 8s, now one area per check; keeps failed
  orders.
- [ ] Other map-wide scripts: check each for one-shot scans.

## F. Found on the way

- [x] Cistern: "river dry" looked at one river-feature tile by the breach; a dry
  bank tile kept the inlet shut beside a full river. Now any unfrozen, fed
  water there counts. Walled-off dead taps stay out of the plan.
- [x] Installing a build: `supervisor/swap-plugin.sh` (save, stop, copy,
  reload) instead of a hot reload, which hung the game twice; the supervisor
  doesn't count it as a crash.
- [ ] Fuel chain: wood -> charcoal -> bars -> tools. 88 bars free now; watch it.
