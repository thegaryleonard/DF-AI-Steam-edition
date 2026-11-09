df-ai for Dwarf Fortress 53.17 (Steam)
======================================

df-ai plays Dwarf Fortress by itself: it digs the fort, builds the rooms,
farms, brews, trades, raises an army and fights. You watch.

YOU NEED
  - Dwarf Fortress 53.17 from Steam
  - DFHack 53.17-r1 from Steam (free: search the Steam Store for "DFHack")
    Start the game once after installing DFHack so it can set itself up.

INSTALL (2 minutes)
  1. Quit Dwarf Fortress.
  2. Unzip this download anywhere (right-click the zip > Extract All).
  3. Double-click INSTALL.bat. It finds the game, copies df-ai in, and
     backs up anything it replaces. Your saves are never touched.
     (If Windows says "Windows protected your PC": click "More info" >
      "Run anyway". That warning appears for any downloaded .bat file.)

PLAY
  1. Start Dwarf Fortress from Steam as usual.
  2. Create a world (or use one you have) and embark. Any embark works;
     a spot with trees, a river or brook, and no "aquifer" warning is best.
  3. When the fort map appears, press the ` key (top-left, under Esc) to
     open DFHack's command box, type    enable df-ai    and press Enter.
  4. That's it. df-ai plans the fort (the game may freeze for a few
     seconds), unpauses and gets to work.

  To stop it:            disable df-ai
  To see what it's doing:  ai
  Settings:  dfhack-config\df-ai.json in the game folder (open with Notepad)

THINGS TO KNOW
  - df-ai only takes over a NEW fort (a fresh embark), or a fort it was
    already running when you saved. It can't take over a fort you've been
    building by hand.
  - Forts you play yourself without "enable df-ai" are left alone; the
    helper scripts only start in forts where df-ai is switched on.
  - The game runs at up to 100 FPS normally and slows to 20 FPS during
    battles so you can watch. Change it with:   dfai-fps set 60
    or   dfai-fps battle 30   or turn it off:   dfai-fps dynamic off
  - Steam updates: df-ai works only with the exact game + DFHack versions
    above. To stop Steam updating DF under you: right-click Dwarf Fortress >
    Properties > Updates > "Only update this game when I launch it".

UNINSTALL
  Double-click UNINSTALL.bat. It removes only df-ai's files.

HELP
  https://github.com/thegaryleonard/DF-AI-Steam-edition  (see Troubleshooting)
