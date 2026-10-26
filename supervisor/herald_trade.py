"""Trade and diplomacy news for the Herald, read from log files (no game calls).

- df-ai.log  [trade] lines: each caravan's result (traded / no deal), what we
  bought and offered, and warnings (depot not wagon-accessible).
- gamelog.txt: caravan arrivals/departures and their trade sentiment.
- the game manager's log: liaison meetings (what the Mountainhomes want).
Only the current fort counts: df-ai.log is read from its last "Planning
complete!" line.
"""
import json
import re
from collections import Counter
from pathlib import Path

import dfai_supervisor as sup

DF = Path(sup.CFG["df_dir"])
HERE = Path(__file__).parent
TAIL = 4_000_000

DATE = re.compile(r"^(\d+)-(\d+)-(\d+):\d+ ")
MONTHS = ["Granite", "Slate", "Felsite", "Hematite", "Malachite", "Galena", "Limestone",
          "Sandstone", "Timber", "Moonstone", "Opal", "Obsidian"]


def _tail(path, n=TAIL, enc="utf-8"):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - n))
            return f.read().decode(enc, "replace").splitlines()
    except OSError:
        return []


def _stack_name(s):
    return re.sub(r"\s*\[\d+\]$", "", s).strip()


def trades():
    lines = _tail(DF / "df-ai.log")
    start = max((i for i, l in enumerate(lines) if "Planning complete" in l), default=0)
    out, cur = [], None
    for l in lines[start:]:
        if "[trade]" not in l:
            continue
        m = DATE.match(l)
        year, month = (int(m.group(1)), int(m.group(2))) if m else (None, None)
        msg = l.split("[trade]", 1)[1].strip()
        if cur is None or cur.get("year") != year:   # one caravan a year per civ
            mm = re.search(r"traders from (.+?)\.\.\.", msg)
            if True:
                cur = {"year": year, "month": month, "civ": mm.group(1) if mm else None,
                       "bought": Counter(), "offered": Counter(), "result": None, "warnings": []}
                out.append(cur)
        mm = re.search(r"traders from (.+?)(\.\.\.| to | arrive|$)", msg)
        if mm and not cur["civ"]:
            cur["civ"] = mm.group(1)
        if msg.startswith("Bought item:"):
            cur["bought"][_stack_name(msg.split(":", 1)[1])] += 1
        elif msg.startswith("Offering item:"):
            cur["offered"][_stack_name(msg.split(":", 1)[1])] += 1
        elif msg.startswith("Traded "):
            mm = re.search(r"Traded (\d+) stacks worth (\d+) dorfbux for (\d+) stacks worth (\d+) dorfbux with (.+)\.", msg)
            if mm:
                cur["result"] = {"ok": True, "gave_stacks": int(mm.group(1)), "gave": int(mm.group(2)),
                                 "got_stacks": int(mm.group(3)), "got": int(mm.group(4))}
                cur["civ"] = mm.group(5)
        elif msg.startswith("Could not put together"):
            mm = re.search(r"request at (\d+), our best offer at (\d+)", msg)
            cur["result"] = {"ok": False, "asked": int(mm.group(1)) if mm else None, "offer": int(mm.group(2)) if mm else None}
        elif msg.startswith("Warning:"):
            w = msg.split(":", 1)[1].strip()
            if w not in cur["warnings"]:
                cur["warnings"].append(w)
    res = []
    for t in out:
        if not (t["result"] or t["bought"] or t["offered"]):
            continue
        res.append({"year": t["year"], "season": _season(t["month"]), "civ": t["civ"], "result": t["result"],
                    "bought": [[k, v] for k, v in t["bought"].most_common(6)], "bought_kinds": len(t["bought"]),
                    "offered": [[k, v] for k, v in t["offered"].most_common(4)], "warnings": t["warnings"]})
    return res[-4:]


def _season(month):
    if not month:
        return None
    return ["spring", "summer", "autumn", "winter"][min(3, (month - 1) // 3)]


def caravans():
    lines = _tail(DF / "gamelog.txt", 1_000_000, "cp437")
    events, here = [], None
    for l in lines:
        m = re.match(r"A caravan from (.+?) has arrived\.\s+Overall trade sentiments are (\w+)", l)
        if m:
            here = {"civ": m.group(1), "sentiment": m.group(2), "present": True}
            events.append(here)
            continue
        m = re.match(r"The merchants from (.+?) have embarked on their journey", l)
        if m and here and here["civ"] == m.group(1):
            here["present"] = False
    return events[-6:]


def liaison():
    meets, cur = [], None
    for path in (HERE / "logs" / "supervisor.log", HERE / "supervisor.log"):
        for l in _tail(path, 2_000_000):
            if "diplomacy: OPENED meeting" in l:
                cur = {"when": l[:16], "wants": None, "agreement": False, "who": None}
                meets.append(cur)
            elif cur and "diplomacy: SAID" in l:
                said = l.split("diplomacy: SAID", 1)[1].strip()
                m = re.search(r"meets with the (.+?) (\S+ \S+)\s+\2", said)
                if m:
                    cur["who"] = f"{m.group(1)} {m.group(2)}"
                m = re.search(r"A need for (.+?) is expected", said)
                if m:
                    cur["wants"] = m.group(1)
                if "import agreement" in said or "export agreement" in said:
                    cur["agreement"] = True
    meets = list({m["when"]: m for m in meets}.values())   # both logs may hold a meeting
    meets.sort(key=lambda m: m["when"])
    return meets[-3:]


def foreign():
    """The foreign office's log (dfai-foreign-office.lua), current fort only."""
    try:
        b = open(DF / "dfhack-config" / "dfai-foreign.json", "rb").read()
        try:
            txt = b.decode("utf-8")
        except UnicodeDecodeError:
            txt = b.decode("cp437")  # DF's own text (names with accents)
        d = json.loads(txt)
    except (OSError, ValueError):
        return []
    try:
        site = json.load(open(HERE / "last_site.json", encoding="utf-8")).get("site_id")
    except (OSError, ValueError):
        site = None
    if site is not None and d.get("site_id") not in (site, -1):
        return []
    out = []
    for e in d.get("log", [])[-6:]:
        t = re.sub(r"\s+", " ", e.get("text", ""))
        item = {"year": e.get("year"), "text": t}
        m = re.match(r"(.+?) set out for (.+?) to (open|improve) trade with (.+?)\.$", t)
        if m:
            item.update(kind="left", who=m.group(1), site=m.group(2), topic=m.group(3), civ=m.group(4))
        m = re.search(r"made contact with (.+?) at (.+?)\.", t)
        if m:
            item.update(kind="contact", civ=m.group(1), site=m.group(2))
        m = re.search(r"The proposal was (.+?)\.", t)
        if m:
            item.setdefault("kind", "result")
            item["result"] = m.group(1)
        m = re.search(r"The proposal (succeeded|failed)", t)
        if m:
            item.setdefault("kind", "result")
            item["result"] = "a success" if m.group(1) == "succeeded" else "a failure"
        m = re.match(r"(.+?), messenger has returned", t)
        if m:
            item["who"] = m.group(1)
        m = re.search(r"The (?:dwarf|human|elf|goblin) (.+?) of .+? met with the (\w+) (.+?)(?:, (.+) of| of) (.+?),? to (?:make|open|improve|discuss|ask|demand|request|seek)", t)
        if m:
            item.update(who=m.group(1), met_race=m.group(2), met=m.group(3), met_title=m.group(4) or "")
        m = re.search(r"the (?:dwarf|human|elf|goblin) (.+?) could not meet with (.+?) as there were no suitable representatives in (.+?)\.", t)
        if m:
            item.update(kind="nomeet", who=m.group(1), civ=m.group(2), site=m.group(3))
        if re.search(r"lie|lying", t):
            item["lied"] = True
        out.append(item)
    return out


def game_year():
    for l in reversed(_tail(DF / "df-ai.log", 20000)):
        m = DATE.match(l)
        if m:
            return int(m.group(1)), int(m.group(2))
    return None, None


def feed():
    try:
        tr = trades()
        year, month = game_year()
        last = max((t["year"] for t in tr if t.get("year")), default=None)
        return {"ok": True, "trades": tr, "caravans": caravans(), "liaison": liaison(), "foreign": foreign(),
                "year": year, "month": month, "last_trade_year": last}
    except Exception as e:      # never break the paper over a log quirk
        return {"ok": False, "error": repr(e)}


if __name__ == "__main__":
    import json
    print(json.dumps(feed(), indent=1, ensure_ascii=False)[:3000])
