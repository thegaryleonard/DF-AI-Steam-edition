#!/usr/bin/env python3
"""df-ai game manager: keeps an unattended Dwarf Fortress + df-ai session alive.

Runs outside the game and talks to it through DFHack's dfhack-run.
  - crash recovery: DF process gone (or DFHack unresponsive) -> relaunch via
    Steam, load the newest save, re-enable df-ai
  - freeze recovery: game unpaused but the clock stopped -> close popups,
    then restart if it stays frozen
  - stuck-paused alert: paused for a long time while df-ai is on
  - diplomacy: opens and answers diplomat meetings (dfai-diplomacy.lua)
  - a quicksave every 20 min (bounds crash loss) and save backups on a timer
  - alerts via a notify file that a Discord cron job posts

Usage:  python dfai_supervisor.py            # run forever
        python dfai_supervisor.py --once     # print one status line and exit
Stdlib only.
"""
import json, os, shutil, subprocess, sys, time
from datetime import datetime
from pathlib import Path

CFG = {
    "df_dir": r"C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress",
    "save_dir": os.path.expandvars(r"%APPDATA%\Bay 12 Games\Dwarf Fortress\save"),
    "backup_dir": os.path.expandvars(r"%USERPROFILE%\DFBackups"),
    "notify_file": os.path.expandvars(r"%LOCALAPPDATA%\hermes\cache\dfai_notify.txt"),
    "mention": "<@YOUR_DISCORD_USER_ID>",
    "steam_app_id": "975370",
    "poll_s": 20,
    "freeze_s": 180,            # unpaused with no clock progress this long = frozen
    "paused_alert_s": 900,      # paused this long with df-ai on = alert once
    "unresponsive_s": 300,      # DF running but DFHack not answering this long = hung
    "quicksave_every_s": 20 * 60,  # bounds what a crash can lose
    "backup_every_s": 3 * 3600,
    "backups_keep": 6,
    "max_restarts_per_hour": 3,
    "launch_timeout_s": 300,
    "load_timeout_s": 600,
    "auto_new_fort": True,      # a fallen fort is abandoned and a new one embarked nearby (new_fort.py)
    "world_folder": "region58", # the world new forts embark in
    "obs_keeper": False,        # true = restart OBS and start streaming if it closes/crashes (obs_keeper.py)
}
CFG_FILE = Path(__file__).with_name("supervisor.json")
if CFG_FILE.exists():
    CFG.update(json.loads(CFG_FILE.read_text(encoding="utf-8")))

LOG = Path(__file__).with_name("supervisor.log")
DFHACK_RUN = str(Path(CFG["df_dir"]) / "hack" / "dfhack-run.exe")
DF_EXE = "Dwarf Fortress.exe"

STATUS_LUA = r"""
local t = {}
t.focus = dfhack.gui.getCurFocus(true)[1] or '?'
t.map = dfhack.isMapLoaded()
if t.map then
  t.year = df.global.cur_year
  t.tick = df.global.cur_year_tick
  t.paused = df.global.pause_state
  t.popups = #df.global.world.status.popups
  t.save = df.global.world.cur_savegame.save_dir
  local n = 0
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(u) then n = n + 1 end
  end
  t.citizens = n
end
local parts = {}
for k, v in pairs(t) do parts[#parts + 1] = k .. '=' .. tostring(v) end
print('STATUS ' .. table.concat(parts, ';'))
"""

CLOSE_POPUPS_LUA = r"""
local p = df.global.world.status.popups
local n = #p
for i = n - 1, 0, -1 do local m = p[i]; p:erase(i); m:delete() end
print('closed ' .. n)
"""


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def notify(msg, ping=False):
    log("NOTIFY " + msg)
    text = (CFG["mention"] + " " if ping else "") + "**df-ai game manager:** " + msg + "\n"
    try:
        with open(CFG["notify_file"], "a", encoding="utf-8") as f:
            f.write(text)
    except OSError as e:
        log(f"notify write failed: {e}")


def dfhack(*args, timeout=30):
    """Run a DFHack command. Returns its output, or None if DFHack didn't answer."""
    try:
        r = subprocess.run([DFHACK_RUN, *args], capture_output=True, timeout=timeout,
                           cwd=CFG["df_dir"])
    except (subprocess.TimeoutExpired, OSError):
        return None
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    if r.returncode != 0 and "STATUS" not in out and not out.strip():
        return None
    return out


def status():
    out = dfhack("lua", STATUS_LUA)
    if out is None:
        return None
    for line in out.splitlines():
        if line.startswith("STATUS "):
            d = {}
            for kv in line[7:].strip().split(";"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d[k] = {"true": True, "false": False}.get(v, int(v) if v.lstrip("-").isdigit() else v)
            return d
    return None


def ai_enabled():
    out = dfhack("enable") or ""
    for line in out.splitlines():
        if line.strip().startswith("df-ai:"):
            return line.strip().endswith("on")
    return None


def df_running():
    r = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {DF_EXE}", "/NH"],
                       capture_output=True, text=True)
    return DF_EXE.lower() in r.stdout.lower()


def kill_df():
    subprocess.run(["taskkill", "/F", "/IM", DF_EXE], capture_output=True)
    for _ in range(30):
        if not df_running():
            return
        time.sleep(1)


def newest_save():
    best = None
    for p in Path(CFG["save_dir"]).iterdir():
        if not p.is_dir() or p.name == "current" or not any(p.glob("world.*")):
            continue
        m = max((f.stat().st_mtime for f in p.iterdir()), default=0)
        if best is None or m > best[0]:
            best = (m, p.name)
    return best[1] if best else None


def wait_for(pred, timeout, step=5):
    end = time.time() + timeout
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(step)
    return None


TITLE_LUA = "local t=dfhack.gui.getViewscreenByType(df.viewscreen_titlest,0) or qerror('no title screen'); "


def load_save(folder):
    """Load a save from the title screen. DFHack's load-save script is broken on
    DF 53 and simulated keys are ignored, so this clicks on-screen text (window
    size independent) after scrolling the lists by data."""
    path = (Path(CFG["save_dir"]) / folder).as_posix()
    out = dfhack("lua", TITLE_LUA + f"""
for _,h in ipairs(t.savegame_header) do
  if h.full_path == '{path}' then print('WORLD '..h.world_name) return end
end
print('NOSAVE')""") or ""
    if "WORLD " not in out:
        log(f"load_save: {folder} not in the title screen's save list: {out.strip()[:200]}")
        return False
    world = out.split("WORLD ", 1)[1].strip()
    steps = [
        ("dfai-screen", "click", "Continue active game"),
        ("lua", TITLE_LUA + f"""
for i,h in ipairs(t.savegame_header_world) do
  if h.world_name == {json.dumps(world)} then t.scroll_position_world_choice=i print('OK') return end
end"""),
        ("dfai-screen", "click", "World: "),          # first visible row = the scrolled-to world
        ("lua", TITLE_LUA + f"""
for i,h in ipairs(t.savegame_header_game) do
  if h.full_path == '{path}' then t.scroll_position_game_choice=i print('OK') return end
end"""),
        ("dfai-screen", "click", "Folder: "),         # first visible row = the scrolled-to save
    ]
    for args in steps:
        out = (dfhack(*args) or "").strip()
        log(f"load_save {args[0]} {args[-1][:40]!r}: {out[:120]}")
        if "NOTFOUND" in out or ("lua" == args[0] and "OK" not in out):
            return False
        time.sleep(3)
    return True


def install_scripts():
    dst = Path(CFG["df_dir"]) / "dfhack-config" / "scripts"
    dst.mkdir(parents=True, exist_ok=True)
    for f in (Path(__file__).parent / "scripts").glob("*.lua"):
        shutil.copy2(f, dst / f.name)


def place_window():
    """Put the DF window where the stream layout expects it (OBS captures it
    there). Size also lives in prefs/init.txt WINDOWEDX/Y; position doesn't."""
    try:
        import ctypes
        x, y, w, h = CFG.get("window_rect", [510, 0, 1412, 1039])
        u = ctypes.windll.user32
        hwnd = None
        for _ in range(20):
            hwnd = u.FindWindowW(None, "Dwarf Fortress")
            if hwnd:
                break
            time.sleep(1)
        if not hwnd:
            log("place_window: DF window not found")
            return
        u.ShowWindow(hwnd, 9)  # SW_RESTORE
        u.SetWindowPos(hwnd, 0, x, y, w, h, 0x0004 | 0x0010)  # NOZORDER | NOACTIVATE
        log(f"DF window placed at {x},{y} {w}x{h}")
    except Exception as e:
        log(f"place_window failed: {e!r}")


def launch_and_load(save=None):
    """Start DF via Steam, load a save, enable df-ai. Returns True on success."""
    save = save or newest_save()
    log(f"launching DF, will load {save}")
    os.startfile(f"steam://rungameid/{CFG['steam_app_id']}")
    st = wait_for(lambda: (s := status()) and s.get("focus", "").startswith("title") and s,
                  CFG["launch_timeout_s"])
    if not st:
        log("DF did not reach the title screen")
        return False
    time.sleep(5)
    place_window()
    if not load_save(save):
        return False
    st = wait_for(lambda: (s := status()) and s.get("map") and s, CFG["load_timeout_s"], step=10)
    if not st:
        log("save did not finish loading")
        return False
    time.sleep(10)
    dfhack("enable", "df-ai")
    log(f"loaded {save}; df-ai enabled")
    return True


class Supervisor:
    def __init__(self):
        self.restarts = []
        self.last_tick = None          # (year, tick)
        self.last_progress = time.time()
        self.popups_closed_at = None
        self.paused_since = None
        self.paused_alerted = False
        self.unresponsive_since = None
        self.last_backup = time.time()
        self.last_quicksave = time.time()
        self.seen_crashlogs = self.crashlogs()
        log_path = Path(CFG["df_dir"]) / "df-ai.log"
        self.ai_log_pos = log_path.stat().st_size if log_path.exists() else 0

    def crashlogs(self):
        d = Path(CFG["df_dir"]) / "crashlogs"
        return set(p.name for p in d.glob("*.txt")) if d.exists() else set()

    def restart(self, reason):
        now = time.time()
        self.restarts = [t for t in self.restarts if now - t < 3600]
        if len(self.restarts) >= CFG["max_restarts_per_hour"]:
            notify(f"{reason}. Already restarted {len(self.restarts)} times this hour, so I'm "
                   "stopping auto-restarts until a human looks.", ping=True)
            raise SystemExit(2)
        self.restarts.append(now)
        new_logs = self.crashlogs() - self.seen_crashlogs
        self.seen_crashlogs |= new_logs
        extra = f" (crash log: {', '.join(sorted(new_logs))})" if new_logs else ""
        notify(f"{reason}{extra}. Restarting the game...", ping=True)
        if df_running():
            kill_df()
        ok = launch_and_load()
        self.last_progress = time.time()
        self.last_tick = None
        self.unresponsive_since = None
        self.paused_since = None
        notify("Back up and df-ai is running again." if ok else
               "Restart FAILED; the game needs a human.", ping=not ok)
        if not ok:
            raise SystemExit(3)

    def backup(self, st):
        save = st.get("save")
        src = Path(CFG["save_dir"]) / str(save)
        if not save or not src.is_dir():
            return
        # copy only a folder that isn't being written right now
        newest = max((f.stat().st_mtime for f in src.rglob("*") if f.is_file()), default=0)
        if time.time() - newest < 60:
            return
        dst_root = Path(CFG["backup_dir"])
        dst = dst_root / f"{save}-{datetime.now():%Y%m%d-%H%M}"
        shutil.copytree(src, dst)
        backups = sorted((p for p in dst_root.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime)
        for old in backups[:-CFG["backups_keep"]]:
            shutil.rmtree(old, ignore_errors=True)
        self.last_backup = time.time()
        log(f"backup -> {dst}")

    def diplomacy(self):
        """Answer diplomat meetings (DF 53 waits for a click on the DIPLOMACY
        alert; unanswered diplomats leave unhappy). A few steps per poll."""
        for _ in range(12):
            out = (dfhack("dfai-diplomacy") or "").strip()
            if not out or out.startswith("IDLE") or out.startswith("WAITING"):
                return
            log(f"diplomacy: {out[:300]}")
            if out.startswith("NEEDS-HUMAN") or out.startswith("STUCK"):
                if not getattr(self, "dip_alerted", False):
                    notify(f"a diplomat meeting needs a human: {out[:200]}", ping=True)
                    self.dip_alerted = True
                return
            self.dip_alerted = False
            time.sleep(2)

    def watch_ai_log(self):
        """Forward notable df-ai log lines (strange moods, deaths) to Discord."""
        path = Path(CFG["df_dir"]) / "df-ai.log"
        if not path.exists():
            return
        size = path.stat().st_size
        if size < self.ai_log_pos:          # log was rotated/truncated
            self.ai_log_pos = 0
        if size == self.ai_log_pos:
            return
        with path.open("rb") as f:
            f.seek(self.ai_log_pos)
            chunk = f.read(size - self.ai_log_pos).decode("utf-8", "replace")
        self.ai_log_pos = size
        for line in chunk.splitlines():
            # strange moods are handled by df-ai and, if one gets stuck, by the
            # mood watchdog (an agent job): log them, don't post them to Discord
            if "[MOOD]" in line and "needs" in line:
                log("mood: " + line.split("[MOOD]", 1)[1].strip()[:300])

    def step(self):
        now = time.time()
        if self.obs:
            try:
                self.obs.step()
            except Exception as e:
                log(f"obs keeper error: {e!r}")
        if not df_running():
            self.restart("Dwarf Fortress is not running (crashed?)")
            return
        st = status()
        if st is None:
            self.unresponsive_since = self.unresponsive_since or now
            if now - self.unresponsive_since > CFG["unresponsive_s"]:
                self.restart(f"DFHack hasn't answered for {int(now - self.unresponsive_since)}s (game hung)")
            return
        self.unresponsive_since = None
        if not st.get("map"):
            # title screen / menus: a human (or df-ai's embark) is doing something
            self.last_progress = now
            return

        # a fallen fort (no citizens left): abandon it and embark a new one nearby
        if st.get("citizens") == 0 and CFG.get("auto_new_fort", True):
            self.no_citizens_since = getattr(self, "no_citizens_since", None) or now
            if now - self.no_citizens_since > 180:
                notify("the fort has fallen (no citizens left). Abandoning it and embarking a new fort nearby.", ping=True)
                import new_fort
                name = new_fort.run("abandon")
                self.no_citizens_since = None
                self.last_progress = time.time()
                if name:
                    notify(f"new fort {name.split(chr(9))[0]} embarked; df-ai is running it.", ping=True)
                return
        else:
            self.no_citizens_since = None

        cur = (st.get("year"), st.get("tick"))
        if cur != self.last_tick:
            self.last_tick = cur
            self.last_progress = now
            self.popups_closed_at = None
        if st.get("paused"):
            self.last_progress = now   # paused isn't frozen
            self.paused_since = self.paused_since or now
            if (not self.paused_alerted and ai_enabled() is not False
                    and now - self.paused_since > CFG["paused_alert_s"]):
                notify(f"the game has been paused for {int((now - self.paused_since) / 60)} min "
                       f"(screen: {st.get('focus')}). df-ai may be stuck.", ping=True)
                self.paused_alerted = True
        else:
            self.paused_since = None
            self.paused_alerted = False
            stalled = now - self.last_progress
            if stalled > CFG["freeze_s"]:
                if self.popups_closed_at is None:
                    out = dfhack("lua", CLOSE_POPUPS_LUA) or ""
                    self.popups_closed_at = now
                    log(f"frozen {int(stalled)}s on {st.get('focus')}, popups={st.get('popups')}: {out.strip()}")
                elif now - self.popups_closed_at > 2 * CFG["freeze_s"]:
                    self.restart(f"game clock frozen for {int(stalled)}s on screen {st.get('focus')}")
                    return

        self.diplomacy()
        self.watch_ai_log()

        # room tour points of interest from df-ai's plan (dfai_poi.py)
        if now - getattr(self, "last_poi", 0) > 600:
            self.last_poi = now
            try:
                import importlib
                import dfai_poi
                importlib.reload(dfai_poi)   # pick up edits without restarting the supervisor
                dfai_poi.main()
            except Exception as e:
                log(f"poi refresh failed: {e!r}")

        if now - self.last_quicksave > CFG["quicksave_every_s"] and not st.get("paused"):
            self.last_quicksave = now
            out = (dfhack("quicksave", timeout=120) or "").strip()
            log(f"quicksave: {out[:100]}")

        if now - self.last_backup > CFG["backup_every_s"]:
            try:
                self.backup(st)
            except OSError as e:
                log(f"backup failed: {e}")
                self.last_backup = now

    def run(self):
        self.obs = None
        if CFG.get("obs_keeper"):
            from obs_keeper import ObsKeeper
            self.obs = ObsKeeper(CFG, log, notify)
            log("obs keeper on: OBS will be restarted and set streaming if it closes")
        install_scripts()
        log("started; watching the game.")
        while True:
            try:
                self.step()
            except SystemExit:
                raise
            except Exception as e:   # never die on a transient error
                log(f"error: {e!r}")
            time.sleep(CFG["poll_s"])


if __name__ == "__main__":
    if "--load" in sys.argv:
        install_scripts()
        print("loaded:", load_save(sys.argv[sys.argv.index("--load") + 1]))
    elif "--once" in sys.argv:
        print("running:", df_running(), "status:", status(), "newest save:", newest_save())
    else:
        Supervisor().run()
