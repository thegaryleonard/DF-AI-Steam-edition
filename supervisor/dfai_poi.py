"""Points of interest for the stream's room tour, taken from df-ai's plan.

df-ai's plan (df-ai-plan.dat in the loaded save) knows places that have no DF
zone or location: the fort entrance, the execution pit (or an old fort's pitting tower), the
cistern, catacombs, jail, farms, workshops and furnaces. This writes them to
<DF>/dfhack-config/dfai-poi.json, which dfai-room-tour.lua reads.

Usage: python dfai_poi.py [<save dir>]   (default: newest save with a plan)
"""
import json
import os
import sys
from pathlib import Path

DF_DIR = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
SAVE_DIRS = [Path(os.path.expandvars(r"%APPDATA%\Bay 12 Games\Dwarf Fortress\save")), DF_DIR / "save"]
OUT = DF_DIR / "dfhack-config" / "dfai-poi.json"

WORKSHOP_NAMES = {
    "Still": "The Still", "Kitchen": "The Kitchen", "MetalsmithsForge": "The Forge",
    "Craftsdwarfs": "The Craftsdwarf's Workshop", "Masons": "The Mason's Workshop",
    "Carpenters": "The Carpenter's Workshop", "Jewelers": "The Jeweler's Workshop",
    "Butchers": "The Butcher's Shop", "Fishery": "The Fishery", "Loom": "The Loom",
    "Farmers": "The Farmer's Workshop", "Bowyers": "The Bowyer's Workshop",
    "Siege": "The Siege Workshop", "Mechanics": "The Mechanic's Workshop",
}
FURNACE_NAMES = {"Smelter": "The Smelter", "MagmaSmelter": "The Magma Smelter", "GlassFurnace": "The Glass Furnace",
                 "WoodFurnace": "The Wood Furnace", "Kiln": "The Kiln"}


def newest_plan():
    best = None
    for root in SAVE_DIRS:
        if not root.is_dir():
            continue
        for d in root.iterdir():
            f = d / "df-ai-plan.dat"
            if f.is_file() and (best is None or f.stat().st_mtime > best.stat().st_mtime):
                best = f
    return best


def centre(r, top=False):
    (x1, y1, z1), (x2, y2, z2) = r["min"], r["max"]
    return [(x1 + x2) // 2, (y1 + y2) // 2, z2 if top else z1]


def build(plan):
    rooms = plan["r"]
    pois, seen = [], set()

    def add(name, kind, pos):
        if name in seen:
            return
        seen.add(name)
        pois.append({"name": name, "kind": kind, "x": pos[0], "y": pos[1], "z": pos[2]})

    for r in rooms:
        if r.get("status") not in ("finished", "dug"):
            continue
        t, c = r.get("type"), r.get("comment", "")
        if t == "corridor" and c == "fort entrance":
            add("The Fort Entrance", "Entrance", centre(r))
        elif t == "pitcage" and r.get("outdoor"):
            add("The Execution Tower", "Prisoners are dropped from here", centre(r))
        elif t == "pitcage":
            # underground pit: caged hostiles drop 11 levels down a sealed shaft
            add("The Execution Pit", "Prisoners are dropped down the shaft", centre(r))
        elif t == "cistern":
            add("The Cistern", "Water reserve", centre(r))
        elif t == "cemetery":
            add("The Catacombs", "Where the fort's dead rest", centre(r))
        elif t == "jail":
            add("The Jail", "Cells for the lawless", centre(r))
        elif t == "garbagedump" and not r.get("outdoor"):
            add("The Refuse Chute", "Refuse goes down the hole", centre(r))
        elif t == "garbagedump":
            add("The Garbage Dump", "Refuse", centre(r))
        elif t == "farmplot" and not r.get("outdoor"):
            add("The Underground Farms", "Farm plots", centre(r))
        elif t == "workshop" and r.get("workshop_type") in WORKSHOP_NAMES:
            add(WORKSHOP_NAMES[r["workshop_type"]], "Workshop", centre(r))
        elif t == "furnace" and r.get("furnace_type") in FURNACE_NAMES:
            add(FURNACE_NAMES[r["furnace_type"]], "Furnace", centre(r))
    return pois


def main():
    f = Path(sys.argv[1]) / "df-ai-plan.dat" if len(sys.argv) > 1 else newest_plan()
    if not f or not f.is_file():
        print("no df-ai plan found")
        return 1
    plan = json.loads(f.read_text(encoding="utf-8"))
    pois = build(plan)
    OUT.write_text(json.dumps({"site_id": plan.get("site_id"), "plan": str(f), "pois": pois}, indent=1), encoding="utf-8")
    print(f"{len(pois)} points of interest from {f} -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
