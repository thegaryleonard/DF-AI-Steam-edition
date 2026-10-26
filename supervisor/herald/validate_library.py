"""Validate the Herald library: unique ids, known slots/conditions, comic vocabulary, length limits.
Run: python herald/validate_library.py   (from supervisor/)"""
import collections, glob, json, os, re, sys

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")
BASE = set("fort pop year month season weather world drinks meals plants seeds stone wood bars gems cloth thread blocks herd dogs cats "
           "topanimal topanimal_n farms citizen citizen2 citizen_first artifact artifact_item mineral masterwork masterwright promoted post "
           "deadname moodname cause prof town town2 darkfort darkfort2 retreat hillock".split())
IV = set("dwarf first nick prof age skill level skill2 deity kin rel adj about job fort season weather".split())
BK = {"who", "first", "fort", "pop", "season", "weather", "event", "item", "art", "prof", "shop", "mineral"}
RUMOR = {"site", "site_kind", "entity", "entity_race", "entity2", "entity2_race", "hf", "hf_race", "hf2", "hf2_race", "region", "artifact",
         "artifact_item", "ago", "source", "fort", "season"}
POL = {"fort", "pop", "season", "civ", "government", "n", "job", "material", "manager", "squad", "captain", "members", "kills", "routine", "order",
       "post", "holder", "crime", "criminal", "victim", "noble", "item", "monarch", "general", "diplomat", "liaison", "enemy", "enemy_race",
       "n_war", "n_peace", "friend", "friend_race"}
OG = {"days", "since", "n", "fort", "season", "weather", "pop", "drinks", "wood", "meals", "citizen", "nick", "topic"}
# world-history slots, allowed in every section; filled from herald/lore/<world>.json (built from real events)
LORE = {"past_fort", "past_fort_fate", "past_fort_years", "record", "record_fort", "civ", "monarch", "liaison", "enemy", "enemy_race", "world"}
# storyline (arc) slots from memory, plus extra stock/works/military slots; context() fills these for every section
ARC = {"lastdead", "lastdead_prof", "lastdead_cause", "lastdead_ago", "moody", "moody_prof", "moody_shop", "moody_days", "mood_took", "artifact_new",
       "artifact_new_item", "artifact_maker", "artifact_offered_to", "masterwright_last", "masterwork_last", "newborn_parent", "bride",
       "meat", "fish", "eggs", "leather", "depth", "cavern_depth", "squads", "soldiers", "caravan_civ", "fort_days"}
LORE |= ARC
BASE |= LORE; IV |= LORE; BK |= LORE; RUMOR |= LORE; POL |= LORE; OG |= LORE
# the topic-keyed Society Pages interview (library qa/qa_decks; filled by ivFacts() in overlay.html)
QA = IV | set("a_prof a_prof_cap pop doing squad milskill trade_level skill_noun trade_title a_trade_title a_trade_title_cap deity2 kin2 child kids kids_cap "
              "drinks thread herd meals".split())
CONDS = set("has_past_fort at_war no_meat drinks_high drinks_low rain snow clear pop_big pop_small dogs_many cats farms_many stone_glut wood_low gems recent_death "
            "recent_mood recent_masterpiece recent_strike recent_promotion recent_migrants recent_caravan spring summer autumn winter "
            "peace food_low food_ok food_high drinks_ok has_meat meat_low no_fish has_eggs cats_many herd_big herd_small thread_glut cloth_ok "
            "seeds_many gems_many bars_low bars_many wood_ok caverns deep caravan_here no_caravan_here has_military army_big no_military "
            "has_tavern has_temple has_library has_hospital has_catacombs has_jail pop_mid young_fort old_fort "
            "death_week mood_open mood_long artifact_week mood_done migrants_week birth_week masterpiece_week marriage_week beast_week caravan_week".split())
ARCKEYS = {"mood_done", "death_week", "mood_open", "artifact_week", "beast_week", "birth_week", "marriage_week", "migrants_week", "masterpiece_week", "caravan_week"}
BG = set("hall mine outside farm tavern depot bedroom workshop cavern none".split())
PROPS = set("barrel mug coffin gem tree well door bed table anvil workshop wagon rocks sun cloud rain sock crown sign".split())
WHO = set("dwarf noble elf goblin kobold cat dog carp ghost beast baby".split())
POSE = set("stand armsUp sad happy angry pick axe mug sleep".split())
POS = {"left", "center", "right"}


def merge(into, new):
    for k, v in new.items():
        if k in into and isinstance(into[k], list) and isinstance(v, list):
            into[k] = into[k] + v
        elif k in into and isinstance(into[k], dict) and isinstance(v, dict):
            merge(into[k], v)
        else:
            into[k] = v


lib, problems, ids = {}, [], collections.Counter()
for f in sorted(glob.glob(os.path.join(HERE, "*.json"))):
    try:
        merge(lib, json.load(open(f, encoding="utf-8")))
    except ValueError as e:
        problems.append(f"{os.path.basename(f)}: bad JSON {e}")


def walk(o, path, allowed):
    if isinstance(o, dict):
        if "id" in o:
            ids[o["id"]] += 1
        for c in o.get("when", []) or []:
            if c not in CONDS:
                problems.append(f"{path} {o.get('id')}: unknown condition {c}")
        for k, v in o.items():
            if k not in ("id", "when"):
                walk(v, path + "." + k, allowed)
    elif isinstance(o, list):
        for v in o:
            walk(v, path, allowed)
    elif isinstance(o, str):
        for s in re.findall(r"\{(\w+)\}", o):
            if s not in allowed:
                problems.append(f"{path}: unknown slot {{{s}}} in {o[:60]!r}")


def check_panel(p, sid):
    if p.get("bg", "none") not in BG:
        problems.append(f"{sid}: bg {p.get('bg')}")
    for pr in p.get("props", []):
        if pr not in PROPS:
            problems.append(f"{sid}: prop {pr}")
    seen = set()
    for c in p.get("cast", []):
        if c.get("who") not in WHO: problems.append(f"{sid}: who {c.get('who')}")
        if c.get("pose", "stand") not in POSE: problems.append(f"{sid}: pose {c.get('pose')}")
        if c.get("pos") not in POS or c.get("pos") in seen: problems.append(f"{sid}: pos {c.get('pos')}")
        seen.add(c.get("pos"))
        for k, lim in (("say", 60), ("think", 45)):
            if len(c.get(k, "")) > lim: problems.append(f"{sid}: {k} too long ({len(c[k])})")


for k, v in lib.items():
    allowed = QA if k in ("qa", "qa_decks") else IV if k in ("thoughts", "questions", "answers", "decks", "idle_decks") else BK if k in ("kinds", "scenes") else RUMOR if k in ("rumors", "briefs", "depot_gossip", "pouch", "pouch_heads") else POL if k in ("order_ads", "recruit_ads", "vacancy_ads", "local", "military", "world", "columns") else OG if k in ("stories", "counters", "followups") else BASE
    walk(v, k, allowed)
for k in lib.get("followon", {}):
    if k not in ARCKEYS: problems.append(f"followon: unknown storyline {k}")
    for part in ("heads", "bodies"):
        if not lib["followon"][k].get(part): problems.append(f"followon.{k}: no {part}")
for k, v in lib.get("room_blurbs", {}).items():
    if not isinstance(v, list) or not all(isinstance(x, str) and 20 < len(x) < 260 for x in v): problems.append(f"room_blurbs.{k}: bad lines")
    for x in v:
        if "{" in x: problems.append(f"room_blurbs.{k}: slots are not filled in room blurbs: {x[:40]}")
for st in lib.get("strips", []):
    if not 3 <= len(st.get("panels", [])) <= 4: problems.append(f"{st.get('id')}: {len(st.get('panels', []))} panels")
    for p in st.get("panels", []): check_panel(p, st.get("id"))
for g in lib.get("gags", []):
    check_panel(g.get("panel", {}), g.get("id"))
for j in lib.get("jumble", []):
    if not re.fullmatch(r"[A-Za-z]{4,9}", j.get("word", "")): problems.append(f"{j.get('id')}: jumble word {j.get('word')!r}")
for pl in lib.get("polls", []):
    if len(pl.get("options", [])) != len(pl.get("pct", [])) or sum(pl.get("pct", [])) != 100: problems.append(f"{pl.get('id')}: poll pct")
for rv in lib.get("reviews", []):
    if not 1 <= int(rv.get("stars", 0)) <= 5: problems.append(f"{rv.get('id')}: stars")
for q in lib.get("quiz", []):
    if len(q.get("options", [])) != 3 or q.get("answer") not in (0, 1, 2): problems.append(f"{q.get('id')}: quiz")
words = collections.Counter(j.get("word", "").upper() for j in lib.get("jumble", []))
problems += [f"duplicate jumble word {w}" for w, c in words.items() if c > 1]
problems += [f"duplicate id {i}" for i, c in ids.items() if c > 1]


def count(o):
    return sum(count(v) for v in o.values()) if isinstance(o, dict) and "id" not in o else len(o) if isinstance(o, list) and o and isinstance(o[0], dict) and "id" in o[0] else sum(count(v) for v in o) if isinstance(o, list) else 1 if isinstance(o, dict) else 0


print("entries:", sum(ids.values()))
print({k: count(v) for k, v in sorted(lib.items())})
print(f"{len(problems)} problems")
for p in problems[:60]:
    print("  ", p)
sys.exit(1 if problems else 0)
