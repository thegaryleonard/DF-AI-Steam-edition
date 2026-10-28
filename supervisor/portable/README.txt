df-ai stream - portable package
================================

Everything that runs the unattended Dwarf Fortress stream, ready to move to
another Windows PC:

  - DFHack 53.16-r3 exactly as built for this stream, with the df-ai plugin and
    its helpers (missions, portraits)
  - every df-ai script (war office, overseer jobs, mist, atom smasher, ascii,
    tours, builds, pastures, ...), their settings, and the blueprints
  - the current fort (Showerwheels) and its world (The Enchanted Planes,
    region58, where new forts embark), DF's settings and the Language Overhaul mod
  - the stream helpers: the Herald broadsheet (with its archive and world
    memory), the stream page, the Overseer's Desk, the Twitch chat logger and
    the game manager that keeps it all running
  - the OBS scene collection (scenes only - no stream key)


What the other PC needs first
-----------------------------
  1. Steam, signed in, with Dwarf Fortress installed (the Steam version).
     It must be the same DF version: 53.16. If Steam has moved DF on to a
     newer version, df-ai will not load until it is rebuilt for it.
     Tip: in Steam, Dwarf Fortress > Properties > Updates, pick
     "Only update this game when I launch it".
  2. DFHack from Steam is optional (this package brings its own copy).
  3. OBS Studio, if this PC is going to stream. Sign in to Twitch in
     OBS > Settings > Stream on that PC (stream keys are not copied).
  4. Python 3.10 or newer. The installer finds it, or offers to install
     Python 3.12 with winget.

Install
-------
  1. Quit Dwarf Fortress on both PCs. Unzip this folder anywhere.
  2. Double-click INSTALL.bat and answer its questions.
     It finds Dwarf Fortress through Steam, copies everything in and keeps a
     copy of every file it replaces (in "dfai-backup-<date>" folders inside the
     game folder and inside %APPDATA%\Bay 12 Games\Dwarf Fortress).
     Saves already on the PC are never touched.
  3. Double-click "DF-AI stream - start" on the desktop.
     It opens Dwarf Fortress through Steam, loads the fort, turns df-ai on and
     starts the web pages:
        broadsheet      http://localhost:8765/
        stream page     http://localhost:8766/
        overseer desk   http://localhost:8767/
     "DF-AI stream - stop" closes the helpers (not DF or OBS).

Run only one PC at a time: the fort is now a copy, and the two copies will
drift apart. Stop the stream on the old PC before starting the new one.

Not in the package
------------------
  - Discord pings and the hourly report: those come from the assistant on the
    original PC and do not move with the package.
  - The game log (gamelog.txt) and old saves, which are large and not needed.
  - df-ai's source code: it is on GitHub (thegaryleonard/DF-AI-Steam-edition,
    branch test-build-wd4062).
