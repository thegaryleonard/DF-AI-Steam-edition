"""Tag Herald library entries with what they fit, so live events never get a mismatched joke.

Run from supervisor/:  python herald/tag_library.py [--check]
Reads the cue words in library/itemcats.json and writes a "fit" list into every entry whose text assumes something
about the event: what was made (cloth, weapon, furniture...), its material, how someone died, which mood, which mineral.
overlay.html's fits() only prints a tagged entry when the live facts match. Untagged entries must be true for anything.
Re-runnable: it recomputes every fit it owns (entries listed in MANUAL keep the hand-set value).
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jsonedit

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")
C = json.load(open(os.path.join(HERE, "itemcats.json"), encoding="utf-8"))["itemcats"]


def rx(words):
    return re.compile(r"(?<![A-Za-z])(?:" + "|".join(words) + r")(?![A-Za-z])", re.I)


def base_of(n):
    n = C["synonyms"].get(n, n)
    return n if n in C["compound"] else C["synonyms"].get(n.split()[-1], n.split()[-1])


# specific nouns: a template naming a throne only prints for a throne, not for every piece of furniture
NOUNS = {}
for _cat, _l in C["nouns"].items():
    for _n in _l:
        b = base_of(_n)
        if b in C["nounskip"] or _n in C["nounskip"]: continue
        NOUNS.setdefault(b, set()).add(_n.split()[-1] if b not in C["compound"] else _n)
for _s, _b in C["synonyms"].items():
    if _b in NOUNS: NOUNS[_b].add(_s)
NOUN_RX = {b: rx([re.escape(w) + "(?:s|es)?" for w in sorted(ws, key=len, reverse=True)]) for b, ws in NOUNS.items()}
ITEM = {k: rx(v) for k, v in C["cues"].items() if not k.startswith("mat_")}
MAT = {k: rx(v) for k, v in C["cues"].items() if k.startswith("mat_")}
DEATH = {k: rx(v) for k, v in C["deathcues"].items()}
MOOD = {k: rx(v) for k, v in C["moodcues"].items()}
METALS = {m: rx([m]) for m in ("silver", "gold", "copper", "iron", "tin", "platinum", "lead", "zinc", "nickel", "bismuth", "aluminum", "adamantine")}
VEIN = rx(["veins?", "strikes?", "struck", "lode", "motherlode", "seam"])
ADOPT = rx(["adopt\\w*", "new pet", "new companion", "animal companion"])
MOOD_SHOP = {"gem": ["Jeweler's Workshop"], "cloth": ["Clothier's Shop", "Loom"], "clothing": ["Clothier's Shop", "Leather Works"],
             "leather": ["Leather Works", "Tanner's Shop"], "mat_metal": ["Metalsmith's Forge", "Magma Forge"],
             "mat_bone": ["Bone Carver's Workshop", "Craftsdwarf's Workshop"], "mat_wood": ["Carpenter's Workshop", "Bowyer's Workshop"],
             "mat_stone": ["Stoneworker's Workshop", "Mason's Workshop"]}
MINERAL = {"gem": rx(["gems?", "gemstones?", "jewels?", "sparkl\\w*", "facet\\w*", "precious stones?"] + [re.escape(w) for w in C["gemwords"]]),
           "ore": rx(["ores?", "veins? of (?:iron|gold|silver|copper|tin|metal)", "smelt\\w*", "metal", "iron", "gold", "silver", "copper", "tin", "platinum", "native \\w+"]),
           "coal": rx(["coal", "lignite", "fuel", "charcoal", "coke"]),
           "cavern": rx(["caverns?", "cave moss", "underground lake", "fungus forest", "tower-caps?", "the deep places"]),
           "magma": rx(["magma", "lava", "molten", "the hot rock"])}
PET_SP = {"sp_cat": rx(["cats?", "kittens?", "purr\\w*", "mous(?:e|er|ers|ing)", "whiskers?", "tabby", "feline", "hairballs?"]),
          "sp_dog": rx(["dogs?", "pupp(?:y|ies)", "good boy", "good girl", "bark\\w*", "fetch\\w*", "wag\\w*", "hounds?", "canine", "kennel"])}
SLAUGHTER = rx(["slaughter\\w*", "butcher\\w*", "meat", "tallow", "dinner", "stew", "roast", "sausage", "the kitchen", "menu"])
GRIEF = rx(["pass(?:es|ed)", "mourn\\w*", "grie\\w+", "rest in peace", "r\\.i\\.p", "died", "dies", "death", "loss", "lost", "miss(?:ed)?", "beloved", "funeral", "burial", "buried", "tears?", "weep\\w*", "farewell", "memory", "memorial", "coffin", "grave"])
ALL_DIE = [k for k in C["death"]]
SLOTS_ITEM = re.compile(r"\{(masterwork|masterwork_last|artifact_item|artifact_new_item)\}")
SLOTS_DEATH = re.compile(r"\{(cause|lastdead_cause)\}")
SLOTS_MIN = re.compile(r"\{mineral\}")
# hand overrides: id -> fit list ([] = generic, true for anything)
MANUAL = {
    "lb-master-cap-2": [],            # "The masterpiece is the one looking smug." fits anything
    "bk-master-cap-8": [], "bk-master-rep-3": [], "bk-master-rep-8": [], "bk2-master-cap-1": [], "bk2-master-label-3": [],
    "bk2-master-kick-1": [], "lb-master-cap-5": [], "lb-master-cap-9": [], "lb-master-rep-2": [], "lb-master-rep-7": [],
    "lb-master-rep-9": [], "lb-master-rep-11": [],
    "bk2-master-cap-6": ["furniture"], "lb-master-head-1": ["furniture"], "lb-master-rep-3": ["furniture"],
    "lb-master-rep-13": ["furniture", "statue"], "lb-master-label-2": ["furniture"],
    # artifacts: display furniture, decorations and engravings are generic; "not an armor stand" is true for anything else
    "lb-artifact-head-1": ["!furniture"], "lb-artifact-rep-1": ["!furniture"], "lb-artifact-label-2": ["!furniture"],
    "lb-artifact-head-8": [], "lb-artifact-cap-1": [], "lb-artifact-cap-6": [], "lb-artifact-rep-5": [], "lb-artifact-rep-6": [],
    "lb-artifact-label-7": [], "bk2-artifact-cap-1": [], "bk2-artifact-label-2": [], "bk2-artifact-cap-2": [], "bk-artifact-cap-8": [],
    "lb-artifact-kicker-8": [], "lb-artifact-cap-8": [], "bk-artifact-cap-7": ["jewelry"], "bk-artifact-rep-5": [], "bk-artifact-rep-1": [],
    "bk-artifact-head-8": [], "bk-artifact-cap-2": [], "lb-artifact-cap-9": [], "bk2-artifact-cap-4": [], "lb-artifact-head-6": [],
    "lb-artifact-rep-4": [], "lb-artifact-rep-11": [], "bk-artifact-rep-6": [],
    "cb-moody-artifact": ["!wearable"], "bk-pet-head-7": [], "lb-mood-cap-2": ["shop_Jeweler's Workshop"],   # "Can I wear it?" / "He could not wear it."
    "bk-death-rep-1": [], "bk-strike-cap-6": [], "lb-strike-rep-6": ["gem"],
}


# the hand-reviewed table lives in fit_manual.json (also read by test_fit.js)
MANUAL.update({k: v for k, v in json.load(open(os.path.join(os.path.dirname(HERE), "fit_manual.json"), encoding="utf-8")).items() if not k.startswith("_")})


def bare(e):
    """the template's own words (slots removed), from every string field except id/when/fit"""
    out = []
    def w(v):
        if isinstance(v, str): out.append(re.sub(r"\{\w+\}", " ", v))
        elif isinstance(v, list): [w(x) for x in v]
        elif isinstance(v, dict): [w(x) for k, x in v.items() if k not in ("id", "when", "fit", "world", "bg", "who", "pos", "pose")]
    w(e)
    return " ".join(out)


def item_fit(t):
    cats = [k for k, r in ITEM.items() if r.search(t)]
    mats = [k for k, r in MAT.items() if r.search(t)]
    # a stone/metal/wood workshop word alone (mason, smith) implies the trade, so the item group must agree too
    if mats and not cats:
        cats = {"mat_stone": ["furniture", "statue", "crafts", "container", "tool", "construction", "engraving"],
                "mat_metal": ["weapon", "armor", "ammo", "furniture", "crafts", "tool", "metal", "instrument", "container"],
                "mat_wood": ["furniture", "container", "tool", "weapon", "ammo", "crafts", "instrument"],
                "mat_bone": ["crafts", "armor", "ammo", "weapon", "furniture", "statue"]}[mats[0]]
    # a joke about a weaver's cloth also fits the clothing made from it? no: cloth is the bolt, clothing is what is worn
    nouns = sorted("n_" + b for b, r in NOUN_RX.items() if r.search(t))
    # "armor stand" contains "stand"; "mail shirt" contains "shirt": drop a noun that is part of a longer one also present
    nouns = [n for n in nouns if not any(n != m and n[2:] in m[2:] for m in nouns)]
    return sorted(set(cats)) + sorted(set(mats)) + nouns


def fit_for(scope, e):
    """the fit list for one entry in a scope (item, death, mood, mineral, pet)"""
    t = bare(e)
    if scope == "item": return item_fit(t)
    if scope == "death":
        d = ["die_" + k for k, r in DEATH.items() if r.search(t)]
        return sorted(set(d))
    if scope == "mood":
        # a mood's demands are unknown until it claims a workshop: lines about gems/cloth/forges need that workshop
        m = ["mood_" + k for k, r in MOOD.items() if r.search(t)]
        cues = {**{k: r for k, r in ITEM.items() if k in MOOD_SHOP}, **{k: r for k, r in MAT.items() if k in MOOD_SHOP}}
        shops = sorted({"shop_" + s for k, r in cues.items() if r.search(t) for s in MOOD_SHOP[k]})
        return sorted(set(m)) + shops
    if scope == "mineral":
        f = sorted(k for k, r in MINERAL.items() if r.search(t))
        f += ["metal_" + k for k, r in METALS.items() if r.search(t)]
        # "the vein", "the strike": a mineral find, never a cavern or magma discovery
        if not f and VEIN.search(t): f = ["gem", "ore", "coal", "stone"]
        return f
    if scope == "pet":
        if ADOPT.search(t) or e.get("id", "").startswith("lb-pet-"): return ["ev_adopt"]   # adoption stories never print for a death
        f = [k for k, r in PET_SP.items() if r.search(t)]
        # butcher lines only for a slaughter; every other pet line (mourning, memories) never for a slaughtered stray
        f.append("die_slaughter" if SLAUGHTER.search(t) else "!die_slaughter")
        return f
    return []


KIND_SCOPE = {"master": "item", "artifact": "item", "mood": "mood", "death": "death", "strike": "mineral", "pet": "pet"}
FOLLOW_SCOPE = {"masterpiece_week": "item", "artifact_week": "item", "mood_done": "item", "death_week": "death"}


def scope_of(path, e):
    if path[0] == "kinds" and len(path) > 1: return KIND_SCOPE.get(path[1])
    if path[0] == "scenes": return None          # scene text is written for its own drawing
    if path[0] == "followon" and len(path) > 1 and path[1] in FOLLOW_SCOPE: return FOLLOW_SCOPE[path[1]]
    s = json.dumps(e, ensure_ascii=False)
    if SLOTS_ITEM.search(s): return "item"
    if SLOTS_DEATH.search(s): return "death"
    if SLOTS_MIN.search(s): return "mineral"
    return None


stats = {"tagged": 0, "entries": 0, "changed": 0}
CHANGED = {}


def walk(o, path):
    if isinstance(o, dict):
        if "id" in o:
            stats["entries"] += 1
            if o.get("fit_auto") is False: return
            sc = scope_of(path, o)
            new = MANUAL.get(o["id"]) if o["id"] in MANUAL else (fit_for(sc, o) if sc else [])
            old = o.get("fit")
            if new: o["fit"] = new; stats["tagged"] += 1
            elif "fit" in o: del o["fit"]
            if (old or []) != (new or []): stats["changed"] += 1; CHANGED[o["id"]] = o
            return
        for k, v in o.items(): walk(v, path + [k])
    elif isinstance(o, list):
        for v in o: walk(v, path)


check = "--check" in sys.argv
for f in sorted(glob.glob(os.path.join(HERE, "*.json"))):
    if f.endswith("itemcats.json"): continue
    raw = open(f, encoding="utf-8", newline="").read()
    d = json.loads(raw)
    before = stats["changed"]
    walk(d, [])
    if stats["changed"] != before and not check:
        new = jsonedit.rewrite(raw, CHANGED)       # only the changed entries are rewritten, in the file's own style
        assert json.loads(new) == d, f"rewrite mismatch in {f}"
        open(f, "w", encoding="utf-8", newline="").write(new)
    CHANGED.clear()
print(stats)
if check and stats["changed"]: sys.exit(1)
