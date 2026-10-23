# df-ai game manager

Keeps an unattended Dwarf Fortress + df-ai session alive. Runs outside the game
and talks to it through DFHack's `dfhack-run`. Python 3.8+, stdlib only.

    python dfai_supervisor.py              # run forever
    python dfai_supervisor.py --once       # one status line
    python dfai_supervisor.py --load "autosave 1"   # load a save from the title screen

What it does:
- DF process gone, or DFHack silent for 5 min: relaunch via Steam, load the
  newest save, `enable df-ai`, and alert.
- Unpaused but the clock stops for 3 min: close popups, then restart if still
  frozen after another 6 min.
- Paused for 15 min with df-ai on: one alert.
- Copies the loaded save to `%USERPROFILE%\DFBackups` every 3 h and keeps the
  newest 6. Skips folders written in the last minute.
- At most 3 restarts per hour, then it stops and alerts.

Alerts are appended to the notify file, which a cron job posts to Discord.
Override any setting in `supervisor.json` next to the script.

Loading: DFHack's `load-save` script is broken on DF 53 (`sel_menu_line` was
renamed), and simulated keys are ignored. `scripts/dfai-screen.lua` (installed
into `dfhack-config/scripts` on start) reads screen text and clicks it, so it
works at any window size. Lists are scrolled by data first
(`scroll_position_world_choice` / `scroll_position_game_choice`). Saves are
matched by `full_path`, because folder names such as "autosave 1" repeat across
the two save roots.
