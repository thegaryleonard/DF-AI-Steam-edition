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

## Open items

- Not yet seen in a real siege: the muster and the battle camera.
- Not yet seen on a natural event: generous trading after the rounding fix
  (next caravan), the mood stall rescue, auto-abandon, and tribute missions.
- Vents over the Butchers and the Fishery wait on metal bars.
- War rule (user): pick fights only at 200 population and with metal armor.
  The goblin raids on The Destined Wickedness are approved conflict testing.
