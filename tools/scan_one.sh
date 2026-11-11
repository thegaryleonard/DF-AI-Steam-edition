#!/bin/bash
# scan_one.sh "<World: text>" <scroll> "<save row text>" : load a save (never saves), dump designs,
# quickfort exports and work orders, then quit DF without saving.
DF="/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress"
S=C:/Users/dad/AppData/Local/hermes/cache/scratch/savescan
OUT=$S/out
cd "$DF"
R=./hack/dfhack-run.exe
q() { timeout 60 $R "$@" 2>&1; }
if ! tasklist | grep -qi "Dwarf Fortress.exe"; then
  powershell -NoProfile -Command "Start-Process 'steam://rungameid/975370'"; sleep 20
fi
for i in $(seq 1 60); do q lua "print('up')" | grep -q up && break; sleep 5; done
for i in $(seq 1 30); do q lua "print(dfhack.gui.getCurFocus(true)[1])" | grep -q '^title/Default' && break; sleep 3; done
sleep 5
echo "== $1 / $3"
q aitest-clicktext "Continue active game"; sleep 3
q lua "dfhack.gui.getCurViewscreen().scroll_position_world_choice=$2"; sleep 2
q aitest-clicktext "$1"; sleep 4
q aitest-clicktext "$3"
for i in $(seq 1 90); do q lua "print(dfhack.isMapLoaded())" | grep -q true && break; sleep 5; done
q lua "print('loaded', dfhack.isMapLoaded(), df.global.world.cur_savegame.save_dir, df.global.cur_year); df.global.d_init.feature.autosave = -1"
sleep 8
if q lua "print(dfhack.isMapLoaded())" | grep -q true; then
  q aiscan-designs "$OUT"
  NAME=$(q lua "print((df.global.world.cur_savegame.save_dir:gsub('[^%w%-_]', '_')))" | tr -d '\r\n')
  echo "save name: [$NAME]"
  python "$S/post_scan.py" "$NAME"
else
  echo "LOAD FAILED"; q aitest-clicktext --dump | grep -v '^ *[0-9]* *$' | head -20
fi
q die >/dev/null; sleep 15
tasklist | grep -qi "Dwarf Fortress.exe" && echo "DF still running" || echo "DF closed"
