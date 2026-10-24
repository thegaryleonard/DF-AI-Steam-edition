#!/usr/bin/env bash
# Build df-ai.plug.dll locally with MSVC, the same way the GitHub workflow does.
#
#   supervisor/build-local.sh            build only
#   supervisor/build-local.sh install    build, then hot-swap into the running game
#
# First run configures DFHack (a few minutes); later runs only rebuild df-ai.
# Needs: DFHack source at $DFHACK (53.16-r3, with submodules), Visual Studio
# 2022 C++ tools, CMake, Ninja, Python with Jinja2.
set -euo pipefail
DFAI="$(cd "$(dirname "$0")/.." && pwd -W)"
DFHACK="${DFHACK:-C:/dfbuild/dfhack}"
DF="${DF:-/c/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress}"
VSDEV="${VSDEV:-C:/Program Files/Microsoft Visual Studio/2022/Professional/VC/Auxiliary/Build/vcvars64.bat}"

# df-ai lives in DFHack's external plugin folder as a junction to this clone
EXT="$DFHACK/plugins/external"
if [ ! -e "$EXT/df-ai/CMakeLists.txt" ]; then
  cmd //c "mklink /J $(cygpath -w "$EXT/df-ai") $(cygpath -w "$DFAI")" >/dev/null
fi
echo 'add_subdirectory(df-ai)' > "$EXT/CMakeLists.txt"

BAT="$(cygpath -w "${TMPDIR:-/tmp}")\\dfai-build.bat"
cat > "$(cygpath -u "$BAT")" <<EOF
@echo off
call "$(cygpath -w "$VSDEV")" >nul || exit /b 1
cd /d "$(cygpath -w "$DFHACK")"
if not exist build\\build.ninja (
  cmake -S . -B build -GNinja -DDFHACK_BUILD_ARCH=64 -DCMAKE_BUILD_TYPE=Release ^
    -DBUILD_STONESENSE:BOOL=OFF -DBUILD_DOCS:BOOL=OFF -DBUILD_TESTS:BOOL=OFF -DBUILD_DFLAUNCH:BOOL=OFF || exit /b 1
)
ninja -C build df-ai || exit /b 1
EOF
cmd //c "$BAT"
DLL=$(find "$DFHACK/build" -name 'df-ai.plug.dll' | head -1)
echo "built: $DLL"

if [ "${1:-}" = install ]; then
  RUN="$DF/hack/dfhack-run.exe"
  # never toggle df-ai in place (disable+enable crashes); unload/load instead
  "$RUN" disable df-ai >/dev/null 2>&1 || true
  "$RUN" unload df-ai
  cp "$DLL" "$DF/hack/plugins/"
  PDB="${DLL%.dll}.pdb"; [ -f "$PDB" ] && cp "$PDB" "$DF/hack/plugins/"
  "$RUN" load df-ai
  "$RUN" enable df-ai
  echo "installed and enabled"
fi
