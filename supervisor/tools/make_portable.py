"""Build the portable df-ai stream package (a zip with INSTALL.bat).

    python tools/make_portable.py [--out C:\\path\\dfai-portable.zip] [--no-save]

Quicksaves the running fort first (through dfhack-run) and copies the save only
once its files have stopped changing. Stdlib only.
"""
import argparse, json, os, shutil, subprocess, sys, time, zipfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent          # supervisor/
sys.path.insert(0, str(HERE))
import dfai_supervisor as sup                           # noqa: E402

DF = Path(sup.CFG["df_dir"])
USER = Path(sup.CFG["save_dir"]).parent                 # %APPDATA%\Bay 12 Games\Dwarf Fortress
WORLD = sup.CFG.get("world_folder", "region58")

SKIP_CONFIG = {"dfhack.history", "launcher.history", "command_counts.json", "steam_autocloud.vdf", "quickcmd.json.bak"}
SKIP_STREAM_DIRS = {"__pycache__", "logs", "mock", "portable"}
SKIP_STREAM_FILES = {"supervisor.log", "python.txt"}


def run(*a, timeout=120):
    try:
        return subprocess.run([str(DF / "hack" / "dfhack-run.exe"), *a], cwd=DF, capture_output=True,
                              text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"error: {e}"


def snapshot(p):
    return {str(f.relative_to(p)): (f.stat().st_size, f.stat().st_mtime) for f in p.rglob("*") if f.is_file()}


def copytree(src, dst, skip_dirs=(), skip_files=(), skip_ext=()):
    n = 0
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for f in files:
            if f in skip_files or f.endswith(tuple(skip_ext)):
                continue
            s = Path(root) / f
            d = dst / s.relative_to(src)
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path.home() / f"dfai-portable-{datetime.now():%Y%m%d}.zip"))
    ap.add_argument("--no-save", action="store_true", help="leave the fort and world out")
    ap.add_argument("--stage", default=str(Path(os.environ.get("TMPDIR") or os.environ.get("TEMP")) / "dfai-portable"))
    a = ap.parse_args()

    stage = Path(a.stage)
    if stage.exists():
        shutil.rmtree(stage)
    pkg = stage / "dfai-portable"
    pkg.mkdir(parents=True)

    # installer + readme
    for f in ("INSTALL.bat", "install.ps1", "README.txt"):
        shutil.copy2(HERE / "portable" / f, pkg / f)

    # game folder: DFHack as built here (no debug symbols), df-ai blueprints, dfhack-config
    g = pkg / "game"
    n = copytree(DF / "hack", g / "hack", skip_ext=(".pdb", ".so"))
    for f in ("dfhooks.dll", "dfhooks_dfhack.ini"):
        if (DF / f).exists():
            shutil.copy2(DF / f, g / f); n += 1
    n += copytree(DF / "df-ai-blueprints", g / "df-ai-blueprints")
    n += copytree(DF / "dfhack-config", g / "dfhack-config", skip_files=SKIP_CONFIG)
    print(f"game: {n} files")

    # version stamp the installer checks against
    ver = run("lua", "print(dfhack.getDFHackVersion()..' / '..dfhack.getDFVersion())", timeout=20) or "?"
    exe = (DF / "Dwarf Fortress.exe").stat().st_size
    (pkg / "VERSION.txt").write_text(f"{ver} exe_size={exe} built={datetime.now():%Y-%m-%d %H:%M}\n", encoding="utf-8")

    # user folder: prefs, mods, the fort and its world
    u = pkg / "appdata"
    copytree(USER / "prefs", u / "prefs")
    copytree(USER / "mods", u / "mods", skip_dirs={"mod_upload"})
    if not a.no_save:
        # DF 53's quicksave writes the next autosave slot, a little later: wait
        # for a world.sav newer than the request and pack that folder
        fort = None
        if run("lua", "print(dfhack.isMapLoaded())", timeout=20) == "true":
            t0 = time.time()
            run("quicksave", timeout=180)
            print("quicksaving the fort ...")
            for _ in range(60):
                time.sleep(5)
                fresh = [d for d in (USER / "save").iterdir()
                         if d.name != "current" and (d / "world.sav").exists() and (d / "world.sav").stat().st_mtime > t0]
                if fresh:
                    fort = max(fresh, key=lambda d: (d / "world.sav").stat().st_mtime).name
                    break
            if not fort:
                print("the quicksave did not appear; packing the newest save instead")
        fort = fort or sup.newest_save()
        src = USER / "save" / fort
        for attempt in range(6):            # copy only once the files sit still
            before = snapshot(src)
            time.sleep(15)
            if snapshot(src) == before:
                break
            print("save still being written, waiting ...")
        name = "Showerwheels" if fort.startswith("autosave") else fort
        before = snapshot(src)
        copytree(src, u / "save" / name)
        if snapshot(src) != before:
            sys.exit("the save changed while it was being copied - run again")
        print(f"fort: save '{fort}' packed as '{name}'")
        if WORLD != fort and (USER / "save" / WORLD).exists():
            copytree(USER / "save" / WORLD, u / "save" / WORLD)
            print(f"world: {WORLD}")

    # stream helpers (with the Herald's archive and memory)
    n = copytree(HERE, pkg / "stream", skip_dirs=SKIP_STREAM_DIRS, skip_files=SKIP_STREAM_FILES)
    for f in (HERE / "logs").glob("*.json"):       # desk and Herald state, not the logs
        (pkg / "stream" / "logs").mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, pkg / "stream" / "logs" / f.name)
    cfg = dict(json.loads((HERE / "supervisor.json").read_text(encoding="utf-8"))) if (HERE / "supervisor.json").exists() else {}
    (pkg / "stream" / "supervisor.json").write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    for f in ("HANDOVER.md", "INSTALL-WINDOWS.md"):
        if (HERE.parent / f).exists():
            shutil.copy2(HERE.parent / f, pkg / "stream" / f)
    print(f"stream helpers: {n} files")

    # OBS scenes (never the profile: it holds the stream key)
    scenes = Path(os.environ["APPDATA"]) / "obs-studio" / "basic" / "scenes"
    for f in scenes.glob("*.json"):
        (pkg / "obs" / "scenes").mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, pkg / "obs" / "scenes" / f.name)

    out = Path(a.out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(stage))
    print(f"package: {out} ({out.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
