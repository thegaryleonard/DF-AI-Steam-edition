#!/bin/bash
# Install a freshly built df-ai without hot-reloading it (unload can hang DF
# on a big fort): quicksave, wait for the save, stop DF, copy the plugin, and
# let the supervisor relaunch the game and load that save.
# Usage: bash supervisor/swap-plugin.sh   (run build-local.sh first, no "install")
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DF="/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress"
B="/c/dfbuild/dfhack/build/plugins/external/df-ai"
SUP="$HERE/logs/supervisor.log"
cd "$DF" || exit 1
timeout 60 ./hack/dfhack-run.exe lua "print(dfhack.isMapLoaded() and 'fort loaded' or 'NO MAP')" | grep -q "fort loaded" || { echo "no fort loaded: not swapping"; exit 1; }
timeout 60 ./hack/dfhack-run.exe quicksave >/dev/null 2>&1
sleep 45
touch "$HERE/logs/planned-restart"
powershell.exe -NoProfile -Command "Stop-Process -Name 'Dwarf Fortress' -Force" >/dev/null 2>&1
sleep 5
cp "$B/df-ai.plug.dll" "$B/df-ai.plug.pdb" "$DF/hack/plugins/" || exit 1
cp "$HERE/df-ai-plugin.lua" "$DF/hack/lua/plugins/df-ai.lua"
sleep 60
for i in $(seq 1 30); do
  sleep 10
  if timeout 20 ./hack/dfhack-run.exe plug df-ai 2>/dev/null | grep -q "enabled" && \
     timeout 20 ./hack/dfhack-run.exe lua "print(dfhack.isMapLoaded() and 'MAPOK' or '')" 2>/dev/null | grep -q MAPOK; then
    echo "swapped; game back up with df-ai running"; exit 0
  fi
  if tail -3 "$SUP" | grep -q "needs a human\|stopping auto-restarts"; then echo "supervisor gave up: run restart-supervisor.ps1"; exit 2; fi
done
echo "game not back after 6 minutes"; exit 3
