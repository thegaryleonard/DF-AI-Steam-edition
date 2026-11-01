#!/usr/bin/env bash
# Build the player download: dist/df-ai-<version>-DF53.16.zip
#
#   tools/release/make-release.sh [version]     (default: git describe)
#
# Needs a local build first (supervisor/build-local.sh), and the DFHack
# build tree at $DFHACK (default C:/dfbuild/dfhack).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DFHACK="${DFHACK:-C:/dfbuild/dfhack}"
VER="${1:-$(git -C "$(cygpath -w "$ROOT" 2>/dev/null || echo "$ROOT")" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)}"
NAME="df-ai-$VER-DF53.16"
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/game/hack/plugins" "$OUT/game/hack/lua/plugins" "$OUT/game/df-ai-blueprints" \
         "$OUT/game/dfhack-config/scripts" "$OUT/game/dfhack-config/blueprints" "$OUT/game/dfhack-config/init"

# the plugins
for p in df-ai dfai_missions dfai_portrait; do
  f=$(find "$DFHACK/build" -name "$p.plug.dll" | head -1)
  [ -n "$f" ] || { echo "missing $p.plug.dll - run supervisor/build-local.sh first"; exit 1; }
  cp "$f" "$OUT/game/hack/plugins/"
done
cp "$ROOT/portrait/dfai_portrait.lua" "$OUT/game/hack/lua/plugins/"

# df-ai's room and fort plans
cp -r "$ROOT/rooms" "$ROOT/plans" "$OUT/game/df-ai-blueprints/"

# the helper scripts (not the retired one-fort ones, not the test probes)
for f in "$ROOT"/supervisor/scripts/dfai-*.lua; do cp "$f" "$OUT/game/dfhack-config/scripts/"; done
# blueprints the helpers build from
cp -r "$ROOT"/supervisor/blueprints/* "$OUT/game/dfhack-config/blueprints/" 2>/dev/null || true
rm -f "$OUT/game/dfhack-config/blueprints/dfai-deep-camp.csv"

# starts the helpers when df-ai is switched on (DFHack runs every
# dfhack-config/init/onMapLoad*.init, so the player's own file is untouched)
cat > "$OUT/game/dfhack-config/init/onMapLoad-dfai.init" <<'EOF'
# df-ai helpers: they start by themselves once you run "enable df-ai" in a
# fort, and stay off in forts you play yourself. Delete this file to stop
# them starting at all.
dfai-helpers start
EOF

# installer, uninstaller, readme
cp "$ROOT"/tools/release/INSTALL.bat "$ROOT"/tools/release/install.ps1 \
   "$ROOT"/tools/release/UNINSTALL.bat "$ROOT"/tools/release/uninstall.ps1 "$OUT/"
cp "$ROOT/tools/release/README-FIRST.txt" "$OUT/"
cp "$ROOT/LICENSE" "$OUT/LICENSE.txt"
DF="${DF:-/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress}"
EXE_SIZE=$(stat -c %s "$DF/Dwarf Fortress.exe" 2>/dev/null || echo 0)
printf 'df-ai %s\nDwarf Fortress 53.16 (Steam)\nDFHack 53.16-r3\nexe_size=%s\n' "$VER" "$EXE_SIZE" > "$OUT/VERSION.txt"
# list of everything we put in the game folder, for the uninstaller
(cd "$OUT/game" && find . -type f | sed 's|^\./||' | sort) > "$OUT/FILES.txt"

# zip with forward-slash paths (PowerShell 5's Compress-Archive writes
# backslashes, which some unzip tools turn into odd file names)
PY="${PY:-C:/Users/dad/AppData/Local/Python/pythoncore-3.15-64/python.exe}"
command -v "$PY" >/dev/null 2>&1 || PY=python
(cd "$ROOT/dist" && "$PY" -c "
import os, sys, zipfile
name = sys.argv[1]
with zipfile.ZipFile(name + '.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for d, _, fs in os.walk(name):
        for f in fs:
            full = os.path.join(d, f)
            z.write(full, full.replace(os.sep, '/'))
" "$NAME")
echo "built: $ROOT/dist/$NAME.zip ($(du -h "$OUT.zip" | cut -f1))"
