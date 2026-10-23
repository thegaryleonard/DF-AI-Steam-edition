#!/usr/bin/env python3
"""Stream overlay server for df-ai.

Serves a sidebar page for OBS (Browser Source -> http://localhost:8765/,
size 480x1080) plus the JSON it renders:
  /state.json    live fort snapshot, refreshed every few seconds
  /history.json  artifact stories, scanned once per world (cached)
Stdlib only. Run alongside dfai_supervisor.py:
    python overlay.py
"""
import json, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

import dfai_supervisor as sup

PORT = 8765
STATE_EVERY_S = 4
HERE = Path(__file__).parent
cache = {"state": {"ok": False}, "history": {"artifacts": []}, "history_world": None}


def run_json(script, timeout=60):
    out = sup.dfhack(script, timeout=timeout)
    if not out or "{" not in out:
        return None
    try:
        return json.loads(out[out.index("{"):])
    except ValueError:
        return None


def poller():
    while True:
        st = run_json("dfai-overlay-state", timeout=20)
        if st is not None:
            cache["state"] = st
            world = (st.get("fort") or {}).get("world")
            if st.get("ok") and world and world != cache["history_world"]:
                h = run_json("dfai-overlay-history", timeout=180)
                if h:
                    cache["history"], cache["history_world"] = h, world
        time.sleep(STATE_EVERY_S)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/state.json"):
            body, ctype = json.dumps(cache["state"]).encode(), "application/json"
        elif self.path.startswith("/history.json"):
            body, ctype = json.dumps(cache["history"]).encode(), "application/json"
        elif self.path in ("/", "/index.html"):
            body, ctype = (HERE / "overlay.html").read_bytes(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    sup.install_scripts()
    threading.Thread(target=poller, daemon=True).start()
    print(f"overlay on http://localhost:{PORT}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
