# df-ai for Dwarf Fortress 53.16 (Windows)

This build of df-ai targets **DFHack 53.16-r3** and **Dwarf Fortress 53.16**
(Steam, itch.io or Classic). A DFHack plugin only loads into the exact DFHack
version it was built for; to rebuild for a newer DFHack, run the GitHub
Actions workflow with a different `dfhack_ref`.

## Install

1. Install DFHack 53.16-r3 (Steam: add DFHack to your library, then **launch
   it from the DFHack app once** so it can install itself into Dwarf Fortress).
2. Find DFHack's `hack` folder. With the Steam version it may not be inside
   the Dwarf Fortress folder any more. In the DFHack console type:

       :lua print(dfhack.getHackPath())

3. Copy `hack/plugins/df-ai.plug.dll` from this zip into that folder's
   `plugins` subfolder.
4. Copy the `df-ai-blueprints` folder from this zip into your
   **Dwarf Fortress** folder (the one containing `Dwarf Fortress.exe`).
   If it's in the wrong place, df-ai prints the folder it expected.
5. If Windows blocks the DLL, right-click it → Properties → tick **Unblock**.

## Use

1. Start Dwarf Fortress with DFHack, create a world and **embark yourself**.
   (Automatic world generation and embarking are not supported in v50+.)
2. Once the fortress map has loaded, open the DFHack console and run:

       enable df-ai

   df-ai plans the fortress (the game may freeze for a few seconds while it
   does), unpauses, and starts working.
3. `ai` shows status, `ai report` writes `df-ai-report.log`, `disable df-ai`
   stops it. Settings live in `dfhack-config/df-ai.json`.

df-ai turns on DFHack's `autolabor` plugin to manage labors. Leave work
details alone while it runs.

## What changed for DF v50+

Old df-ai pressed keys in the game's menus. Those menus no longer exist,
so this version changes game data directly through DFHack instead:

- **Works directly:** digging, construction and furniture, workshops and
  furnaces, stockpiles (via DFHack's `stockpiles` plugin), zones (bedrooms,
  offices, dining halls, barracks, tombs, dungeons, pastures, ponds, dumps,
  gathering), locations (tavern, temple, library, guildhall, hospital),
  room ownership, work orders, squad room assignments, marking goods for
  trade, camera following.
- **Also direct:** squads (creation, uniforms, kill orders, training),
  appointing nobles, tavern keepers/performers/scholars, pasture assignment.
- **Manual for now** (df-ai logs a message once): embarking, the actual
  barter with caravans (goods are moved to the depot for you), answering
  petitions, convicting criminals, recognizing temple priesthoods,
  abandoning a fortress.

This port compiles and links against DFHack 53.16-r3 but has not yet been
played through in a live game, so expect rough edges. If something goes
wrong, `df-ai-debug.log` in the Dwarf Fortress folder has details.
