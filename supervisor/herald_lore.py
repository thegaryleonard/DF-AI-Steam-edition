"""World lore for the Herald, learned from real play (no hand-written facts needed).

herald/lore.json = {world_name: {"forts": {fort: {...}}, "records": [...], "order": [fort, ...]}}
For each fort it tracks first/last seen game day, peak and last population, citizen deaths, sieges, moods,
masterpieces and the highest stock counts. When a new fort appears in the same world, the previous one
is closed and given a fate (lost with all hands, abandoned, now occupied by whoever the rumours say).
Records are absurd numbers worth bragging about later ("3,771 loose stones", "1,981 armor stands").
The page reads /lore.json?world=... and fills {past_fort} {past_fort_fate} {past_fort_years} {record} {record_fort}.
"""
import json, threading, time
from pathlib import Path

LORE_FILE = Path(__file__).parent / "herald" / "lore.json"
lock = threading.Lock()
DAYS_PER_YEAR = 336
MONTHS = ["Granite", "Slate", "Felsite", "Hematite", "Malachite", "Galena", "Limestone", "Sandstone", "Timber", "Moonstone", "Opal", "Obsidian"]
# stock -> (threshold worth remembering, how to say it)
STOCK_RECORDS = {"drinks": (1500, "{n:,} drinks in the cellars"), "stone": (2000, "{n:,} loose stones"), "seeds": (1500, "{n:,} seeds"),
                 "plants": (1500, "{n:,} plants"), "meals": (1000, "{n:,} prepared meals"), "gems": (300, "{n:,} gems"),
                 "bars": (800, "{n:,} metal bars"), "thread": (500, "{n:,} spools of thread"), "wood": (1000, "{n:,} logs")}
ORDER_RECORD = 100   # a single work order this big is a story


def _day(f):
    try:
        return int(f["year"]) * DAYS_PER_YEAR + max(0, MONTHS.index(f.get("month"))) * 28 + int(f.get("day", 1)) - 1
    except (KeyError, ValueError, TypeError):
        return None


def load():
    try:
        return json.loads(LORE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save(lore):
    LORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = LORE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(lore, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(LORE_FILE)


def _years(fd):
    if fd.get("first_day") is None or fd.get("last_day") is None:
        return None
    y = (fd["last_day"] - fd["first_day"]) / DAYS_PER_YEAR
    return "less than a year" if y < 1 else ("a year" if y < 1.5 else f"{round(y)} years")


def _fate(fd, rumors):
    """How a fort ended, from what we saw and what the world says now."""
    name = fd["name"]
    for r in (rumors or {}).get("rumors", []):
        site = (r.get("site") or {}).get("name")
        if site and site.lower() == name.lower() and r.get("type") == "occupation" and (r.get("entity") or {}).get("name"):
            e = r["entity"]
            return f"is now occupied by {e['name']}" + (f" ({e['race']}s)" if e.get("race") else "")
    try:   # the supervisor retires forts on purpose; its log says so
        log = (Path(__file__).parent / "supervisor.log").read_bytes()[-2_000_000:].decode("utf-8", "replace")
        if f"retiring {name};" in log:
            return f"was retired with {fd.get('last_pop') or 0} dwarves still in it"
    except OSError:
        pass
    if (fd.get("last_pop") or 0) == 0:
        if fd.get("sieges"):
            return "fell to a siege, all hands lost"
        return "was lost with all hands"
    if fd.get("deaths", 0) >= max(5, (fd.get("peak_pop") or 0) // 2):
        return "was abandoned after losing half its dwarves"
    return "was abandoned"


def observe(state, stocks=None, politics=None, rumors=None):
    """Called by the poller with each fresh snapshot. Cheap; writes only when something changed."""
    f = (state or {}).get("fort") or {}
    world, fort, day = f.get("world"), f.get("name"), _day(f)
    if not (state or {}).get("ok") or not world or not fort or day is None:
        return
    with lock:
        lore = load()
        W = lore.setdefault(world, {"forts": {}, "records": [], "order": []})
        changed = False
        if fort not in W["forts"]:
            # a new fort in this world: close the previous one
            for prev in W["order"]:
                p = W["forts"][prev]
                if not p.get("ended"):
                    p["ended"] = True
                    p["fate"] = _fate(p, rumors)
                    p["years"] = _years(p)
            W["forts"][fort] = {"name": fort, "first_day": max(0, day - int(f.get("age_days") or 0)), "peak_pop": 0, "deaths": 0,
                                "sieges": 0, "moods": 0, "masterpieces": 0, "seen_events": [], "max": {}}
            W["order"].append(fort)
            changed = True
        fd = W["forts"][fort]
        pop = f.get("population") or 0
        if fd.get("last_day") != day or fd.get("last_pop") != pop:
            fd["last_day"], fd["last_pop"] = day, pop
            fd["peak_pop"] = max(fd.get("peak_pop") or 0, pop)
            changed = True
        for b in state.get("big") or []:
            key = f"{b.get('type')}:{b.get('id')}"
            if b.get("id") is None or key in fd["seen_events"]:
                continue
            fd["seen_events"] = (fd["seen_events"] + [key])[-300:]
            t = b.get("type") or ""
            fd["deaths"] += t == "CITIZEN_DEATH"
            fd["sieges"] += "SIEGE" in t or "INVASION" in t
            fd["moods"] += "MOOD" in t
            fd["masterpieces"] += "MASTERPIECE" in t
            changed = True
        st = (stocks or {}).get("stocks") or {}
        for k, (thr, say) in STOCK_RECORDS.items():
            n = st.get(k) or 0
            if n > (fd["max"].get(k) or 0):
                fd["max"][k] = n
                changed = True
                if n >= thr:
                    _record(W, f"stock:{k}", say.format(n=n), fort, n)
        for o in (politics or {}).get("orders") or []:
            tot = o.get("total") or 0
            if tot >= ORDER_RECORD and o.get("job"):
                _record(W, f"order:{o['job']}", f"{tot:,} of '{o['job']}' ordered at once", fort, tot)
                changed = True
        if changed:
            save(lore)


def _record(W, key, text, fort, n):
    for r in W["records"]:
        if r["key"] == key and r["fort"] == fort:
            if n > r.get("n", 0):
                r.update(text=text, n=n)
            return
    W["records"].append({"key": key, "text": text, "fort": fort, "n": n})


def for_world(world):
    """What the page needs: ended forts (with fate/years) and the records, newest first,
    plus the other worlds the stream has played (for a new world's first issue)."""
    with lock:
        allw = load()
    W = allw.get(world) or {"forts": {}, "records": [], "order": []}
    forts = [{k: v for k, v in W["forts"][n].items() if k != "seen_events"} for n in W["order"]]
    others = [{"world": w, "forts": [W2["forts"][n]["name"] for n in W2.get("order", [])],
               "last": (W2["forts"][W2["order"][-1]] if W2.get("order") else {}).get("name")}
              for w, W2 in allw.items() if w != world]
    return {"world": world, "forts": forts, "past": [x for x in forts if x.get("ended")], "records": W["records"], "elsewhere": others}
