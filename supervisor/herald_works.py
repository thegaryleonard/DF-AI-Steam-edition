"""Construction news for the Herald: what the fort is building and working toward.

Reads df-ai's plan (df-ai-plan.dat in the newest save; refreshed at each
autosave/quicksave) and a small hand-kept list of special projects
(herald_projects.json). No game calls.

- building: rooms df-ai is digging or fitting out right now
- goals: the next unmet steps of df-ai's build order ("p" priorities)
- done: rooms finished since the last look (kept in logs/works_state.json)
- projects: big landmarks (hospital, tavern, mist generator...) and their state
- depth: how far below the entrance the fort reaches
"""
import json
import re
import time
from collections import Counter
from pathlib import Path

import dfai_poi

HERE = Path(__file__).parent
STATE = HERE / "logs" / "works_state.json"
PROJECTS = HERE / "herald_projects.json"
DFLOG = dfai_poi.DF_DIR / "df-ai.log"

NICE = {
    "Masons": "mason's workshop", "Carpenters": "carpenter's workshop", "Craftsdwarfs": "craftsdwarf's workshop",
    "Jewelers": "jeweler's workshop", "MetalsmithsForge": "forge", "Butchers": "butcher's shop", "Tanners": "tannery",
    "Fishery": "fishery", "Kitchen": "kitchen", "Still": "still", "Farmers": "farmer's workshop", "Loom": "loom",
    "Clothiers": "clothier's shop", "Leatherworks": "leatherworks", "Bowyers": "bowyer's workshop",
    "Mechanics": "mechanic's workshop", "Siege": "siege workshop", "Ashery": "ashery", "Dyers": "dyer's shop",
    "SoapMaker": "soap maker", "Smelter": "smelter", "WoodFurnace": "wood furnace", "Kiln": "kiln",
    "GlassFurnace": "glass furnace", "MagmaSmelter": "magma smelter",
}


def label(r):
    t = r.get("type")
    if t == "workshop":
        return NICE.get(r.get("workshop_type"), (r.get("workshop_type") or "workshop").lower())
    if t == "furnace":
        return NICE.get(r.get("furnace_type"), (r.get("furnace_type") or "furnace").lower())
    if t == "location":
        return {"tavern": "tavern", "temple": "temple", "library": "library", "guildhall": "guildhall"}.get(r.get("location_type"), "meeting place")
    if t == "stockpile":
        return f"{(r.get('stockpile_type') or 'general').replace('_', ' ')} stockpile"
    if t == "farmplot":
        return f"{r.get('farm_type') or 'food'} farm"
    if t == "nobleroom":
        return f"noble {r.get('nobleroom_type') or 'room'}"
    if t == "outpost":
        return f"{r.get('outpost_type') or 'mining'} outpost"
    if t == "pond":
        return "irrigation pond" if "irrigation" in (r.get("comment") or "") else "pond"
    return {"infirmary": "hospital", "tradedepot": "trade depot", "garbagedump": "garbage dump", "pitcage": "execution pit",
            "barracks": "barracks", "bedroom": "bedroom", "corridor": "corridor", "cistern": "cistern", "jail": "jail",
            "cemetery": "catacomb", "pasture": "pasture", "dininghall": "dining hall"}.get(t, (t or "room").replace("_", " "))


def _matches(r, match):
    for k, v in match.items():
        if k.endswith("_not") or isinstance(v, dict):
            continue
        if k == "level":
            if r.get("level") != v:
                return False
        elif r.get(k) != v:
            return False
    return True


def _game_date():
    try:
        with open(DFLOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4000))
            for l in reversed(f.read().decode("utf-8", "replace").splitlines()):
                m = re.match(r"^(\d+)-(\d+)-(\d+):", l)
                if m:
                    return [int(m.group(1)), int(m.group(2)), int(m.group(3))]
    except OSError:
        pass
    return None


def feed():
    path = dfai_poi.newest_plan()
    if not path:
        return {"ok": False, "error": "no plan"}
    plan = json.load(open(path, encoding="utf-8"))
    rooms = plan["r"]
    site = plan.get("site_id")

    # under way: rooms being dug or fitted out (skip plain corridors unless that's all)
    busy = Counter(label(r) for r in rooms if r.get("status") in ("dig", "dug") and r.get("type") != "corridor")
    halls = sum(1 for r in rooms if r.get("status") in ("dig", "dug") and r.get("type") == "corridor")

    goals, done_goals = [], 0
    for p in plan.get("p", []):
        if p.get("action") not in ("dig", "dig_immediate") or not isinstance(p.get("match"), dict):
            continue
        hit = [r for r in rooms if _matches(r, p["match"])]
        if not hit:
            continue
        # "count" priorities are met once one matching room exists; the rest need them all
        met = any(r.get("status") == "finished" for r in hit) if "count" in p else all(r.get("status") == "finished" for r in hit)
        if met:
            done_goals += 1
        else:
            fin = sum(1 for r in hit if r.get("status") == "finished")
            dug = sum(1 for r in hit if r.get("status") in ("dig", "dug"))
            goals.append({"name": p.get("name"), "of": len(hit), "finished": fin, "digging": dug})

    # finished since last time (per site)
    try:
        st = json.load(open(STATE, encoding="utf-8"))
    except (OSError, ValueError):
        st = {}
    if st.get("site") != site:
        st = {"site": site, "status": {}, "done": []}
    first = not st["status"]
    when = _game_date()
    for i, r in enumerate(rooms):
        old = st["status"].get(str(i))
        if not first and old and old != "finished" and r.get("status") == "finished" and r.get("type") != "corridor":
            st["done"].append({"what": label(r), "date": when, "at": int(time.time())})
        st["status"][str(i)] = r.get("status")
    st["done"] = st["done"][-12:]
    STATE.parent.mkdir(exist_ok=True)
    json.dump(st, open(STATE, "w", encoding="utf-8"))

    def state_of(types, **kw):
        hit = [r for r in rooms if r.get("type") in types and all(r.get(k) == v for k, v in kw.items())]
        if not hit:
            return None
        if any(r.get("status") == "finished" for r in hit):
            return "complete"
        if any(r.get("status") in ("dig", "dug") for r in hit):
            return "under way"
        return "planned"

    landmarks = [
        ("The Trade Depot", state_of(["tradedepot"])), ("The Hospital", state_of(["infirmary"])),
        ("The Tavern", state_of(["location"], location_type="tavern")), ("The Temple", state_of(["location"], location_type="temple")),
        ("The Library", state_of(["location"], location_type="library")), ("The Barracks", state_of(["barracks"])),
        ("The Cistern", state_of(["cistern"])), ("The Jail", state_of(["jail"])), ("The Catacombs", state_of(["cemetery"])),
        ("The Execution Pit", state_of(["pitcage"])),
    ]
    indoor = [r for r in rooms if r.get("type") == "pasture" and not r.get("outdoor")]
    landmarks.append(("The Indoor Pasture", ("complete" if any(r.get("status") == "finished" for r in indoor) else "planned") if indoor else None))
    try:
        poi = json.load(open(dfai_poi.OUT, encoding="utf-8"))
        names = " ".join(p.get("name", "") for p in poi.get("pois", [])) if poi.get("site_id") == site else ""
    except (OSError, ValueError):
        names = ""
    if "Mist" in names:
        landmarks.append(("The Mist Generator", "complete"))
    landmarks = [{"name": n, "state": s} for n, s in landmarks if s]

    ent = rooms[plan["entrance"]]["min"][2] if isinstance(plan.get("entrance"), int) and plan["entrance"] < len(rooms) else None
    zs = [r["min"][2] for r in rooms if r.get("status") in ("finished", "dug") and r.get("type") != "outpost"]
    cav = [r for r in rooms if r.get("type") == "outpost" and r.get("outpost_type") == "cavern" and r.get("status") == "finished"]
    depth = {"levels": (ent - min(zs)) if ent is not None and zs else None, "cavern": bool(cav),
             "cavern_levels": (ent - min(r["min"][2] for r in cav)) if cav and ent is not None else None}

    total = sum(1 for r in rooms if r.get("type") != "corridor")
    fin = sum(1 for r in rooms if r.get("type") != "corridor" and r.get("status") == "finished")

    try:
        projects = json.load(open(PROJECTS, encoding="utf-8"))
    except (OSError, ValueError):
        projects = []

    return {"ok": True, "site": site, "building": busy.most_common(6), "halls": halls, "goals": goals[:4],
            "goals_done": done_goals, "done": st["done"][-5:], "landmarks": landmarks, "depth": depth,
            "rooms_finished": fin, "rooms_total": total, "projects": projects}


if __name__ == "__main__":
    print(json.dumps(feed(), indent=1, ensure_ascii=False)[:3500])
