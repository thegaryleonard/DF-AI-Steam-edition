#!/usr/bin/env bash
# deploy.sh: put supervisor/scripts/*.lua into the running game safely.
#   bash supervisor/deploy.sh dfai-pit dfai-mist     (named scripts)
#   bash supervisor/deploy.sh                         (every script that differs)
# For each one: copy, check it parses inside DFHack, and if onMapLoad.init
# starts it, run "<script> start" again so the loop runs the NEW code (an old
# loop keeps its old functions after a rewrite: that's how the mist planner
# crashed on stale state). Never runs anything else.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# Game on another machine: supervisor/remote_host.txt (gitignored) holds
# "<ssh host> <repo path there>", e.g. "gamepc C:/Users/you/dfai-stream/df-ai".
# Then the files go over by scp and this script runs there (Git Bash).
if [ -z "${DFAI_ON_HOST:-}" ] && [ -s "$HERE/remote_host.txt" ]; then
  read -r RH RREPO < "$HERE/remote_host.txt"
  scp -q "$HERE"/scripts/*.lua "$RH:$RREPO/supervisor/scripts/" && scp -q "$HERE/deploy.sh" "$HERE/onMapLoad.init.installed" "$RH:$RREPO/supervisor/" || { echo "deploy: copy to $RH failed"; exit 1; }
  exec ssh -o BatchMode=yes "$RH" "set DFAI_ON_HOST=1&& \"C:\\Program Files\\Git\\bin\\bash.exe\" \"$RREPO/supervisor/deploy.sh\" $*"
fi
DF="/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress"
DST="$DF/dfhack-config/scripts"
INIT="$DF/dfhack-config/init/onMapLoad.init"
RUN="$DF/hack/dfhack-run.exe"

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  for f in "$HERE"/scripts/*.lua; do
    n="$(basename "$f" .lua)"
    cmp -s "$f" "$DST/$n.lua" || names+=("$n")
  done
fi
[ ${#names[@]} -eq 0 ] && { echo "deploy: nothing changed"; exit 0; }

fail=0
for n in "${names[@]}"; do
  src="$HERE/scripts/$n.lua"
  [ -f "$src" ] || { echo "deploy: $n: no such script"; fail=1; continue; }
  cp "$src" "$DST/$n.lua"
  chk="$(cd "$DF" && timeout 20 "$RUN" lua "local f,e=loadfile(dfhack.getDFPath()..'/dfhack-config/scripts/$n.lua') print(f and 'OK' or ('PARSE ERROR: '..tostring(e)))" 2>&1 | tr -d '\r')"
  case "$chk" in
    OK*) ;;
    *) echo "deploy: $n: $chk"; fail=1; continue ;;
  esac
  if grep -q "^$n start" "$INIT" 2>/dev/null; then
    out="$(cd "$DF" && timeout 20 "$RUN" "$n" start 2>&1 | tr -d '\r' | head -1)"
    echo "deploy: $n: installed, loop restarted ($out)"
  else
    echo "deploy: $n: installed"
  fi
done
exit $fail
