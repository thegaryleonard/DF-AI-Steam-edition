"""Overseer console: the fort's commands on one page (user: "an overseer console
type page with overseer commands like im giving you now. fight wars, construct
this or that, order of construction priority...").

Usage: python -u overseer.py        -> http://localhost:8767/

Local only: binds 127.0.0.1 and is NOT behind lan_proxy (that mirror forwards
every GET), so nobody else on the network can run the fort. Commands are a fixed
allow-list run through DFHack (game-state changes inside the scripts already wait
for a game tick); nothing here builds a command from what the page sends.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import dfai_supervisor as sup

PORT = 8767
HERE = Path(__file__).parent
LOG_FILE = HERE / "logs" / "overseer.json"
log_lock = threading.Lock()

# key -> (group, label, help, dfhack args, timeout)
COMMANDS = {
    # war
    "war.raid":     ("War", "Send a raid now", "The next squad in line leaves at once, the camera follows it out.", ["dfai-war-office", "now", "follow"], 30),
    "war.hold":     ("War", "Hold the army home", "No more raids go out (the one abroad still comes back).", ["dfai-war-office", "hold", "overseer"], 30),
    "war.resume":   ("War", "Resume raids", "One raiding party out at a time, rotating targets.", ["dfai-war-office", "resume"], 30),
    "war.list":     ("War", "Targets", "Every site the war office can reach, nearest first.", ["dfai-war-office", "list"], 60),
    "beast.attack": ("War", "Beast hunt: go now", "Skip the rest of the muster and breach.", ["dfai-beast-hunt", "attack"], 30),
    # diplomacy
    "fo.now":       ("Diplomacy", "Send messengers", "Ask the neighbours for trade and visits now.", ["dfai-foreign-office", "now"], 30),
    "fo.list":      ("Diplomacy", "Relations", "Who we know and how they feel about us.", ["dfai-foreign-office", "list"], 60),
    # construction
    "mist.status":  ("Construction", "Mist generator", "Build and run state.", ["dfai-mist-build"], 30),
    "mist.prime":   ("Construction", "Prime the mist generator", "Opens a pond over a statue for a bucket or three (no top-ups).", ["dfai-mist-build", "prime"], 30),
    "camp.now":     ("Construction", "Deep camp: next step", "Dig or furnish the next piece of the deep camp.", ["dfai-deep-camp", "now"], 30),
    "dig.now":      ("Construction", "Deep dig: next 10 levels", "The shaft goes down another batch.", ["dfai-deep-dig", "now"], 30),
    "dig.stop":     ("Construction", "Deep dig: stop", "No more shaft levels.", ["dfai-deep-dig", "stop"], 30),
    "projects":     ("Construction", "Projects", "Everything being dug or built that the camera follows.", ["dfai-projects", "list"], 30),
    # camera
    "cam.next":     ("Camera", "Next room", "The tour moves on now.", ["dfai-room-tour", "next"], 30),
    "cam.statue":   ("Camera", "Show a statue", "The statue shown least recently, with its story.", ["lua", "reqscript('dfai-room-tour').show_statue_check()"], 30),
    "cam.leaves":   ("Camera", "Look at the trees", "Leaves mode: a breather on the nearest stand of trees.", ["lua", "reqscript('dfai-room-tour').show_leaves_check(true)"], 30),
    "cam.threats":  ("Camera", "Threats", "What the battle camera can see.", ["dfai-room-tour", "threats"], 30),
    # the fort
    "holiday.start": ("Fort", "Holiday party mode", "No jobs, no masters: everyone parties for N game days (about 1.5 min each), then every labor goes back as it was. Squads stay on guard.", ["dfai-holiday", "start", "{n}"], 30),
    "holiday.stop":  ("Fort", "End the holiday", "Back to work now.", ["dfai-holiday", "stop"], 30),
}
# orders that take a number: key -> (label, min, max, default)
PARAMS = {
    "holiday.start": ("days", 1, 28, 7),
}
STATUS = [
    ("War office", ["dfai-war-office"]),
    ("Beast hunt", ["dfai-beast-hunt"]),
    ("Mist generator", ["dfai-mist-build"]),
    ("Deep dig", ["dfai-deep-dig"]),
    ("Deep camp", ["dfai-deep-camp"]),
    ("Holiday", ["dfai-holiday"]),
]
PLANNED = [
    ("Construction", "Dig X levels down and scrub for ore", "A shaft of X levels with side galleries that mark every ore vein for mining."),
    ("Construction", "Construction priority", "Put the fort's planned rooms in the order you want them dug."),
]
status_cache = {"at": 0, "data": []}


def clean(out):
    return (out or "").replace("\r", "").strip()


def read_log():
    try:
        return json.loads(LOG_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def write_log(entry):
    with log_lock:
        log = read_log()
        log.insert(0, entry)
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        LOG_FILE.write_text(json.dumps(log[:100], ensure_ascii=False), encoding="utf-8")


def status():
    if time.time() - status_cache["at"] > 15:
        rows = []
        for label, args in STATUS:
            out = clean(sup.dfhack(*args, timeout=20))
            rows.append({"label": label, "text": out.splitlines()[-1] if out else "no answer from the game"})
        status_cache["at"], status_cache["data"] = time.time(), rows
    return status_cache["data"]


class Handler(BaseHTTPRequestHandler):
    def send(self, body, ctype="application/json", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self.send((HERE / "overseer.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/commands.json":
            cmds = [{"key": k, "group": g, "label": l, "help": h,
                     "param": dict(zip(("name", "min", "max", "default"), PARAMS[k])) if k in PARAMS else None}
                    for k, (g, l, h, _, _) in COMMANDS.items()]
            planned = [{"group": g, "label": l, "help": h} for g, l, h in PLANNED]
            self.send(json.dumps({"commands": cmds, "planned": planned}).encode())
        elif path == "/status.json":
            self.send(json.dumps(status(), ensure_ascii=False).encode())
        elif path == "/log.json":
            self.send(json.dumps(read_log()[:30], ensure_ascii=False).encode())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.split("?")[0] != "/run":
            self.send_error(404)
            return
        # only pages served from this machine (blocks other sites posting here)
        origin = self.headers.get("Origin") or ""
        if origin and not origin.startswith(("http://localhost:%d" % PORT, "http://127.0.0.1:%d" % PORT)):
            self.send_error(403)
            return
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        except ValueError:
            req = {}
        key = req.get("key")
        if key not in COMMANDS:
            self.send_error(400)
            return
        group, label, _, args, timeout = COMMANDS[key]
        if key in PARAMS:
            _, lo, hi, default = PARAMS[key]
            try:
                n = int(req.get("n", default))
            except (TypeError, ValueError):
                n = default
            n = max(lo, min(hi, n))   # only ever a clamped integer reaches the game
            args = [str(n) if a == "{n}" else a for a in args]
            label = f"{label} ({n} {PARAMS[key][0]})"
        out = sup.dfhack(*args, timeout=timeout)
        entry = {"at": time.strftime("%H:%M:%S"), "key": key, "label": label,
                 "ok": out is not None, "out": clean(out)[-2000:] if out is not None else "no answer from the game"}
        write_log(entry)
        status_cache["at"] = 0
        self.send(json.dumps(entry, ensure_ascii=False).encode())

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"overseer console on http://localhost:{PORT}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
