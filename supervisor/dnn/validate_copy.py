"""Validate the DNN copy library (supervisor/dnn/copy/*.json). See COPY.md.

Usage: python supervisor/dnn/validate_copy.py [file ...]   (default: every copy file)
Exit code 1 on any error.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY = HERE / "copy"

GLOBAL = {"fort", "world", "anchor", "anchor2", "reporter", "pop", "season", "month", "year",
          "citizen", "citizen2", "civ"}
EVENT = {"name", "prof", "thing", "creature", "count"}
FIELD = {"place", "place_kind", "guest", "guest_prof", "guest_job"}
STOCK = {"drinks", "meals", "meat", "plants", "gems", "bars", "wood", "stone", "cats"}
CONDS = set("drinks_low drinks_high food_low food_high meat_low cats_many pop_small pop_big "
            "young_fort old_fort raining snowing clear spring summer autumn winter peace "
            "recent_death".split())
LOWER_SLOTS = {"prof", "thing", "creature", "place_kind", "weather", "guest_prof", "guest_job"}

BREAK_KINDS = set("death pet_death birth migrants caravan diplomat artifact masterpiece mood beast "
                  "siege soldier civilian quota marriage noble generic".split())
SEGMENTS = set("markets weather sports world trade works crossfire interview".split())
FIELD_KINDS = set("tavern temple library hospital guildhall dining barracks pasture depot workshop "
                  "farm dig entrance machine generic".split())
ANSWER_MOODS = set("happy stressed neutral child soldier busy".split())
WEATHER = set("rain snow clear other".split())

# section -> (allowed slots, max len, shape)  shape: list | kinds:<set> | breaking | banter | debate
SECTIONS = {
    "breaking": (GLOBAL | EVENT, None, "breaking"),
    "reaction": (GLOBAL | EVENT, 120, ("kinds", BREAK_KINDS)),
    "open": (GLOBAL, 160, "list"), "close": (GLOBAL, 160, "list"),
    "toss": (GLOBAL | FIELD, 160, "list"), "toss_back": (GLOBAL | FIELD, 160, "list"),
    "banter": (GLOBAL, 160, "banter"), "bumper": (GLOBAL, 160, "list"), "promo": (GLOBAL, 160, "list"),
    "segment": (GLOBAL | {"caravan_civ", "project", "weather"}, 160, ("kinds", SEGMENTS)),
    "field": (GLOBAL | FIELD, 160, ("kinds", FIELD_KINDS)),
    "interview_q": (GLOBAL | FIELD, 160, "list"),
    "interview_a": (GLOBAL | FIELD, 160, ("kinds", ANSWER_MOODS)),
    "weather": (GLOBAL | {"weather"}, 160, ("kinds", WEATHER)),
    "markets": (GLOBAL | STOCK, 160, "list"), "ads": (GLOBAL, 160, "list"),
    "ticker": (GLOBAL | STOCK, 90, "list"), "sports": (GLOBAL, 160, "list"),
    "trade": (GLOBAL | {"caravan_civ"}, 160, "list"), "works": (GLOBAL | {"project"}, 160, "list"),
    "debate": (GLOBAL, 160, "debate"), "world": (GLOBAL, 160, "list"),
}
SLOT_RE = re.compile(r"\{([a-z_0-9]+)\}")


def check_text(where, text, allowed, maxlen, errs):
    if not isinstance(text, str) or not text.strip():
        errs.append(f"{where}: empty text")
        return
    if maxlen and len(text) > maxlen:
        errs.append(f"{where}: {len(text)} chars > {maxlen}: {text[:60]}...")
    for s in SLOT_RE.findall(text):
        if s not in allowed:
            errs.append(f"{where}: unknown slot {{{s}}}")
    if re.sub(SLOT_RE, "", text).count("{") or re.sub(SLOT_RE, "", text).count("}"):
        errs.append(f"{where}: stray brace")
    m = re.match(r"^\W*\{([a-z_0-9]+)\}", text)
    if m and m.group(1) in LOWER_SLOTS:
        errs.append(f"{where}: opens with lowercase slot {{{m.group(1)}}}")


def check_entry(where, e, allowed, maxlen, ids, errs, fields=("text",)):
    if not isinstance(e, dict) or "id" not in e:
        errs.append(f"{where}: entry without id")
        return
    if e["id"] in ids:
        errs.append(f"{where}: duplicate id {e['id']} (also {ids[e['id']]})")
    ids[e["id"]] = where
    for c in e.get("when", []) or []:
        if c not in CONDS:
            errs.append(f"{where} {e['id']}: unknown condition {c}")
    for f in fields:
        check_text(f"{where} {e['id']}.{f}", e.get(f), allowed, maxlen, errs)


def main(files):
    errs, ids, counts, owner = [], {}, {}, {}
    for f in files:
        try:
            data = json.loads(Path(f).read_text(encoding="utf-8"))
        except (OSError, ValueError) as ex:
            errs.append(f"{f}: {ex}")
            continue
        name = Path(f).name
        for sec, body in data.items():
            if sec.startswith("_"):
                continue
            if sec not in SECTIONS:
                errs.append(f"{name}: unknown section {sec}")
                continue
            if sec in owner:
                errs.append(f"{name}: section {sec} also in {owner[sec]} (sections must be owned by one file)")
            owner[sec] = name
            allowed, maxlen, shape = SECTIONS[sec]
            n = 0
            w = f"{name}:{sec}"
            if shape == "list":
                for e in body:
                    check_entry(w, e, allowed, maxlen, ids, errs); n += 1
            elif shape == "banter":
                for e in body:
                    check_entry(w, e, allowed, maxlen, ids, errs, fields=("a", "b")); n += 1
            elif shape == "debate":
                for e in body:
                    check_entry(w, e, allowed, 40, ids, errs, fields=("topic",))
                    lines = e.get("lines") or []
                    if not 4 <= len(lines) <= 6:
                        errs.append(f"{w} {e.get('id')}: needs 4-6 lines, has {len(lines)}")
                    for i, ln in enumerate(lines):
                        check_text(f"{w} {e.get('id')}.lines[{i}]", ln, allowed, maxlen, errs)
                    n += 1
            elif shape == "breaking":
                for kind, kb in body.items():
                    if kind not in BREAK_KINDS:
                        errs.append(f"{w}: unknown kind {kind}")
                    for e in kb.get("heads", []):
                        check_entry(f"{w}.{kind}.heads", e, allowed, 48, ids, errs); n += 1
                        if e.get("text") and e["text"] != e["text"].upper() and not SLOT_RE.search(e["text"]):
                            errs.append(f"{w}.{kind}.heads {e['id']}: heads must be ALL CAPS")
                    for e in kb.get("reads", []):
                        check_entry(f"{w}.{kind}.reads", e, allowed, 160, ids, errs); n += 1
            else:
                kinds = shape[1]
                for kind, lst in body.items():
                    if kind not in kinds:
                        errs.append(f"{w}: unknown kind {kind}")
                    for e in lst:
                        check_entry(f"{w}.{kind}", e, allowed, maxlen, ids, errs); n += 1
            counts[sec] = counts.get(sec, 0) + n
    for k in sorted(counts):
        print(f"{k:12s} {counts[k]}")
    print(f"entries: {sum(counts.values())}")
    for e in errs[:200]:
        print("ERROR", e)
    if len(errs) > 200:
        print(f"... {len(errs) - 200} more errors")
    print(f"errors: {len(errs)}")
    return 1 if errs else 0


if __name__ == "__main__":
    fs = sys.argv[1:] or sorted(str(p) for p in COPY.glob("*.json"))
    sys.exit(main(fs))
