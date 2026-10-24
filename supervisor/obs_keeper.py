"""Keep OBS running and streaming (used by dfai_supervisor when "obs_keeper" is on).

What it does when OBS (obs64.exe) is not running:
  1. clears OBS's crash sentinel (%APPDATA%/obs-studio/.sentinel/run_*), so
     OBS 30+ doesn't stop on the "OBS crashed, start in Safe Mode?" dialog;
  2. starts OBS from its own bin folder (OBS needs that working directory) with
     --startstreaming --minimize-to-tray --disable-updater
     --disable-missing-files-check, plus optional --profile/--collection/--scene.

A stream that drops while OBS keeps running is left to OBS's own auto-reconnect
(Settings > Advanced > Automatically Reconnect), which handled four Twitch
disconnects on 2026-10-24. Restarts are rate-limited so a broken OBS install
can't loop.
"""
import os
import subprocess
import time
from pathlib import Path

DEFAULTS = {
    "obs_exe": r"C:\Program Files\obs-studio\bin\64bit\obs64.exe",
    "obs_profile": "",       # empty = OBS's last used
    "obs_collection": "",
    "obs_scene": "",
    "obs_max_restarts_per_hour": 3,
    "obs_start_grace_s": 60,  # after a launch, wait this long before judging again
}


def obs_running():
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq obs64.exe", "/NH"],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None   # unknown: don't act
    return "obs64.exe" in out.lower()


def clear_sentinel():
    d = Path(os.path.expandvars(r"%APPDATA%\obs-studio\.sentinel"))
    n = 0
    if d.is_dir():
        for f in d.glob("run_*"):
            try:
                f.unlink()
                n += 1
            except OSError:
                pass
    return n


def launch_obs(cfg):
    exe = Path(cfg["obs_exe"])
    args = [str(exe), "--startstreaming", "--minimize-to-tray",
            "--disable-updater", "--disable-missing-files-check"]
    for key, flag in (("obs_profile", "--profile"), ("obs_collection", "--collection"), ("obs_scene", "--scene")):
        if cfg.get(key):
            args += [flag, cfg[key]]
    # detached: OBS must outlive the supervisor
    flags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen(args, cwd=str(exe.parent), creationflags=flags, close_fds=True)


class ObsKeeper:
    def __init__(self, cfg, log, notify):
        self.cfg = dict(DEFAULTS, **cfg)
        self.log, self.notify = log, notify
        self.launches = []
        self.last_launch = 0.0

    def step(self):
        now = time.time()
        if now - self.last_launch < self.cfg["obs_start_grace_s"]:
            return
        running = obs_running()
        if running is None or running:
            return
        self.launches = [t for t in self.launches if now - t < 3600]
        if len(self.launches) >= self.cfg["obs_max_restarts_per_hour"]:
            if len(self.launches) == self.cfg["obs_max_restarts_per_hour"]:
                self.notify("OBS keeps dying; stopped restarting it for this hour. The stream is down.", ping=True)
                self.launches.append(now)   # notify once
            return
        cleared = clear_sentinel()
        try:
            launch_obs(self.cfg)
        except OSError as e:
            self.log(f"obs: launch failed: {e}")
            self.launches.append(now)
            return
        self.launches.append(now)
        self.last_launch = now
        self.log(f"obs: was not running; started it streaming (cleared {cleared} crash sentinel(s))")
        self.notify("OBS was closed or crashed: restarted it and started the stream again.")
