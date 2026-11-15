"""DNN, the Dwarf News Network: a generated cable-news channel about the fort.

Serves http://<host>:8769/ (all interfaces, so the LG TV app can load it):
  /                 the DNN page (dnn/web/index.html). ?obs=1 = OBS browser source
                    (the live-video box is transparent: OBS puts Game Capture under it)
  /copy.json        the merged copy library (dnn/copy/*.json, see dnn/COPY.md)
  /feed.json        fort data for the page, gathered from the broadsheet (:8765)
  /portrait.png?u=  a dwarf's portrait (relayed from the broadsheet)
  /game.jpg         the newest game frame (relayed from gamefeed :8766)
  /game.mjpg        the live game window (gamefeed's MJPEG): the TV's default picture
  /dfsound/<path>   Dwarf Fortress's own music and sound effects, straight from the game
                    install's data/sound (allowlisted folders, .ogg only, Range requests)
  /video.json       is the HLS restream of the OBS program up? {ok, hls}
  /hls/index.m3u8   that restream (cookie-free relay of mediamtx)

Default TV picture: the game window via /game.mjpg (free: gamefeed captures it anyway).

Optional "OBS mode" (the stream's full program, Herald included, as HLS): only when the
file supervisor/dnn_video.on exists, because on the stream laptop it costs ~0.7 of a CPU
core (DirectShow copies every 1080p60 Virtual Camera frame) and drops frames at 95%+ CPU.
OBS's Virtual Camera carries the program; this process then keeps two helpers running:
  mediamtx.exe   RTSP in on 127.0.0.1:8554, HLS out on 127.0.0.1:8888, relayed as /hls/
  ffmpeg.exe     dshow "OBS Virtual Camera" -> 960x540 30 fps -> h264_qsv -> rtsp
Both live in <repo>/../mediamtx (mediamtx.exe, mediamtx.yml, ffmpeg-*/bin/ffmpeg.exe).
OBS must be started with --startvirtualcam (supervisor.json "obs_virtualcam": true).
Only GET is served; nothing here writes to the game.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
WEB = HERE / "dnn" / "web"
COPY = HERE / "dnn" / "copy"
LOGS = HERE / "logs"
HERALD = os.environ.get("DNN_HERALD", "http://127.0.0.1:8765")      # tests: the LAN copy :8780
GAMEFEED = os.environ.get("DNN_GAMEFEED", "http://127.0.0.1:8766")
MTX_API = "http://127.0.0.1:9997"

CTYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
          ".css": "text/css; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml",
          ".ttf": "font/ttf", ".woff2": "font/woff2", ".json": "application/json"}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S ") + msg, flush=True)


def fetch(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


class Cache:
    """Tiny TTL cache for upstream GETs; on an upstream failure, serve the last good copy."""

    def __init__(self):
        self.d, self.lock = {}, threading.Lock()

    def get(self, key, ttl, make):
        now = time.time()
        with self.lock:
            hit = self.d.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
        try:
            val = make()
        except Exception as e:  # upstream down: stale is better than nothing
            if hit:
                return hit[1]
            raise e
        with self.lock:
            self.d[key] = (now, val)
            if len(self.d) > 400:  # portraits keyed by unit: keep it bounded
                for k in sorted(self.d, key=lambda k: self.d[k][0])[:100]:
                    del self.d[k]
        return val


CACHE = Cache()


def herald_json(name, ttl):
    return CACHE.get(name, ttl, lambda: json.loads(fetch(f"{HERALD}/{name}.json", 30)))


# ---------------------------------------------------------------- the copy library
_copy = {"sig": None, "body": b"{}"}


def copy_json():
    files = sorted(COPY.glob("*.json"))
    sig = tuple((f.name, f.stat().st_mtime) for f in files)
    if sig != _copy["sig"]:
        merged = {}
        for f in files:
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError) as e:
                log(f"copy: skipping {f.name}: {e}")
                continue
            for k, v in data.items():
                if k.startswith("_"):
                    continue
                if isinstance(v, dict) and isinstance(merged.get(k), dict):
                    for kk, vv in v.items():
                        merged[k].setdefault(kk, vv if not isinstance(vv, list) else [])
                        if isinstance(vv, list):
                            merged[k][kk] = merged[k][kk] + vv
                elif isinstance(v, list) and isinstance(merged.get(k), list):
                    merged[k] += v
                else:
                    merged[k] = v
        _copy["sig"], _copy["body"] = sig, json.dumps(merged, ensure_ascii=False).encode()
        log(f"copy: loaded {len(files)} files")
    return _copy["body"]


# ---------------------------------------------------------------- the feed
def _person(h, title=None):
    if not h or h.get("id") is None or not h.get("here", True) or h.get("alive") is False:
        return None
    return {"id": h["id"], "name": h.get("english") or h.get("name"), "title": title or h.get("profession") or ""}


def cast(pol, fort):
    """The on-air team, picked from the fort's officials and soldiers.

    Deterministic for a fort and game year, so the TV and the OBS scene show the same
    anchors, and the team changes every year like a real network reshuffle."""
    people, seen = [], set()
    for p in pol.get("local_posts", []) or []:
        q = _person(p.get("holder"), p.get("title"))
        if q and q["id"] not in seen:
            seen.add(q["id"]); people.append(q)
    for sq in pol.get("squads", []) or []:
        if sq.get("abroad"):
            continue
        for m in sq.get("members", []) or []:
            q = _person(m)
            if q and q["id"] not in seen:
                seen.add(q["id"]); people.append(q)
    people.sort(key=lambda p: p["id"])
    if not people:
        return []
    seed = sum(ord(c) for c in f"{fort.get('name')}{fort.get('year')}")
    order = []
    while people:  # a deterministic shuffle
        order.append(people.pop((seed + len(order) * 7) % len(people)))
    # politics.json ids are HISTORICAL FIGURE ids; portraits are keyed by UNIT id
    units = hf_units(tuple(p["id"] for p in order[:40]))
    order = [dict(p, hf=p["id"], id=units[p["id"]]) for p in order[:40] if units.get(p["id"], -1) >= 0] or order
    # anchors, reporter and pundits should have faces. DF only draws a portrait for a unit
    # it has rendered, and each try is a slow game call (5-30 s), so a background thread
    # probes the candidates one at a time and the cast prefers the ones with a face.
    FACES.want([p["id"] for p in order[:24]])
    faces = [p for p in order if FACES.known.get(p["id"])]
    rest = [p for p in order if not FACES.known.get(p["id"])]
    return (faces + rest)[:5]


HF_LUA = ("for _,id in ipairs({%s}) do local hf=df.historical_figure.find(id) "
          "print('HFU', id, hf and hf.unit_id or -1) end")


def hf_units(ids):
    """{histfig id: unit id} from the game (cached for an hour; {} when the game doesn't answer)."""
    def ask():
        import dfai_supervisor as sup   # same helper portraits.py uses; read-only lua
        out = sup.dfhack("lua", HF_LUA % ",".join(str(int(i)) for i in ids), timeout=20) or ""
        got = {}
        for ln in out.splitlines():
            f = ln.split()
            if len(f) == 3 and f[0] == "HFU":
                got[int(f[1])] = int(f[2])
        if not got:
            raise RuntimeError("no answer from the game")
        return got
    try:
        return CACHE.get(("hfu", ids), 3600, ask)
    except Exception as e:
        log(f"cast: histfig->unit lookup failed: {e!r}")
        return {}


class FaceProbe:
    TTL = 3600

    def __init__(self):
        self.known, self.at, self.queue, self.lock = {}, {}, [], threading.Lock()
        threading.Thread(target=self.loop, daemon=True).start()

    def want(self, ids):
        now = time.time()
        with self.lock:
            for i in ids:
                if now - self.at.get(i, 0) > self.TTL and i not in self.queue:
                    self.queue.append(i)

    def loop(self):
        while True:
            with self.lock:
                uid = self.queue.pop(0) if self.queue else None
            if uid is None:
                time.sleep(5)
                continue
            try:
                body = fetch(f"{HERALD}/portrait.png?u={uid}", 60)
                CACHE.get(f"portrait{uid}", 600, lambda: body)
                ok = bool(body)
            except Exception:
                ok = False
            self.known[uid], self.at[uid] = ok, time.time()
            time.sleep(2)   # be gentle with the game


FACES = FaceProbe()


def feed():
    st = herald_json("state", 4)
    out = {"ok": bool(st.get("ok")), "at": time.time(), "state": st}
    for name, ttl in (("recent", 60), ("stocks", 60), ("trade", 120), ("works", 120), ("politics", 120)):
        try:
            out[name] = herald_json(name, ttl)
        except Exception as e:
            out[name] = {"ok": False, "error": repr(e)}
    pol = out.pop("politics")
    out["cast"] = cast(pol if isinstance(pol, dict) else {}, st.get("fort") or {})
    out["civ"] = ((pol or {}).get("civ") or {}).get("name") if isinstance(pol, dict) else None
    # keep the page's download small: trim the big lists
    tr = out.get("trade") or {}
    if isinstance(tr.get("trades"), list):
        out["trade"] = {"ok": tr.get("ok"), "trades": [{k: t.get(k) for k in ("year", "season", "civ", "result")}
                                                         for t in tr["trades"][-3:]]}
    wk = out.get("works") or {}
    out["works"] = {"ok": wk.get("ok"), "built": (wk.get("built") or [])[-8:] if isinstance(wk.get("built"), list) else [],
                    "deep": {"status": (wk.get("deep") or {}).get("status"), "log": ((wk.get("deep") or {}).get("log") or [])[-3:]}}
    out["video"] = VIDEO.status()
    return out


# ---------------------------------------------------------------- video (OBS mode)
class Video:
    def __init__(self, enabled, mtx_dir):
        self.enabled, self.dir = enabled, Path(mtx_dir)
        self.mtx = self.ff = None
        self.ff_fail = 0
        self.ff_next = 0.0
        self.ready = False
        self.checked = 0.0

    def status(self):
        if not self.enabled:
            return {"ok": False, "hls": None, "why": "video off"}
        now = time.time()
        if now - self.checked > 5:
            self.checked = now
            try:
                d = json.loads(fetch(f"{MTX_API}/v3/paths/get/dnn", 3))
                self.ready = bool(d.get("ready"))
            except Exception:
                self.ready = False
        return {"ok": self.ready, "hls": "/hls/index.m3u8"}

    def ffmpeg_exe(self):
        hits = sorted(glob.glob(str(self.dir / "ffmpeg-*" / "bin" / "ffmpeg.exe")))
        return hits[-1] if hits else None

    @staticmethod
    def kill_stale():
        """Children of an earlier dnn.py that died outlive it; free their ports first."""
        ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'mediamtx.exe' -or "
              "($_.Name -eq 'ffmpeg.exe' -and $_.CommandLine -match 'rtsp://127.0.0.1:8554/dnn') } | "
              "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId }")
        try:
            r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, timeout=60)
            if r.stdout.strip():
                log(f"video: stopped stale helpers {r.stdout.split()}")
        except (OSError, subprocess.TimeoutExpired) as e:
            log(f"video: stale check failed: {e!r}")

    def obs_running(self):
        try:
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq obs64.exe", "/NH"], capture_output=True,
                                 text=True, timeout=20).stdout
            return "obs64.exe" in out.lower()
        except (OSError, subprocess.TimeoutExpired):
            return False

    def _spawn(self, args, logname, cwd):
        logf = open(LOGS / logname, "a", encoding="utf-8", errors="replace")
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
        return subprocess.Popen(args, cwd=str(cwd), stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                creationflags=flags)

    def loop(self):
        self.kill_stale()
        while True:
            try:
                self.step()
            except Exception as e:
                log(f"video: error {e!r}")
            time.sleep(5)

    def step(self):
        mtx = self.dir / "mediamtx.exe"
        if not mtx.exists():
            return
        if self.mtx is None or self.mtx.poll() is not None:
            if self.mtx is not None:
                log(f"video: mediamtx exited ({self.mtx.returncode}); restarting")
            self.mtx = self._spawn([str(mtx), str(self.dir / "mediamtx.yml")], "dnn_mediamtx.log", self.dir)
            time.sleep(2)
        ff = self.ffmpeg_exe()
        if not ff:
            return
        if self.ff is not None and self.ff.poll() is None:
            return
        if self.ff is not None:
            self.ff_fail += 1
            log(f"video: ffmpeg exited ({self.ff.returncode}), failure {self.ff_fail}")
            self.ff = None
            self.ff_next = time.time() + min(300, 10 * 2 ** min(self.ff_fail, 5))
        if time.time() < self.ff_next or not self.obs_running():
            return
        args = [ff, "-hide_banner", "-loglevel", "warning", "-nostdin",
                "-f", "dshow", "-rtbufsize", "64M", "-i", "video=OBS Virtual Camera",   # vcam runs at OBS's fps: no -framerate
                "-an", "-vf", "fps=30,scale=960:540,format=nv12",
                "-c:v", "h264_qsv", "-preset", "veryfast", "-b:v", "2000k", "-maxrate", "2000k", "-bufsize", "4000k",
                "-g", "60", "-bf", "0",
                "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/dnn"]
        self.ff = self._spawn(args, "dnn_ffmpeg.log", self.dir)
        self.ff_started = time.time()
        log("video: ffmpeg started (OBS Virtual Camera -> rtsp://127.0.0.1:8554/dnn)")
        # a run that lasted a while resets the backoff
        threading.Timer(120, self._reset_if_alive).start()

    def _reset_if_alive(self):
        if self.ff is not None and self.ff.poll() is None:
            self.ff_fail = 0


VIDEO = Video(False, ".")


class HlsRelay:
    """Relays mediamtx's HLS under /hls/ on this port.

    mediamtx (1.21+) answers the first playlist GET with a 302 + session cookie and a
    401 'session not found' without it. The TV's media player can't be trusted to keep
    cookies, so the cookie lives here, and the TV gets a plain cookie-free HLS stream
    from the same origin as the page (one firewall port)."""

    def __init__(self, base="http://127.0.0.1:8888/dnn/"):
        import http.cookiejar
        self.base, self.lock = base, threading.Lock()
        self.cj = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cj))

    def get(self, name):
        if not name or "/" in name or ".." in name or not name.endswith((".m3u8", ".ts", ".mp4", ".m4s")):
            raise ValueError("bad hls name")
        for attempt in (0, 1):
            try:
                with self.opener.open(self.base + name, timeout=15) as r:
                    return r.read(), r.headers.get("Content-Type") or "application/octet-stream"
            except urllib.error.HTTPError as e:
                if e.code in (401, 404) and attempt == 0:
                    with self.lock:
                        self.cj.clear()   # stale session: start a new one via index.m3u8
                    if name != "index.m3u8":
                        try:
                            self.opener.open(self.base + "index.m3u8", timeout=15).read()
                        except Exception:
                            pass
                    continue
                raise


HLS = HlsRelay()


# ---------------------------------------------------------------- the game's sounds
SOUND_DIRS = ("tracks/", "sounds/", "audio/ui/whoosh/", "audio/ui/scrolls/", "audio/actions/", "cards/")


def df_sound_root():
    try:
        import dfai_supervisor as sup
        return Path(sup.CFG["df_dir"]) / "data" / "sound"
    except Exception:
        return Path(r"C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress") / "data" / "sound"


def df_sound(rel):
    """Path of an allowlisted DF sound file, or None. Served from the user's own game
    install for their own TV; never copied into the repo."""
    from urllib.parse import unquote
    rel = unquote(rel).replace("\\", "/")
    if not rel.lower().endswith(".ogg") or ".." in rel or not rel.startswith(SOUND_DIRS):
        return None
    root = df_sound_root().resolve()
    f = (root / rel).resolve()
    return f if root in f.parents and f.is_file() else None


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype, code=200, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_file_range(self, f, ctype):
        """A static file with HTTP Range support (media players seek and probe with it)."""
        if f is None:
            return self.send_error(404)
        size = f.stat().st_size
        start, end = 0, size - 1
        rng = self.headers.get("Range") or ""
        partial = rng.startswith("bytes=")
        if partial:
            a, _, b = rng[6:].split(",")[0].partition("-")
            try:
                if a.strip():
                    start = int(a)
                    end = int(b) if b.strip() else size - 1
                else:
                    start = max(0, size - int(b))
            except ValueError:
                partial = False
            end = min(end, size - 1)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "max-age=86400")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        with open(f, "rb") as fh:
            fh.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = fh.read(min(65536, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)

    def relay_mjpg(self):
        """The live game window (gamefeed's MJPEG, ~10 fps) for the TV. gamefeed shares one
        capture between all viewers, so this costs no extra capture or encode on the game PC."""
        up = urllib.request.urlopen(f"{GAMEFEED}/game.mjpg", timeout=20)
        try:
            self.send_response(200)
            self.send_header("Content-Type", up.headers.get("Content-Type") or "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            while True:
                chunk = up.read1(65536) if hasattr(up, "read1") else up.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        finally:
            up.close()

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        u = urlparse(self.path)
        path = u.path
        try:
            if path in ("/", "/index.html"):
                path = "/index.html"
            if path == "/copy.json":
                return self.send(copy_json(), CTYPES[".json"])
            if path == "/feed.json":
                return self.send(json.dumps(feed(), ensure_ascii=False).encode(), CTYPES[".json"])
            if path == "/video.json":
                return self.send(json.dumps(VIDEO.status()).encode(), CTYPES[".json"])
            if path == "/portrait.png":
                q = parse_qs(u.query)
                uid = int((q.get("u") or ["-1"])[0])
                body = CACHE.get(f"portrait{uid}", 600, lambda: fetch(f"{HERALD}/portrait.png?u={uid}", 20))
                return self.send(body, "image/png", cache="max-age=600")
            if path.startswith("/dfsound/"):
                return self.send_file_range(df_sound(path[len("/dfsound/"):]), "audio/ogg")
            if path.startswith("/hls/"):
                body, ctype = HLS.get(path[5:])
                return self.send(body, ctype)
            if path == "/game.mjpg":
                return self.relay_mjpg()
            if path == "/game.jpg":
                body = CACHE.get("game.jpg", 0.4, lambda: fetch(f"{GAMEFEED}/game.jpg", 5))
                return self.send(body, "image/jpeg")
            f = (WEB / path.lstrip("/")).resolve()
            if WEB in f.parents and f.is_file() and f.suffix in CTYPES:
                return self.send(f.read_bytes(), CTYPES[f.suffix])
            self.send_error(404)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        except Exception as e:
            try:
                self.send(json.dumps({"ok": False, "error": repr(e)}).encode(), CTYPES[".json"], code=502)
            except OSError:
                pass


def main():
    global VIDEO
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8769)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--no-video", action="store_true", help="don't run mediamtx/ffmpeg (no OBS restream)")
    ap.add_argument("--mediamtx-dir", default=str(HERE.parent.parent / "mediamtx"))
    a = ap.parse_args()
    LOGS.mkdir(exist_ok=True)
    # the restream costs CPU on the stream machine: only on when dnn_video.on exists next to this file
    want = (HERE / "dnn_video.on").exists() and not a.no_video
    VIDEO = Video(want and Path(a.mediamtx_dir, "mediamtx.exe").exists(), a.mediamtx_dir)
    if VIDEO.enabled:
        threading.Thread(target=VIDEO.loop, daemon=True).start()
    else:
        log(f"video: off ({'no dnn_video.on' if not want else 'no mediamtx.exe in ' + a.mediamtx_dir})")
        Video.kill_stale()
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    log(f"DNN on http://{a.bind}:{a.port}/")
    srv.serve_forever()


if __name__ == "__main__":
    main()
