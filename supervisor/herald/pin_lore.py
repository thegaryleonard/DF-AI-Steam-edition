"""Pin library entries that name one world's history literally to that world (so they never print elsewhere).
Run: python herald/pin_lore.py [files...]   (default: library/lore_*.json)"""
import glob, json, os, re, sys

WORLD = "The Enchanted Planes"
NAMES = ["Searabbeys", "Quakefocus", "Creaturemirrored", "Crazed Hex", "Destined Wickedness", "High Cruelties", "Torments of Hating",
         "Chambers of Steel", "Iden", "Loloklolor", "Oddom", "Oltartilesh", "Bomrek", "Enshalcatten", "Padtufted", "Pulledrained",
         "Ironcrowds", "Jackaldefense", "Grooved Council", "Distinct Dungeon", "Distant Letter", "Fair Cakes", "Toeembrace", "Tametomb",
         "Scaldedarch", "Chaste Cudgel", "Oily Boots", "Fewethauyira", "Shadyghosts", "Sable Nights", "Nobledessert", "Keeperglossed",
         "Amusing Duties", "Claspedserpent", "Nuanced Hamlet", "Fieryaged", "Roughnessslaps", "Crazeboard", "Massivebarbs", "Seducedbowl",
         "Menacetested", "Quietmenaces", "Glimmerpartnered", "Bulbwhisker", "Ngumrash", "Vice of Fins", "Ilral", "1,981", "1981", "1,994",
         "Glowing Cult", "Wayward Doctrine", "Deified Lantern", "Enchanted Planes"]
RX = re.compile(r"\b(" + "|".join(re.escape(n) for n in NAMES) + r")\b")


def pin(o, stats):
    if isinstance(o, dict):
        if "id" in o:
            stats["n"] += 1
            body = json.dumps({k: v for k, v in o.items() if k not in ("id", "world")}, ensure_ascii=False)
            if RX.search(body) and o.get("world") != WORLD:
                o["world"] = WORLD
                stats["pinned"] += 1
            elif o.get("world") == WORLD:
                stats["already"] += 1
            return
        for v in o.values():
            pin(v, stats)
    elif isinstance(o, list):
        for v in o:
            pin(v, stats)


here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")
for f in sys.argv[1:] or sorted(glob.glob(os.path.join(here, "lore_*.json"))):
    d = json.load(open(f, encoding="utf-8"))
    st = {"n": 0, "pinned": 0, "already": 0}
    pin(d, st)
    json.dump(d, open(f, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{os.path.basename(f)}: {st['n']} entries, newly pinned {st['pinned']}, already pinned {st['already']}, "
          f"world-specific {100 * (st['pinned'] + st['already']) // max(1, st['n'])}%")
