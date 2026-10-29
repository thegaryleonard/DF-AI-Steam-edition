#!/usr/bin/env python3
"""Stream overlay server for df-ai.

Serves a sidebar page for OBS (Browser Source -> http://localhost:8765/,
size 480x1080) plus the JSON it renders:
  /state.json    live fort snapshot, refreshed every few seconds
  /history.json  artifact stories, scanned once per world (cached)
  /world.json    world map tiles + sites, read once per world (cached)
  /stocks.json   resource levels for the agriculture report, every 30 s
`python overlay.py --mock` serves mock/*.json instead of talking to the game.
Stdlib only. Run alongside dfai_supervisor.py:
    python overlay.py
"""
import json, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

import dfai_supervisor as sup
import herald_lore   # world history learned from play: past forts, their fates, absurd records

PORT = 8765
STATE_EVERY_S = 4
HERE = Path(__file__).parent
LIB_DIR = HERE / "herald" / "library"
SEEN_FILE = HERE / "herald" / "seen.json"   # library entry id -> unix time last printed, so issues don't repeat
seen_lock = threading.Lock()
MEMORY_FILE = HERE / "herald" / "memory.json"   # running stories: shortages, streaks, days-since counters, dwarf grievances
trade_cache = {"at": 0, "data": {"ok": False}}
works_cache = {"at": 0, "data": {"ok": False}}
cache = {"state": {"ok": False}, "history": {"artifacts": []}, "world": {}, "stocks": {}, "rumors": {}, "politics": {}, "history_world": None, "instruments": {}}
STOCKS_EVERY_S = 30
RUMORS_EVERY_S = 60   # news the fort has heard from diplomats, the liaison and caravans
MOCK = "--mock" in sys.argv


def deep_merge(into, new):
    """Library files can extend each other: lists concatenate, dicts merge recursively (e.g. interview_more.json adds headlines)."""
    for k, v in new.items():
        if k in into and isinstance(into[k], list) and isinstance(v, list):
            into[k] = into[k] + v
        elif k in into and isinstance(into[k], dict) and isinstance(v, dict):
            deep_merge(into[k], v)
        else:
            into[k] = v
    return into


def run_json(script, timeout=60):
    out = sup.dfhack(script, timeout=timeout)
    if not out or "{" not in out:
        return None
    try:
        return json.loads(out[out.index("{"):])
    except ValueError:
        return None


CLOCK_FILE = HERE / "herald" / "clock.json"   # real time -> game time, every half hour (for "While You Slept")
recap_cache = {"at": 0, "data": {}}


def remember_clock(st):
    """Note the game time once per real half hour (kept for 2 days)."""
    g = (st.get("fort") or {})
    year, tick = g.get("year"), g.get("tick")
    if year is None or tick is None:
        return
    try:
        clock = json.loads(CLOCK_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        clock = []
    now = int(time.time())
    g_abs = int(year) * 403200 + int(tick)
    # a crash reloads an older autosave: forget clock marks from the lost future
    kept = [c for c in clock if not (c[2] == g.get("name") and c[1] > g_abs)]
    if len(kept) != len(clock):
        clock = kept
        CLOCK_FILE.write_text(json.dumps(clock), encoding="utf-8")
    if clock and now - clock[-1][0] < 1800:
        return
    clock.append([now, int(year) * 403200 + int(tick), g.get("name")])
    clock = [c for c in clock if now - c[0] < 2 * 86400]
    CLOCK_FILE.write_text(json.dumps(clock), encoding="utf-8")


ISSUES = HERE / "herald" / "issues"        # the daily editions, kept for the archive
EVENTS_LOG = HERE / "herald" / "events.json"  # every big event seen, with real time (for the editions)


def log_big_events(st):
    """Keep every 'big' event (deaths, sieges, moods, artifacts...) with the real time it was seen."""
    big = st.get("big") or []
    if not big:
        return
    try:
        log = json.loads(EVENTS_LOG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        log = []
    ids = {e.get("id") for e in log}
    now = int(time.time())
    new = [dict(b, seen=now, fort=(st.get("fort") or {}).get("name")) for b in big if b.get("id") not in ids]
    if new:
        log = [e for e in log + new if now - e.get("seen", now) < 3 * 86400]
        EVENTS_LOG.write_text(json.dumps(log, ensure_ascii=False), encoding="utf-8")


def edition_now(now=None):
    """Which daily issue is out: the morning 'While You Slept' (6am-1pm, covering
    since 10pm last night) or the 'Evening News' (3pm-midnight, since 6am)."""
    lt = time.localtime(now or time.time())
    day = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    if 6 <= lt.tm_hour < 13:
        return "morning", day - 2 * 3600, time.strftime("%Y-%m-%d", lt)
    if lt.tm_hour >= 15:
        return "evening", day + 6 * 3600, time.strftime("%Y-%m-%d", lt)
    return None, None, None


def recap():
    """The current daily issue, in game terms (dfai-recap), archived to herald/issues/."""
    if time.time() - recap_cache["at"] < 300:
        return recap_cache["data"]
    now = time.time()
    ed, since, date = edition_now(now)
    data = {}
    if ed:
        try:
            clock = json.loads(CLOCK_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            clock = []
        fort = (cache["state"].get("fort") or {}).get("name")
        mine = [c for c in clock if c[2] == fort and c[0] >= since - 1800]
        if mine:
            start = mine[0]
            r = run_json_args(["dfai-recap", str(start[1])])
            if r:
                r.update(edition=ed, date=date, hours=max(1, round((now - start[0]) / 3600)), fort=fort)
                try:
                    done = json.loads((Path(sup.CFG["df_dir"]) / "dfhack-config" / "dfai-projects-done.json").read_text(encoding="utf-8"))
                    from collections import Counter
                    cnt = Counter(d.get("title") or d.get("name") or d.get("key") for d in done.get("done", []) if d.get("at", 0) >= start[0])
                    r["projects"] = [t if n == 1 else f"{t} (x{n})" for t, n in cnt.most_common()]
                except (OSError, ValueError, AttributeError):
                    r["projects"] = []
                try:
                    ev = json.loads(EVENTS_LOG.read_text(encoding="utf-8"))
                    r["big"] = [{"type": e.get("type"), "text": e.get("text")} for e in ev if e.get("seen", 0) >= start[0] and e.get("fort") == fort][-12:]
                except (OSError, ValueError):
                    r["big"] = []
                data = r
                try:
                    ISSUES.mkdir(parents=True, exist_ok=True)
                    (ISSUES / f"{date}-{ed}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1), encoding="utf-8")
                except OSError as e:
                    print(f"issue archive: {e}", flush=True)
    recap_cache["at"], recap_cache["data"] = now, data
    return data


def run_json_args(args, timeout=60):
    out = sup.dfhack(*args, timeout=timeout)
    if not out or "{" not in out:
        return None
    try:
        return json.loads(out[out.index("{"):])
    except ValueError:
        return None


def poller():
    last_stocks = last_rumors = 0
    while True:
        if time.time() - last_rumors > RUMORS_EVERY_S:
            last_rumors = time.time()
            ru = run_json("dfai-overlay-rumors", timeout=30)
            if ru is not None:
                cache["rumors"] = ru
            po = run_json("dfai-overlay-politics", timeout=30)   # offices, squads, diplomacy, work orders, crimes
            if po is not None:
                cache["politics"] = po
        if time.time() - last_stocks > STOCKS_EVERY_S:
            last_stocks = time.time()
            sk = run_json("dfai-overlay-stocks", timeout=30)
            if sk is not None:
                cache["stocks"] = sk
            ins = run_json_args(["dfai-instruments", "json"], timeout=30)   # the instrument collection
            if ins is not None:
                cache["instruments"] = ins
        st = run_json("dfai-overlay-state", timeout=20)
        if st is not None:
            cache["state"] = st
            try:
                log_big_events(st)
            except Exception as e:
                print(f"events: {e}", flush=True)
            try:
                remember_clock(st)
            except Exception as e:
                print(f"clock: {e}", flush=True)
            try:
                herald_lore.observe(st, cache["stocks"], cache["politics"], cache["rumors"])
            except Exception as e:   # the paper's memory must never stop the feed
                print(f"lore: {e}", flush=True)
            world = (st.get("fort") or {}).get("world")
            fort = (st.get("fort") or {}).get("name")
            if st.get("ok") and world and world != cache["history_world"]:
                h = run_json("dfai-overlay-history", timeout=180)
                if h:
                    cache["history"], cache["history_world"] = h, world
            # the map is per fort, not per world: a new embark in the same world moves the star and the weather
            if st.get("ok") and world and (world, fort) != cache.get("map_key"):
                m = run_json("dfai-overlay-world", timeout=120)
                if m:
                    cache["world"], cache["map_key"] = m, (world, fort)
        time.sleep(STATE_EVERY_S)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/state.json"):
            body, ctype = json.dumps(cache["state"]).encode(), "application/json"
        elif self.path.startswith("/history.json"):
            body, ctype = json.dumps(cache["history"]).encode(), "application/json"
        elif self.path.startswith("/stocks.json"):
            body, ctype = json.dumps(cache["stocks"]).encode(), "application/json"
        elif self.path.startswith("/politics.json"):
            body, ctype = json.dumps(cache["politics"]).encode(), "application/json"
        elif self.path.startswith("/lore.json"):
            world = ((cache["state"].get("fort") or {}).get("world")) or ""
            body, ctype = json.dumps(herald_lore.for_world(world), ensure_ascii=False).encode(), "application/json"
        elif self.path.startswith("/recap.json"):
            body, ctype = json.dumps(recap(), ensure_ascii=False).encode(), "application/json"
        elif self.path.startswith("/instruments.json"):
            body, ctype = json.dumps(cache["instruments"], ensure_ascii=False).encode(), "application/json"
        elif self.path.startswith("/rumors.json"):
            body, ctype = json.dumps(cache["rumors"]).encode(), "application/json"
        elif self.path.startswith("/world.json"):
            body, ctype = json.dumps(cache["world"]).encode(), "application/json"
        elif self.path.startswith("/library.json"):
            lib = {}
            for f in sorted(LIB_DIR.glob("*.json")):   # re-read each time so library edits show up on refresh
                try:
                    deep_merge(lib, json.loads(f.read_text(encoding="utf-8")))
                except ValueError as e:
                    print(f"library: bad JSON in {f.name}: {e}", flush=True)
            body, ctype = json.dumps(lib).encode(), "application/json"
        elif self.path.startswith("/seen.json"):
            body, ctype = (SEEN_FILE.read_bytes() if SEEN_FILE.exists() else b"{}"), "application/json"
        elif self.path.startswith("/memory.json"):
            body, ctype = (MEMORY_FILE.read_bytes() if MEMORY_FILE.exists() else b"{}"), "application/json"
        elif self.path.startswith("/works.json"):
            # construction in progress and the fort's goals (herald_works.py)
            import herald_works
            now = time.time()
            if now - works_cache["at"] > 120:
                try:
                    works_cache["data"] = herald_works.feed()
                except Exception as e:
                    works_cache["data"] = {"ok": False, "error": repr(e)}
                works_cache["at"] = now
            body, ctype = json.dumps(works_cache["data"], ensure_ascii=False).encode(), "application/json"
        elif self.path.startswith("/trade.json"):
            # caravans, deals and the liaison's wishes, from the logs (herald_trade.py)
            import herald_trade
            now = time.time()
            if now - trade_cache["at"] > 60:
                trade_cache["at"], trade_cache["data"] = now, herald_trade.feed()
            body, ctype = json.dumps(trade_cache["data"], ensure_ascii=False).encode(), "application/json"
        elif self.path.startswith("/portrait.png"):
            # the followed dwarf's sprite, for the On Camera card (portraits.py)
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            try:
                import portraits
                body = portraits.portrait_png(int((q.get("u") or ["-1"])[0]))
            except (ValueError, OSError) as e:
                print(f"portrait: {e!r}", flush=True)
                body = None
            if not body:
                self.send_error(404)
                return
            ctype = "image/png"
        elif self.path.split("?")[0] in ("/", "/index.html"):
            body, ctype = (HERE / "overlay.html").read_bytes(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/memory"):
            # the page owns the running-stories logic and stores its whole memory object here
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
            try:
                json.loads(raw)
            except ValueError:
                self.send_error(400)
                return
            with seen_lock:
                MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
                tmp = MEMORY_FILE.with_suffix(".tmp")
                tmp.write_bytes(raw)
                tmp.replace(MEMORY_FILE)
            self.send_response(204)
            self.end_headers()
            return
        # the page reports which library entries it just printed: {"ids": [...]}
        if not self.path.startswith("/seen"):
            self.send_error(404)
            return
        try:
            ids = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}").get("ids", [])
        except ValueError:
            ids = []
        with seen_lock:
            seen = json.loads(SEEN_FILE.read_text(encoding="utf-8")) if SEEN_FILE.exists() else {}
            now = int(time.time())
            seen.update({str(i): now for i in ids[:200]})
            SEEN_FILE.parent.mkdir(parents=True, exist_ok=True)
            SEEN_FILE.write_text(json.dumps(seen), encoding="utf-8")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


def load_mock():
    d = HERE / "mock"
    for key, name in (("state", "state.json"), ("history", "history.json"), ("world", "world.json"), ("stocks", "stocks.json"), ("rumors", "rumors.json"), ("politics", "politics.json")):
        f = d / name
        if f.exists():
            cache[key] = json.loads(f.read_text(encoding="utf-8"))


if __name__ == "__main__":
    if MOCK:
        load_mock()
    else:
        sup.install_scripts()
        threading.Thread(target=poller, daemon=True).start()
    print(f"overlay on http://localhost:{PORT}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
