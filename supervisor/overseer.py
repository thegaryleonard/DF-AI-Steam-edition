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
import re
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
    "camp.now":     ("Construction", "Deep camp: check it", "The deep camp is the rest stop at level 38, at the bottom of the main shaft: a citizens-only tavern, a dormitory with 4 beds, a still and food, so the deep miners don't climb 130 levels for a drink. It is built. This re-checks it and digs or furnishes anything missing (a stolen bed, a broken still).", ["dfai-deep-camp", "now"], 30),
    "dig.now":      ("Construction", "Deep dig: next 10 levels", "The shaft goes down another batch.", ["dfai-deep-dig", "now"], 30),
    "dig.stop":     ("Construction", "Deep dig: stop", "No more shaft levels.", ["dfai-deep-dig", "stop"], 30),
    "ore.start":    ("Construction", "Dig down and scrub for ore", "A staircase N levels down with galleries on every level; every ore vein they expose is marked for mining. Picks the spot with the most ore and never digs near water, magma or caverns.", ["dfai-ore-scrub", "start", "{n}"], 30),
    "ore.stop":     ("Construction", "Stop the ore scrub", "No more veins marked (what is marked stays).", ["dfai-ore-scrub", "stop"], 30),
    "cavore.start": ("Construction", "Mine the caverns' ore", "Once a game day, marks every metal-ore tile showing in the caverns' walls (next to seen, reachable cavern floor; never beside water). As each is dug the next tile of the vein shows and is marked, so the veins get followed into the rock.", ["dfai-cavern-ore", "start"], 30),
    "health.now":   ("Construction", "Fort health check", "Once a game day: stone the masons may use, fertilizer vs potash, coffins for the dead, idle workshops and the army. Fixes what it safely can. This runs the check now.", ["dfai-fort-health", "now"], 30),
    "cavore.stop":  ("Construction", "Stop mining the caverns", "No new cavern ore is marked (what is marked stays marked).", ["dfai-cavern-ore", "stop"], 30),
    "pasture.cave": ("Construction", "Cavern pastures: use them", "Off by default (indoor pens are safer). Turns on the two big pens on the first cavern's grass and lets the herd spread into them.", ["dfai-pastures", "cavern", "on"], 30),
    "pasture.home": ("Construction", "Cavern pastures: bring the herd home", "Indoor pens only: grazers in the caverns come back as indoor grass allows, new indoor pasture rooms are ordered when the herd outgrows them, and autobutcher trims each species to its share of the grass.", ["dfai-pastures", "cavern", "off"], 30),
    "smasher":      ("Construction", "Atom smasher: check now", "The refuse chute and the execution pit drop onto 1-tile drawbridges at the bottom of the pit (level 157). Anything that lands on one is wiped out when the bridge swings up. While it is being built this checks the next step; once running it smashes whatever is lying there now.", ["dfai-atom-smasher", "now"], 30),
    "projects":     ("Construction", "What's being built", "Read-only: lists every big job the camera's mission mode is following right now (new rooms being dug, a cavern breach, the ore scrub) and how far along each is. The answer shows up in Orders Given on the right.", ["dfai-projects", "list"], 30),
    # camera
    "cam.next":     ("Camera", "Next room", "The tour moves on now.", ["dfai-room-tour", "next"], 30),
    "cam.statue":   ("Camera", "Show a statue", "The statue shown least recently, with its story.", ["dfai-room-tour", "statue"], 30),
    "cam.leaves":   ("Camera", "Look at the trees", "Leaves mode: a breather on the nearest stand of trees.", ["dfai-room-tour", "leaves"], 30),
    "cam.lock":     ("Camera", "Lock the camera here", "Holds the camera on what it shows right now. Spectate, the tour, projects and raid send-offs leave it alone until the time is up or you unlock it (minutes: 0 = until you unlock). A tour stop's \"lock\" link locks on that stop.", ["dfai-camera-lock", "here", "{n}"], 30),
    "cam.locktrees": ("Camera", "Lock on the trees", "Holds the camera on the thickest stand of surface trees. Every year it also locks there by itself from the 6th to the 10th of Limestone, while the leaves turn for autumn (a battle still gets the camera, then it goes back to the trees).", ["dfai-camera-lock", "trees", "{n}"], 30),
    "cam.unlock":   ("Camera", "Unlock the camera", "Back to the tour and spectate. Unlocking during the autumn days ends them for this year.", ["dfai-camera-lock", "off"], 30),
    "cam.threats":  ("Camera", "Threats", "What the battle camera can see.", ["dfai-room-tour", "threats"], 30),
    # the fort
    "holiday.start": ("Fort", "Holiday party mode", "No jobs, no masters: everyone parties for N game days (a minute or two each), then every labor goes back as it was. Squads stay on guard. Give it a name if you like; it goes on the Herald. The Fort Calendar below sets holidays that come round every year.", ["dfai-holiday", "start", "{n}"], 30),
    "holiday.stop":  ("Fort", "End the holiday", "Back to work now.", ["dfai-holiday", "stop"], 30),
}
# orders that take a number: key -> (label, min, max, default)
PARAMS = {
    "cam.lock": ("minutes", 0, 240, 0),
    "cam.locktrees": ("minutes", 0, 240, 10),
    "holiday.start": ("days", 1, 28, 7),
    "ore.start": ("levels", 1, 20, 10),
}
STATUS = [
    ("War office", ["dfai-war-office"]),
    ("Beast hunt", ["dfai-beast-hunt"]),
    ("Mist generator", ["dfai-mist-build"]),
    ("Deep dig", ["dfai-deep-dig"]),
    ("Deep camp", ["dfai-deep-camp"]),
    ("Holiday", ["dfai-holiday"]),
    ("Ore scrub", ["dfai-ore-scrub"]),
    ("Memorial", ["dfai-memorial"]),
    ("Building to order", ["dfai-build"]),
    ("Cavern ore", ["dfai-cavern-ore"]),
    ("Archer posts", ["dfai-archer-posts"]),
    ("Pastures", ["dfai-pastures"]),
    ("Catacomb wing", ["dfai-catacomb"]),
]
PLANNED = [
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
            rows.append({"label": label, "text": out.splitlines()[0] if out else "no answer from the game"})
        status_cache["at"], status_cache["data"] = time.time(), rows
    return status_cache["data"]


# ---- the fort calendar (dfai-holiday reads dfhack-config/dfai-holidays.json) ----
MONTHS = ["Granite", "Slate", "Felsite", "Hematite", "Malachite", "Galena", "Limestone", "Sandstone", "Timber", "Moonstone", "Opal", "Obsidian"]
HOLIDAYS_CFG = "dfai-holidays.json"


def clean_title(t):
    t = re.sub(r"[^A-Za-z0-9' ,.!-]", "", str(t or "")).strip()
    return re.sub(r"\s+", " ", t)[:40]


def calendar_read():
    c = read_json(df_path(HOLIDAYS_CFG), None)
    return c if isinstance(c, dict) else {"calendar": []}


def calendar_write(c):
    df_path(HOLIDAYS_CFG).write_text(json.dumps(c, indent=1), encoding="utf-8")


# ---- tour stops (dfai-room-tour writes the list; the off list is ours) ----
def df_path(name):
    return Path(sup.CFG["df_dir"]) / "dfhack-config" / name


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def stops():
    return read_json(df_path("dfai-tour-stops.json"), [])


# ---- blueprints (quickfort's own list; df-ai's exports and this fort's
# site scripts are left out: they only make sense where they were made) ----
BP_SKIP = re.compile(r"^(df-ai-|dfai-mist/|dfai-deep-camp|dfai-pasture)")
SAFE_FILE = re.compile(r"^[\w./ -]+\.(csv|xlsx)$")
SAFE_LABEL = re.compile(r"^[\w-]+$")
bp_cache = {"at": 0, "data": []}


def blueprints():
    if time.time() - bp_cache["at"] > 60:
        out = sup.dfhack("quickfort", "list", "-u", timeout=30) or ""
        rows = []
        for line in out.replace("\r", "").splitlines():
            m = re.match(r"^\s*(\d+)\) (.+?) -n /(\S+) \((\w+)(?::\s*(.*))?\)\s*$", line)
            if not m or BP_SKIP.match(m.group(2)):
                continue
            f, label, mode, note = m.group(2), m.group(3), m.group(4), (m.group(5) or "").strip()
            if mode == "notes" or not SAFE_FILE.match(f) or not SAFE_LABEL.match(label):
                continue
            rows.append({"file": f, "label": label, "mode": mode, "note": note})
        bp_cache["at"], bp_cache["data"] = time.time(), rows
    return bp_cache["data"]


def camera():
    out = sup.dfhack("lua", "local d=dfhack.gui.getDwarfmodeViewDims() print(df.global.window_x + (d.map_x2 - d.map_x1 + 1) // 2, "
                     "df.global.window_y + (d.map_y2 - d.map_y1 + 1) // 2, df.global.window_z)", timeout=20) or ""
    m = re.search(r"(-?\d+)\s+(-?\d+)\s+(-?\d+)", out)
    return {"x": int(m.group(1)), "y": int(m.group(2)), "z": int(m.group(3))} if m else None


# ---- construction order: df-ai's planned rooms, dug first in the order given ----
import glob, os
DIG_FILE = "dfai-overseer-dig.txt"
ROOM_WORDS = {"stockpile": "storeroom", "nobleroom": "noble room", "cemetery": "catacomb", "dininghall": "dining hall",
              "infirmary": "hospital", "farmplot": "farm plot", "tradedepot": "trade depot", "pitcage": "execution pit",
              "garbagedump": "refuse chute", "location": "", "outpost": "outpost"}


def plan_rooms():
    files = glob.glob(os.path.expandvars(r"%APPDATA%\Bay 12 Games\Dwarf Fortress\save\*\df-ai-plan.dat"))
    if not files:
        return [], None
    f = max(files, key=os.path.getmtime)
    try:
        plan = json.loads(Path(f).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return [], None
    out = []
    for r in plan.get("r", []):
        if r.get("status") not in ("plan", "dig") or r.get("type") == "corridor":
            continue
        t = r.get("type", "")
        sub = (r.get("stockpile_type") or r.get("nobleroom_type") or r.get("location_type") or r.get("workshop_type")
               or r.get("furnace_type") or r.get("farm_type") or r.get("outpost_type") or r.get("cistern_type") or "")
        word = ROOM_WORDS.get(t, t)
        name = (f"noble {sub}" if t == "nobleroom" else f"{sub} {word}").strip() if sub else word
        name = name.replace("_", " ")
        (x1, y1, z1), (x2, y2, z2) = r["min"], r["max"]
        out.append({"key": f"{x1},{y1},{z1}", "name": name[:1].upper() + name[1:], "type": t, "status": r["status"],
                    "size": f"{x2 - x1 + 1}x{y2 - y1 + 1}", "x": (x1 + x2) // 2, "y": (y1 + y2) // 2, "z": z1,
                    "comment": r.get("comment", "")})
    out.sort(key=lambda r: (r["type"], r["name"], -r["z"]))
    return out, os.path.getmtime(f)


def dig_order():
    try:
        return [l.strip() for l in df_path(DIG_FILE).read_text(encoding="utf-8").splitlines() if l.strip()]
    except OSError:
        return []


# ---- a status line on every card (user: "send a raid now: 1 raid out currently") ----
card_cache = {"at": 0, "data": {}}


def card_status():
    if time.time() - card_cache["at"] < 8:
        return card_cache["data"]
    out = sup.dfhack("dfai-overseer-status", timeout=20) or ""
    try:
        st = json.loads(out[out.index("{"):])
    except ValueError:
        return card_cache["data"]
    w = st.get("war") or {}
    abroad = w.get("abroad") or []
    out_now = ("Out now: " + "; ".join(abroad)) if abroad else "No raid out right now."
    held = w.get("hold")
    fo = st.get("foreign") or {}
    proj = st.get("projects") or []
    army = st.get("army") or {}
    army_line = f" Army: {army.get('soldiers', '?')} soldiers in {army.get('squads', '?')} squads, {army.get('citizens', '?')} citizens." if army else ""
    cards = {
        "war.raid": out_now + ("" if not w.get("last") else f" Last: {w['last']}.") + army_line,
        "war.hold": (f"Holding the army home ({held})." if held else "Raids are running: one party out at a time.") + army_line,
        "war.resume": f"Raids are on hold ({held})." if held else "Raids are already running.",
        "war.list": out_now,
        "beast.attack": st.get("beast", "?"),
        "fo.now": "The foreign office's records are unreadable; needs a look." if fo.get("broken") else f"{fo.get('envoys', 0)} envoy(s) on the road; {fo.get('contacts', 0)} civs contacted.",
        "fo.list": f"{fo.get('contacts', 0)} civs contacted.",
        "mist.status": st.get("mist", "?"),
        "mist.prime": st.get("mist", "?"),
        "camp.now": st.get("camp", "?"),
        "dig.now": st.get("dig", "?"),
        "dig.stop": st.get("dig", "?"),
        "ore.start": st.get("ore", "?"),
        "ore.stop": st.get("ore", "?"),
        "smasher": st.get("smasher", "?"),
        "pasture.cave": st.get("pastures", "?"),
        "pasture.home": st.get("pastures", "?"),
        "cavore.start": st.get("cavore", "?"),
        "cavore.stop": st.get("cavore", "?"),
        "health.now": st.get("health", "?") + (" | " + st["armory"] if st.get("armory") else "") + (" | " + st["seal"] if st.get("seal") else ""),
        "catacomb": st.get("catacomb", "?"),
        "projects": (f"{len(proj)} under way: " + ", ".join(proj)) if proj else "Nothing big under way.",
        "cam.next": "On camera: " + st.get("camera", "?"),
        "cam.statue": "On camera: " + st.get("camera", "?"),
        "cam.leaves": "On camera: " + st.get("camera", "?"),
        "cam.lock": "Camera " + st.get("camlock", "?"),
        "cam.locktrees": "Camera " + st.get("camlock", "?"),
        "cam.unlock": "Camera " + st.get("camlock", "?"),
        "cam.threats": f"{st.get('threats', 0)} threat(s) in view." if st.get("threats") else "No threats in view.",
        "holiday.start": st.get("holiday", "?"),
        "holiday.stop": st.get("holiday", "?"),
    }
    cards["_at"] = time.time()   # when the game last answered (a busy game can't, mid-battle)
    card_cache["at"], card_cache["data"] = time.time(), cards
    return cards


# ---- the game's Classic ASCII glyphs, live (dfai-ascii.lua clicks the game's own settings) ----
ASCII_CFG = "dfai-ascii.json"


def ascii_state():
    out = sup.dfhack("dfai-ascii", timeout=20) or ""
    line = (out.strip().splitlines() or [""])[0]
    m = re.search(r"game shows (\w+); mode (\w+)", line)
    cfg = read_json(df_path(ASCII_CFG), {"hours": [], "minutes": 5})
    return {"shows": m.group(1) if m else "?", "mode": m.group(2) if m else "?", "hours": cfg.get("hours", []),
            "minutes": cfg.get("minutes", 5), "line": line}


# ---- the fort's future: retire it, start a new fort here or in a new world ----
import subprocess, sys
NF_STATUS = Path(__file__).with_name("logs") / "new_fort_status.json"
nf_proc = {"p": None}


def fort_name():
    out = sup.dfhack("lua", "local s=dfhack.world.getCurrentSite() print(s and dfhack.df2utf(dfhack.translation.translateName(s.name,true)) or '')", timeout=20) or ""
    return out.strip()


def future_state():
    try:
        st = json.loads(NF_STATUS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        st = {}
    p = nf_proc["p"]
    alive = bool(p and p.poll() is None)
    st["running"] = alive or (st.get("running") and time.time() - NF_STATUS.stat().st_mtime < 4 * 3600 if NF_STATUS.exists() else False)
    st["fort"] = fort_name()
    st["world_folder"] = sup.CFG.get("world_folder")
    return st


# ---- build a room: any kind df-ai builds (dfai-build.lua) ----
kinds_cache = {"at": 0, "data": []}


def build_kinds():
    if time.time() - kinds_cache["at"] < 600 and kinds_cache["data"]:
        return kinds_cache["data"]
    out = sup.dfhack("dfai-build", "kinds", timeout=20) or ""
    try:
        kinds_cache["data"], kinds_cache["at"] = json.loads(out[out.index("["):]), time.time()
    except ValueError:
        pass
    return kinds_cache["data"]


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
        elif path == "/stops.json":
            self.send(json.dumps(stops(), ensure_ascii=False).encode())
        elif path == "/blueprints.json":
            self.send(json.dumps(blueprints(), ensure_ascii=False).encode())
        elif path == "/buildkinds.json":
            out = sup.dfhack("dfai-build", timeout=20) or ""
            self.send(json.dumps({"kinds": build_kinds(), "status": out.strip().splitlines()[0] if out.strip() else ""}, ensure_ascii=False).encode())
        elif path == "/future.json":
            self.send(json.dumps(future_state(), ensure_ascii=False).encode())
        elif path == "/calendar.json":
            self.send(json.dumps({"calendar": calendar_read().get("calendar", []), "months": MONTHS}).encode())
        elif path == "/ascii.json":
            self.send(json.dumps(ascii_state()).encode())
        elif path == "/cardstatus.json":
            self.send(json.dumps(card_status(), ensure_ascii=False).encode())
        elif path == "/plan.json":
            rooms, at = plan_rooms()
            self.send(json.dumps({"rooms": rooms, "order": dig_order(),
                                  "saved": time.strftime("%H:%M", time.localtime(at)) if at else None}, ensure_ascii=False).encode())
        elif path == "/camera.json":
            self.send(json.dumps(camera()).encode())
        elif path == "/log.json":
            self.send(json.dumps(read_log()[:30], ensure_ascii=False).encode())
        else:
            self.send_error(404)

    def answer(self, label, key, out):
        entry = {"at": time.strftime("%H:%M:%S"), "key": key, "label": label,
                 "ok": out is not None, "out": clean(out)[-2000:] if out is not None else "no answer from the game"}
        write_log(entry)
        status_cache["at"] = card_cache["at"] = 0
        self.send(json.dumps(entry, ensure_ascii=False).encode())

    def do_POST(self):
        path = self.path.split("?")[0]
        # only pages served from this machine (blocks other sites posting here)
        origin = self.headers.get("Origin") or ""
        if origin and not origin.startswith(("http://localhost:%d" % PORT, "http://127.0.0.1:%d" % PORT)):
            self.send_error(403)
            return
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        except ValueError:
            req = {}
        if path == "/stop":
            # switch tour stops on or off (one key, or a list); only keys the tour itself listed
            known = {s_["key"]: s_ for s_ in stops()}
            keys = req.get("keys") if isinstance(req.get("keys"), list) else [req.get("key")]
            keys = [k for k in keys if k in known]
            if not keys:
                self.send_error(400)
                return
            off_path = df_path("dfai-tour-off.json")
            off = set(read_json(off_path, []))
            for k in keys:
                if req.get("on"):
                    off.discard(k)
                else:
                    off.add(k)
            off_path.write_text(json.dumps(sorted(off), ensure_ascii=False), encoding="utf-8")
            sup.dfhack("dfai-room-tour", "stops", timeout=20)
            self.send(json.dumps({"ok": True, "off": len(off)}).encode())
            return
        if path == "/build":
            kinds = {k["key"]: k for k in build_kinds()}
            kind = req.get("kind")
            if kind not in kinds:
                self.send_error(400)
                return
            try:
                n = max(1, min(5, int(req.get("n", 1))))
            except (TypeError, ValueError):
                n = 1
            out = sup.dfhack("dfai-build", "new", kind, str(n), timeout=20)
            self.answer(f"Build: {n} x {kinds[kind]['label']}", "build." + kind, out)
            return
        if path == "/future":
            # the biggest order on the desk: only with the fort's name typed back
            mode = req.get("mode")
            st = future_state()
            if mode not in ("fort", "world"):
                self.send_error(400)
                return
            if st.get("running"):
                self.send(json.dumps({"ok": False, "why": "a new fort is already being made"}).encode())
                return
            name = st.get("fort") or ""
            if not name or (req.get("confirm") or "").strip().lower() != name.lower():
                self.send(json.dumps({"ok": False, "why": f"type the fort's name ({name or 'no fort loaded'}) to confirm"}).encode())
                return
            args = [sys.executable, str(Path(__file__).with_name("new_fort.py"))] + (["--new-world"] if mode == "world" else [])
            log_f = open(Path(__file__).with_name("logs") / "new_fort_run.log", "a", encoding="utf-8")
            nf_proc["p"] = subprocess.Popen(args, cwd=str(Path(__file__).parent), stdout=log_f, stderr=subprocess.STDOUT,
                                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            label = f"Retire {name}: " + ("a new world and a new fort" if mode == "world" else "a new fort in this world")
            write_log({"at": time.strftime("%H:%M:%S"), "key": "future." + mode, "label": label, "ok": True, "out": "started; progress shows on the desk"})
            self.send(json.dumps({"ok": True}).encode())
            return
        if path == "/ascii":
            mode = req.get("mode")
            if mode not in ("on", "off", "auto"):
                self.send_error(400)
                return
            sup.dfhack("dfai-ascii", mode, timeout=20)
            time.sleep(1.5)
            st = ascii_state()
            write_log({"at": time.strftime("%H:%M:%S"), "key": "game.ascii", "label": {"on": "Game to ASCII", "off": "Game to graphics", "auto": "Game display: follow the ASCII schedule"}[mode],
                       "ok": True, "out": st["line"]})
            self.send(json.dumps(st).encode())
            return
        if path == "/calendar":
            # add / remove a yearly holiday; every field is checked and clamped here
            cal = calendar_read()
            days = cal.setdefault("calendar", [])
            op = req.get("op")
            if op == "add":
                name, month = clean_title(req.get("name")), req.get("month")
                try:
                    day, n = max(1, min(28, int(req.get("day", 1)))), max(1, min(28, int(req.get("days", 3))))
                except (TypeError, ValueError):
                    self.send_error(400)
                    return
                if not name or month not in MONTHS or len(days) >= 24:
                    self.send_error(400)
                    return
                days[:] = [h for h in days if h.get("name") != name]
                days.append({"name": name, "month": month, "day": day, "days": n})
                days.sort(key=lambda h: (MONTHS.index(h["month"]) if h.get("month") in MONTHS else 99, h.get("day", 1)))
                what = f"added {name}: the {day} {month}, {n} days"
            elif op == "del":
                name = req.get("name")
                if not any(h.get("name") == name for h in days):
                    self.send_error(400)
                    return
                days[:] = [h for h in days if h.get("name") != name]
                what = f"removed {name}"
            else:
                self.send_error(400)
                return
            calendar_write(cal)
            write_log({"at": time.strftime("%H:%M:%S"), "key": "holiday.calendar", "label": "Fort calendar", "ok": True, "out": what})
            self.send(json.dumps({"calendar": days, "months": MONTHS}).encode())
            return
        if path == "/ascii_schedule":
            try:
                hours = sorted({int(h) for h in req.get("hours", []) if 0 <= int(h) <= 23})
                minutes = max(1, min(30, int(req.get("minutes", 5))))
            except (TypeError, ValueError):
                self.send_error(400)
                return
            df_path(ASCII_CFG).write_text(json.dumps({"hours": hours, "minutes": minutes}), encoding="utf-8")
            st = ascii_state()
            write_log({"at": time.strftime("%H:%M:%S"), "key": "game.ascii_schedule", "label": "ASCII schedule set", "ok": True,
                       "out": (f"last {minutes} min of " + ", ".join(f"{h}:00" for h in hours) + " hours") if hours else "no scheduled ASCII"})
            self.send(json.dumps(st).encode())
            return
        if path == "/dig":
            # the construction order: add / remove / up / clear; keys must be planned rooms
            rooms = {r["key"]: r for r in plan_rooms()[0]}
            order = dig_order()
            op, k = req.get("op"), req.get("key")
            if op == "clear":
                order = []
            elif k not in rooms and not (op == "remove" and k in order):
                self.send_error(400)
                return
            elif op == "add" and k not in order:
                order.append(k)
            elif op == "remove" and k in order:
                order.remove(k)
            elif op == "up" and k in order and order.index(k) > 0:
                i = order.index(k)
                order[i - 1], order[i] = order[i], order[i - 1]
            df_path(DIG_FILE).write_text("\n".join(order) + ("\n" if order else ""), encoding="utf-8")
            name = rooms.get(k, {}).get("name", k) if k else ""
            write_log({"at": time.strftime("%H:%M:%S"), "key": "dig." + str(op), "label": f"Construction order: {op} {name}".strip(),
                       "ok": True, "out": "order now: " + (", ".join(rooms[o]["name"] if o in rooms else o for o in order) or "empty (df-ai decides)")})
            self.send(json.dumps({"ok": True, "order": order}).encode())
            return
        if path == "/goto":
            # send the camera to a planned room
            rooms = {r["key"]: r for r in plan_rooms()[0]}
            r = rooms.get(req.get("key"))
            if not r:
                self.send_error(400)
                return
            lua = (f"dfhack.timeout(1,'ticks',function() dfhack.run_command_silent('disable','spectate') "
                   f"df.global.plotinfo.follow_unit=-1 dfhack.gui.revealInDwarfmodeMap(xyz2pos({r['x']},{r['y']},{r['z']}),true,true) end)")
            out = sup.dfhack("lua", lua, timeout=20)
            self.answer(f"Camera to the planned {r['name']}", "cam.goto", "camera moved" if out is not None else None)
            return
        if path == "/lock":
            # lock the camera on a tour stop: only coordinates and the name from
            # the game's own stop list reach the game, never page input
            known = {s_["key"]: s_ for s_ in stops()}
            k = req.get("key")
            if k not in known:
                self.send_error(400)
                return
            s_ = known[k]
            try:
                x, y, z = int(s_["x"]), int(s_["y"]), int(s_["z"])
            except (KeyError, TypeError, ValueError):
                self.send_error(400)
                return
            name = re.sub(r"[^\w' -]", "", str(s_.get("name", "")))[:60] or "A tour stop"
            out = sup.dfhack("dfai-camera-lock", "at", str(x), str(y), str(z), "0", name, timeout=20)
            self.answer("Lock the camera on " + name, "cam.lock", out)
            return
        if path == "/show":
            known = {s_["key"]: s_ for s_ in stops()}
            k = req.get("key")
            if k not in known:
                self.send_error(400)
                return
            out = sup.dfhack("dfai-room-tour", "show", k, timeout=20)
            time.sleep(1.5)
            out = sup.dfhack("dfai-room-tour", "last", timeout=20) or out
            self.answer("Show " + known[k]["name"], "cam.show", out)
            return
        if path == "/blueprint":
            known = {(b["file"], b["label"]): b for b in blueprints()}
            f, label = req.get("file"), req.get("label")
            if (f, label) not in known:
                self.send_error(400)
                return
            try:
                x, y, z = (int(req.get(c)) for c in ("x", "y", "z"))
            except (TypeError, ValueError):
                self.send_error(400)
                return
            x, y, z = max(0, min(400, x)), max(0, min(400, y)), max(0, min(400, z))
            if req.get("dry"):
                out = sup.dfhack("quickfort", "run", f, "-n", "/" + label, "-c", f"{x},{y},{z}", "--dry-run", timeout=60)
                self.answer(f"Preview {f} /{label} at {x},{y},{z}", "bp.preview", out)
                return
            # the real thing runs on the game tick (never from the console thread)
            lua = ("dfhack.timeout(1,'ticks',function() _G.dfai_overseer_qf = dfhack.run_command_silent("
                   f"'quickfort','run','{f}','-n','/{label}','-c','{x},{y},{z}') end)")
            sup.dfhack("lua", lua, timeout=20)
            time.sleep(2)
            out = sup.dfhack("lua", "print(_G.dfai_overseer_qf or 'still running')", timeout=20)
            self.answer(f"Build {f} /{label} at {x},{y},{z}", "bp.run", out)
            return
        if path != "/run":
            self.send_error(404)
            return
        key = req.get("key")
        if key not in COMMANDS:
            self.send_error(400)
            return
        group, label, _, args, timeout = COMMANDS[key]
        if key == "holiday.start":
            # an optional name: it goes into the calendar file for the game to pick up,
            # never into the command
            title = clean_title(req.get("title"))
            cal = calendar_read()
            if title:
                cal["next_title"] = title
            else:
                cal.pop("next_title", None)
            calendar_write(cal)
            if title:
                label = f"{label}: {title}"
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
        if out is not None and args[:1] == ["dfai-room-tour"] and args[1:2] in (["statue"], ["leaves"]):
            time.sleep(1.5)   # the camera moves on the next game tick
            out = sup.dfhack("dfai-room-tour", "last", timeout=20) or out
        self.answer(label, key, out)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"overseer console on http://localhost:{PORT}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
