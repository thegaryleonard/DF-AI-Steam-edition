"""Start a new fort unattended: end the current fort (retire, or abandon when
it has fallen), go back to the title screen, embark in the same world close
to the old site (river, no aquifer), and hand the new fort to df-ai.

Every step clicks on-screen text with dfai-screen (DF 53 ignores simulated
keys on these screens) and checks the result in data before going on.

    python new_fort.py            retire the current fort, embark nearby
    python new_fort.py --abandon  abandon it instead (a fallen fort)
    python new_fort.py --title    already at the title screen: just embark
    python new_fort.py --new-world  retire, generate a new world, embark in it
    python new_fort.py --new-world --title   at the title screen: new world + embark

A new world is made from the title screen's "Create new world" with whatever
the basic world settings were last time, then "Play now" (which saves it). The
new world's folder becomes supervisor.json's world_folder, so later forts
(and a fallen fort's replacement) embark there.

The Overseer's Desk starts this (POST /future, with the fort's name typed to
confirm) and shows its progress from supervisor.log ("new fort: ..." lines).

Used by dfai_supervisor.py when a fort falls; run it by hand to test.
"""
import argparse
import json
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

import dfai_supervisor as sup
from dfai_supervisor import CFG, dfhack, log

WORLD = CFG["world_folder"]
STATUS = Path(__file__).with_name("logs") / "new_fort_status.json"


def status(step, **kw):
    """Progress for the Overseer's Desk."""
    try:
        d = json.loads(STATUS.read_text(encoding="utf-8")) if STATUS.exists() else {}
    except ValueError:
        d = {}
    d.update(kw, step=step, at=time.strftime("%H:%M:%S"))
    d.setdefault("steps", []).append(f"{d['at']} {step}")
    d["steps"] = d["steps"][-30:]
    STATUS.write_text(json.dumps(d, indent=1), encoding="utf-8")
    log(f"new fort: {step}")
GEAR_TILE = (-29, 1)       # the main menu gear, top right (tiles from the right edge)
SCREEN = "dfai-screen"


class Failed(Exception):
    pass


def focus():
    out = dfhack("lua", "print(dfhack.gui.getCurFocus(true)[1])") or ""
    return out.strip()


def dump():
    return dfhack(SCREEN, "dump") or ""


def click(text, must=True):
    out = (dfhack(SCREEN, "click", text) or "").strip()
    log(f"new fort: click {text!r}: {out[:60]}")
    if must and "FOUND" not in out.replace("NOTFOUND", ""):
        raise Failed(f"button {text!r} is not on screen (focus {focus()})")
    return "NOTFOUND" not in out


def wait_text(texts, timeout, step=5):
    """Wait until one of texts is on screen; returns it."""
    if isinstance(texts, str):
        texts = [texts]
    end = time.time() + timeout
    while time.time() < end:
        d = dump()
        for t in texts:
            if t in d:
                return t
        time.sleep(step)
    raise Failed(f"waited {timeout}s for {texts} (focus {focus()})")


def wait_focus(prefix, timeout, step=5):
    end = time.time() + timeout
    while time.time() < end:
        f = focus()
        if f.startswith(prefix):
            return f
        time.sleep(step)
    raise Failed(f"waited {timeout}s for screen {prefix} (focus {focus()})")


def lua(code):
    return (dfhack("lua", code, timeout=60) or "").strip()


# --- ending the current fort ------------------------------------------------

def backup(tag):
    save = Path(CFG["save_dir"])
    dst = Path.home() / "DFBackups" / f"pre-{tag}-{datetime.now():%Y%m%d-%H%M}"
    for name in [WORLD, "autosave 1", "autosave 2", "autosave 3"]:
        if (save / name).is_dir():
            shutil.copytree(save / name, dst / name, dirs_exist_ok=True)
    log(f"new fort: backed up {WORLD} and autosaves to {dst}")


def stop_stream_scripts():
    for cmd in (["dfai-room-tour", "stop"], ["dfai-spectate-keeper", "stop"], ["disable", "spectate"],
                ["disable", "df-ai"], ["unload", "df-ai"]):
        dfhack(*cmd)
    lua("df.global.pause_state = true")


def end_fort(abandon):
    site = lua("local s=dfhack.world.getCurrentSite() print(s and dfhack.translation.translateName(s.name,true) or '?')")
    backup(("abandon-" if abandon else "retire-") + ("".join(c for c in site if c.isalnum())[:20] or "fort"))
    stop_stream_scripts()
    time.sleep(3)
    ENDED = ["Save world and return to title menu", "Return to title", "Start new game in existing world"]
    d = dump()
    if any(t in d for t in ENDED):
        log("new fort: the game already offers to leave this fort")
    else:
        dfhack(SCREEN, "tile", str(GEAR_TILE[0]), str(GEAR_TILE[1]))
        time.sleep(2)
        if not focus().startswith("dwarfmode/Options"):
            raise Failed(f"the game menu did not open (focus {focus()})")
        leave(abandon, site)
    wait_text(ENDED, 30 * 60, step=10)
    if click("Save world and return to title menu", must=False) or click("Return to title", must=False):
        log("new fort: saving the world")
        # DF 53 asks which timeline to save to; the recommended one keeps a single save
        time.sleep(3)
        if "Save to this timeline" in dump():
            click("Save to this timeline")
    wait_focus("title", 30 * 60, step=15)


def leave(abandon, site):
    if abandon:
        # during a siege DF 53 offers "Succumb to the invasion" instead
        if not click("Abandon the fortress to ruin", must=False):
            click("Succumb to the invasion")
        time.sleep(2)
        click("Abandon", must=False) or click("Succumb", must=False) or click("Yes", must=False)
    else:
        click("Retire the fortress (for the time being)")
        time.sleep(2)
        click("Retire")
    log(f"new fort: {'abandoning' if abandon else 'retiring'} {site}; the world simulates")


# --- a new world -------------------------------------------------------------

def new_world():
    """From the title screen: Create new world (basic settings as last used),
    wait for history to finish, Play now. Returns the new world's folder."""
    global WORLD
    save = Path(CFG["save_dir"])
    before = {p.name for p in save.iterdir() if p.is_dir()}
    wait_focus("title", 60)
    time.sleep(3)
    click("Create new world")
    time.sleep(5)
    status("world generation settings open")
    # the basic settings screen: its main button is "Create world" (a returning
    # player may first be asked whether to use the last settings)
    for t in ["Create world", "Create new world", "Generate world"]:
        if click(t, must=False):
            break
    else:
        raise Failed(f"no create-world button on the world generation screen (focus {focus()})")
    status("generating the world (this takes a while)")
    found = wait_text(["Play now", "Play Now", "Use this world"], 3 * 3600, step=30)
    time.sleep(5)
    click(found)
    status("world finished; saving it")
    wait_focus("choose_game_type", 30 * 60, step=10)
    after = [p for p in save.iterdir() if p.is_dir() and p.name not in before and p.name.startswith("region")]
    if not after:
        raise Failed("the new world's folder did not appear in the save directory")
    WORLD = max(after, key=lambda p: p.stat().st_mtime).name
    cfg = json.loads(sup.CFG_FILE.read_text(encoding="utf-8-sig")) if sup.CFG_FILE.exists() else {}
    old = cfg.get("world_folder", CFG["world_folder"])
    cfg["world_folder"] = WORLD
    cfg.setdefault("past_worlds", []).append(old)
    sup.CFG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    CFG["world_folder"] = WORLD
    # a new world has no old fort to embark near
    p = Path(CFG.get("state_dir", Path(__file__).parent)) / "last_site.json"
    if p.exists():
        p.unlink()
    status(f"new world saved as {WORLD}", world=WORLD)
    return WORLD


def follow_game_world():
    """Use the world the game has loaded (or last had loaded), not the one in
    supervisor.json: a world made by hand never got there, so "retire, new
    fort here" looked for the previous world (region59) and failed."""
    global WORLD
    out = (lua("print('WF '..tostring(dfhack.world.ReadWorldFolder and dfhack.world.ReadWorldFolder() or ''))") or "")
    name = out.split("WF ", 1)[1].strip() if "WF " in out else ""
    folder = Path(CFG["save_dir"]) / name
    if not name or name == WORLD or not folder.is_dir() or not any(folder.glob("world.*")):
        return WORLD
    cfg = json.loads(sup.CFG_FILE.read_text(encoding="utf-8-sig")) if sup.CFG_FILE.exists() else {}
    old = cfg.get("world_folder", CFG["world_folder"])
    cfg["world_folder"] = name
    if old and old != name:
        cfg.setdefault("past_worlds", []).append(old)
    sup.CFG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    CFG["world_folder"] = WORLD = name
    log(f"new fort: following the game's world {name} (was {old})")
    return WORLD


def reset_fort_files():
    """The desk's per-fort lists mean nothing in a new fort."""
    cfgdir = Path(CFG["df_dir"]) / "dfhack-config"
    for name in ["dfai-overseer-dig.txt", "dfai-tour-off.json", "dfai-tour-stops.json"]:
        f = cfgdir / name
        if f.exists():
            f.unlink()


# --- the new embark ---------------------------------------------------------

def old_site_pos():
    p = Path(CFG.get("state_dir", Path(__file__).parent)) / "last_site.json"
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return None


def remember_site():
    out = lua("local s=dfhack.world.getCurrentSite() if s then print(s.pos.x, s.pos.y, s.id) end")
    parts = out.split()
    if len(parts) == 3:
        p = Path(CFG.get("state_dir", Path(__file__).parent)) / "last_site.json"
        p.write_text(json.dumps({"x": int(parts[0]), "y": int(parts[1]), "site_id": int(parts[2])}))


# embark size in region tiles (48x48 map tiles each). User: "try 2x2 and see
# how that works" - a smaller map the stream camera can show more of.
EMBARK = max(1, min(16, int(CFG.get("embark_size", 2))))
LO = 8 - EMBARK // 2
HI = LO + EMBARK - 1

CSS = "local v=dfhack.gui.getViewscreenByType(df.viewscreen_choose_start_sitest,0) or qerror('not on the embark screen'); "


def open_world():
    if focus().startswith("choose_start_site"):
        return  # already there (a retry)
    if focus().startswith("choose_game_type"):
        pass    # straight from a new world's "Play now"
    elif focus().startswith("title"):
        pick_world()
    wait_focus("choose_game_type", 10 * 60, step=5)   # after loading the world (adopt_region)
    time.sleep(3)
    click("Fortress")
    wait_focus("choose_start_site", 10 * 60, step=10)
    time.sleep(5)


def pick_world():
    time.sleep(3)
    click("Start new game in existing world")
    time.sleep(3)
    out = lua(sup.TITLE_LUA + f"""
for i,r in ipairs(t.region_choice) do
  if r.filename_noext == '{WORLD}' then t.scroll_position_region_choice = i print('OK') return end
end print('NOWORLD')""")
    if "OK" not in out:
        raise Failed(f"world {WORLD} is not in the title screen's list: {out[:100]}")
    click(f"Folder: {WORLD}")
    time.sleep(5)


def find_sites(near):
    """Pick embark tiles (user: "you can be in a savage area it just means big
    animals but you want good weather usually and trees and a river/stream is
    a bonus"). DF's site finder only rules out aquifers; then every match is
    scored here: never evil or salty, mild weather, trees, a river/stream as
    a bonus, a little for being near the old fort (a new world: its middle).
    Best first."""
    opt = "df.embark_finder_option"
    lua(CSS + "v.choosing_embark=false v.zoomed_in=false v.doing_site_finder=false print('OK')")
    time.sleep(1)
    if "Clear find results" in dump():
        click("Clear find results", must=False)
        time.sleep(2)
    if not click("Find embark location", must=False):
        raise Failed(f"no site finder button (focus {focus()})")
    time.sleep(2)
    # the finder panel can be slow to open right after the world map loads
    # (Fortresstome -> next fort: "Begin" was not on screen 2 s after the
    # click): wait for it, and click once more if it never came
    for attempt in range(2):
        for _ in range(10):
            if "Begin" in dump():
                break
            time.sleep(1.5)
        else:
            if attempt == 0:
                log("new fort: the site finder didn't open; clicking 'Find embark location' again")
                click("Find embark location", must=False)
                time.sleep(3)
                continue
        break
    lua(CSS + f"""for i=2,#v.find_param-1 do v.find_param[i]=-1 end
v.find_param[{opt}.DimensionX]={EMBARK} v.find_param[{opt}.DimensionY]={EMBARK}
v.find_param[{opt}.AquiferLight]=0 v.find_param[{opt}.AquiferHeavy]=0 print('OK')""")
    time.sleep(1)
    # what the finder shows for those settings (Twistgravel flooded from an
    # aquifer even so: keep a record of what "0" means on screen)
    log("new fort: finder aquifer settings: " + " | ".join(l.split("\t", 1)[-1].strip() for l in dump().splitlines() if "quifer" in l))
    click("Begin")
    wait_text(["Match found", "No match", "no match"], 10 * 60, step=5)
    # the finder panel hides the Embark button: close it, the results stay
    lua(CSS + "v.doing_site_finder=false print('OK')")
    time.sleep(1)
    if near:
        cx, cy = near["x"], near["y"]   # site pos is in region tiles
    else:
        wh = lua("local wd=df.global.world.world_data print(wd.world_width, wd.world_height)").split()
        cx, cy = (int(wh[0]) // 2, int(wh[1]) // 2) if len(wh) == 2 else (64, 64)
    out = lua(f"""local wd=df.global.world.world_data
local river={{}}
for _,rv in ipairs(wd.rivers) do for i=0,#rv.path.x-1 do river[rv.path.x[i]*1000+rv.path.y[i]]=true end end
local o={{}}
for x=2,wd.world_width-3 do for y=2,wd.world_height-3 do
  local r=wd.region_map[x]:_displace(y)
  if r.finder_rank>0 and #r.sites==0 and not r.flags.has_site and r.evilness<66 and r.salinity<10 and r.elevation>99 and r.elevation<250 then
    local s=0
    s=s-math.abs(r.temperature-55)*2                      -- mild weather
    s=s+math.min(r.vegetation,70)                         -- trees
    if r.evilness>=33 then s=s-40 end                     -- leaning evil
    if r.rainfall<20 then s=s-30 end                      -- desert
    -- water: Twistgravel died of thirst and Fortresstome could never fill its
    -- farm ponds ("No water source"): a river or brook ranks above any dry site
    if river[x*1000+y] or r.flags.has_river or r.flags.is_brook then s=s+200 end
    s=s-math.sqrt((x-{cx})^2+(y-{cy})^2)*0.5
    o[#o+1]={{x,y,math.floor(s)}}
  end
end end
table.sort(o,function(a,b) return a[3]>b[3] end)
local t={{}} for i=1,math.min(30,#o) do t[#t+1]=o[i][1]..','..o[i][2]..','..o[i][3] end print(#o, table.concat(t,' '))""")
    parts = out.split()
    sites = [tuple(map(int, p.split(",")[:2])) for p in parts[1:] if p.count(",") == 2]
    log(f"new fort: site finder matched {parts[0] if parts else 0} tiles; best: {' '.join(parts[1:6])}")
    return sites


def try_embark(x, y):
    """Embark on region tile (x, y), an EMBARK x EMBARK square in its middle. The embark screen
    uses its location fields, not the mouse position, when the map is clicked,
    so: set the location in data, press Embark, click anywhere on the map.
    embark_pos_* are in world-wide local tiles (region * 16 + offset).
    Returns True if the game took it (no aquifer or other warning)."""
    # zoomed in on the region tile: that's where the Embark button lives
    lua(CSS + f"""local l=v.location l.region_pos.x={x} l.region_pos.y={y}
v.doing_site_finder=false v.zoomed_in=true v.zoom_cent_x={x} v.zoom_cent_y={y}
v.region_cent_x={x} v.region_cent_y={y}
l.embark_pos_min.x={x}*16+{LO} l.embark_pos_min.y={y}*16+{LO} l.embark_pos_max.x={x}*16+{HI} l.embark_pos_max.y={y}*16+{HI}
print('OK')""")
    time.sleep(2)
    # the embark panel lists the site's features: an aquifer floods the fort
    # (Twistgravel: the lower fort cut off, haulers stuck, 29 died of thirst)
    d = dump()
    if "quifer" in d:
        log(f"new fort: ({x},{y}) has an aquifer: skipped")
        return False
    if "Click on the map to embark" not in d:
        if not click_last("Embark"):
            return False
        time.sleep(2)
    lua(CSS + f"""local l=v.location l.region_pos.x={x} l.region_pos.y={y}
l.embark_pos_min.x={x}*16+{LO} l.embark_pos_min.y={y}*16+{LO} l.embark_pos_max.x={x}*16+{HI} l.embark_pos_max.y={y}*16+{HI} print('OK')""")
    dfhack(SCREEN, "tile", "120", "40")   # any tile on the map
    time.sleep(4)
    if focus().startswith("setupdwarfgame") or focus().startswith("dwarfmode"):
        return True
    d = dump()
    # savage land only means big animals: take it; anything else (evil, salt
    # water, an aquifer - the savage warning lists them together, and
    # confirming it put Twistgravel on a light aquifer that flooded) is turned down
    if "savage" in d.lower() and not any(w in d.lower() for w in ("evil", "salt", "aquifer", "flood")) and "Confirm" in d:
        click("Confirm", must=False)
        time.sleep(4)
        if focus().startswith("setupdwarfgame") or focus().startswith("dwarfmode"):
            log(f"new fort: ({x},{y}) is savage: taken anyway")
            return True
        d = dump()
    warn = [l.strip() for l in d.splitlines()[:4] if "selected" in l or "aquifer" in l.lower()]
    log(f"new fort: ({x},{y}) not taken: {warn[:1] or d.splitlines()[:2]}")
    click("Abort", must=False)
    time.sleep(2)
    return False


def click_last(text):
    out = (dfhack(SCREEN, "clicklast", text) or "").strip()
    log(f"new fort: clicklast {text!r}: {out[:60]}")
    return "NOTFOUND" not in out


REJECTED = Path(__file__).with_name("logs") / "rejected_sites.json"


def rejected():
    try:
        return {tuple(t[1:]) for t in json.loads(REJECTED.read_text(encoding="utf-8")) if t[0] == WORLD}
    except (OSError, ValueError):
        return set()


def reject(x, y, why):
    try:
        lst = json.loads(REJECTED.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        lst = []
    lst.append([WORLD, x, y, why])
    REJECTED.write_text(json.dumps(lst), encoding="utf-8")


def embark():
    near = old_site_pos()
    open_world()
    bad = rejected()
    sites = [t for t in find_sites(near) if tuple(t) not in bad]
    for x, y in sites[:12]:
        if try_embark(x, y):
            log(f"new fort: embarking at region tile ({x},{y})")
            chosen = (x, y)
            break
    else:
        raise Failed("no candidate site embarked cleanly")
    # "Play now" if the preparation screen appears, then the arrival popup
    end = time.time() + 10 * 60
    while time.time() < end:
        f = focus()
        if f.startswith("setupdwarfgame"):
            click("Play now!", must=False)
        elif f.startswith("dwarfmode"):
            break
        time.sleep(5)
    wait_focus("dwarfmode", 60)
    time.sleep(5)
    click("Okay", must=False)
    time.sleep(3)
    return chosen


def map_problem():
    """Reasons this map is no good, checked on the real map right after
    embark (the site finder's 'Aquifer: No' let Boardghosts through with an
    aquifer 6 levels down)."""
    out = lua("local n=0 for _,b in ipairs(df.global.world.map.map_blocks) do if b.flags.has_aquifer then n=n+1 end end print('AQ '..n)")
    m = re.search(r"AQ (\d+)", out or "")
    if m and int(m.group(1)) > 0:
        return f"an aquifer ({m.group(1)} map blocks)"
    return None


def start_df_ai():
    dfhack("load", "df-ai")
    dfhack("enable", "df-ai")
    lua("df.global.pause_state = false")
    end = time.time() + 300
    log_path = Path(CFG["df_dir"]) / "df-ai.log"
    start = log_path.stat().st_size if log_path.exists() else 0
    while time.time() < end:
        if log_path.exists() and log_path.stat().st_size > start:
            with log_path.open("rb") as f:
                f.seek(start)
                if b"Planning complete" in f.read():
                    break
        time.sleep(10)
    else:
        log("new fort: df-ai did not report 'Planning complete!' within 5 min")
    for cmd in (["enable", "spectate"], ["dfai-spectate-keeper", "start"], ["dfai-follow-label-only"],
                ["overlay", "enable", "dfai-room-tour.label"], ["dfai-room-tour", "start"],
                ["spectate", "set", "tooltip-follow", "false"],
                ["dfai-fps", "start"]):
        dfhack(*cmd)
    remember_site()
    name = lua("local s=dfhack.world.getCurrentSite() print(dfhack.df2utf(dfhack.translation.translateName(s.name,true))..'	'..dfhack.df2utf(dfhack.translation.translateName(s.name,false)))")
    log(f"new fort: {name} is up; df-ai running")
    return name


def run(mode="retire", world=False):
    try:
        status("starting: " + ("retire, new world, new fort" if world else mode), running=True, error=None, mode=mode, world_mode=world)
        if not world:
            follow_game_world()
        if mode != "title":
            remember_site()
            status("ending the fort")
            end_fort(abandon=(mode == "abandon"))
        if world:
            new_world()
        for attempt in range(4):
            status("embarking" if not attempt else f"embarking (try {attempt + 1})")
            reset_fort_files()
            x, y = embark()
            why = map_problem()
            if not why:
                status("starting df-ai")
                name = start_df_ai()
                if "disabled" not in (dfhack("plug", "df-ai") or "disabled"):
                    status(f"done: {name}", running=False)
                    return name
                why = "df-ai could not fit its plan to this map"
            log(f"new fort: ({x},{y}) rejected after embark: {why}; abandoning it at once")
            reject(x, y, why)
            if attempt == 3:
                raise Failed(f"four sites in a row were no good (last: {why})")
            end_fort(abandon=True)
    except Failed as e:
        status(f"FAILED: {e}", running=False, error=str(e))
        log(f"new fort FAILED: {e}")
        sup.notify(f"starting a new fort failed: {e}. Needs a human (or me) to finish by hand.", ping=True)
        return None


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--abandon", action="store_true")
    g.add_argument("--title", action="store_true")
    ap.add_argument("--new-world", action="store_true", help="generate a new world before embarking")
    a = ap.parse_args()
    r = run("abandon" if a.abandon else "title" if a.title else "retire", world=a.new_world)
    sys.exit(0 if r else 1)
