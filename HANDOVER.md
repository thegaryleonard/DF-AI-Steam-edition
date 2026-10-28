# df-ai on DF 53.16 (Steam): handover

State of the port and the stream tooling for whoever picks this up next.
Written 2026-10-27, fort Showerwheels (site 350), game year 133.

## Branches

- `test-build-wd4062`: working branch. Every change is built locally with MSVC
  and hot-installed into the running game before it is committed.
- `v53-port`: stable. It is fast-forwarded from the working branch only after a
  crash-free soak run.

## Build and install

    bash supervisor/build-local.sh            # builds df-ai, dfai_portrait, dfai_missions
    bash supervisor/build-local.sh install    # also hot-swaps df-ai into the running game
    grep -n ": error" "$TMPDIR/dfai-localbuild.log"

GitHub Actions minutes are used up, so builds are local only. The portrait and
missions plugins call DF code at fixed addresses for v0.53.16 win64 STEAM. They
check those addresses first and do nothing on any other build.

## What runs where

| Piece | Where | What |
|---|---|---|
| df-ai plugin | C++ | Runs the fort. |
| dfai_missions | C++ plugin | Sends messengers, raids and tributes through DF's own army controller allocator and set_goal. It never opens the world screen. |
| dfai_portrait | C++ plugin | Builds portraits in the render pass. |
| dfai_supervisor.py | supervisor | Freeze watchdog, crash restarts (at most 3 an hour), quicksaves about every 20 min, diplomat meetings (dfai-diplomacy.lua), Discord notes. |
| overlay.py :8765 | supervisor | The Herald broadsheet (overlay.html, herald_*.py). |
| gamefeed :8766, lan_proxy :8780 | supervisor | The stream page and the LAN view. |
| overseer.py :8767 | supervisor | The Overseer's Desk: fort commands (war, diplomacy, construction, camera). Local only, never behind lan_proxy. |
| dfai-room-tour.lua | dfhack-config/scripts | Spectate camera: a busy-aware room tour, guests, the battle camera, and a watchdog that hands control back to spectate. |
| dfai-foreign-office.lua | scripts | Monthly. Sends messengers to open or improve trade with peaceful civs. |
| dfai-war-office.lua | scripts | Sends a squad to raid an enemy site about every 2 game months and logs the result for the Herald. |
| dfai-deep-dig.lua | scripts | A staircase shaft dug 10 levels at a time. It stops 3 levels above the magma sea or any water, and the miners then carve the Deep Hall. |

All of the scripts start from onMapLoad.init.

## Rules learned the hard way

- Never call DF internals from Lua or dfhack-run. Do it only in a C++ plugin,
  on a game tick or in the render pass. Game-state changes made from the
  console are deferred with `dfhack.timeout(1,'ticks')`.
- Never leave the world screen open. It pauses the game, and the freeze
  watchdog kills DF.
- Diplomat meetings that offer a choice used to freeze the game.
  dfai-diplomacy.lua now refuses the elves' tree quota and takes the first
  answer for anything else.
- Use `.at()` on stocks maps only after the stocks pass has filled them. Right
  after a load, the population code runs first. Use `find()`.
- A hidden designated tile that can only be reached by a staircase never gets
  a dig job. plan_task uncovers such tiles.
- Deep-dig orders are set to priority 1. At the default priority the miners
  always find a closer job first.

## Military (2026-10-27)

- Battle stations: when invaders or a great danger appear, every squad that is
  on the map switches to the Ready routine, in uniform, and its equipment is
  re-assigned.
- Squads with no target gather at the fort entrance. Kill orders go out once
  an invader is within 25 tiles of the gate, or within 10 tiles of a citizen.
- The squads stand down to staggered training after 8 quiet checks.
- Kill lists are cleared of targets that are dead or have left the map.
- Forging uses the best metal that has bars in hand. The fuel stock grows with
  the fort (12 bars plus 30 per 100 dwarves).
- Fuel comes from charcoal at the wood furnace and from coal veins, which are
  dug when fewer than 10 raw coal boulders are stocked.

## Next fort checklist (the owner's lessons from Showerwheels)

Before embarking:
- New embark in region58, random_embark off. Never touch the owner's real saves.
- Turn off end-of-fort mode: the war office's monthly raids and rotating targets were for ending Showerwheels. Next fort, raid only forts that offend or attack first, and only once the fort has 200 citizens and metal armor.

Layout:
- The cistern well overlaps the hospital, so the sick get water without a walk.
- One public tavern only. A citizens-only deep camp is fine.
- The first stockpile of each kind has no bins or barrels. Containers start with the second.
- The execution tower stays above ground; any new one goes underground.
- Vents go over a fishery or a butcher's shop open to the sky.
- The livestock pen must be big enough for its grazers: they ate the indoor pen's cave moss bare. Put grazers on cavern moss (dfai-pastures) and cap the herd.

Order of work:
- Food and drink first.
- Build the mist generator (walled entrance) before any cavern work. Prime it with one bucket of water; no top-ups.
- Deep digs go 10 levels at a time. Scrub for ore early (dfai-ore-scrub) so iron is known before the first siege.
- Armor: df-ai now orders armor to fill every soldier's uniform, not just a few spares. Check that the forges are busy once the army passes about 30.
- Fuel: mine coal, or burn wood into charcoal at a wood furnace.
- Trade: let caravans leave happy. Add gems and whatever is plentiful.

Never:
- Force strange moods, or fake a caravan.
- Leave the world screen open (the freeze watchdog kills DF after about 9 minutes).
- Run whole-map Lua scans on the live game.

## Open items

- Not yet seen in a real siege: the muster and the battle camera.
- Not yet seen on a natural event: generous trading after the rounding fix
  (next caravan), the mood stall rescue, auto-abandon, and tribute missions.
- Vents over the Butchers and the Fishery wait on metal bars.
- War rule (user): pick fights only at 200 population and with metal armor.
  The goblin raids on The Destined Wickedness are approved conflict testing.
