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
    backup(("abandon-" if abandon else "retire-") + site.replace(" ", "")[:20])
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
        click("Abandon the fortress to ruin")
        time.sleep(2)
        click("Abandon", must=False) or click("Yes", must=False)
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


CSS = "local v=dfhack.gui.getViewscreenByType(df.viewscreen_choose_start_sitest,0) or qerror('not on the embark screen'); "


def open_world():
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
    """Run DF's site finder for river + no aquifer; return matching region
    tiles, nearest the old fort first."""
    opt = "df.embark_finder_option"
    click("Find embark location")
    time.sleep(2)
    lua(CSS + f"""for i=2,#v.find_param-1 do v.find_param[i]=-1 end
v.find_param[{opt}.DimensionX]=4 v.find_param[{opt}.DimensionY]=4
v.find_param[{opt}.AquiferLight]=0 v.find_param[{opt}.AquiferHeavy]=0 v.find_param[{opt}.River]=1 print('OK')""")
    click("Begin")
    wait_text(["Match found", "No match", "no match"], 10 * 60, step=5)
    out = lua(f"""local wd=df.global.world.world_data local o={{}}
for x=0,wd.world_width-1 do for y=0,wd.world_height-1 do
  local r=wd.region_map[x]:_displace(y)
  if r.finder_rank>0 and #r.sites==0 and not r.flags.has_site then o[#o+1]=x..','..y end
end end print(table.concat(o,' '))""")
    sites = [tuple(map(int, s.split(","))) for s in out.split() if "," in s]
    if near:
        sites.sort(key=lambda p: (p[0] - near["x"]) ** 2 + (p[1] - near["y"]) ** 2)  # site pos is in region tiles
    log(f"new fort: site finder matched {len(sites)} region tiles")
    return sites


def try_embark(x, y):
    """Embark on region tile (x, y), a 4x4 in its middle. The embark screen
    uses its location fields, not the mouse position, when the map is clicked,
    so: set the location in data, press Embark, click anywhere on the map.
    embark_pos_* are in world-wide local tiles (region * 16 + offset).
    Returns True if the game took it (no aquifer or other warning)."""
    lua(CSS + f"""local l=v.location l.region_pos.x={x} l.region_pos.y={y}
v.region_cent_x={x} v.region_cent_y={y}
l.embark_pos_min.x={x}*16+6 l.embark_pos_min.y={y}*16+6 l.embark_pos_max.x={x}*16+9 l.embark_pos_max.y={y}*16+9
print('OK')""")
    time.sleep(1)
    if "Click on the map to embark" not in dump():
        if not click_last("Embark"):
            return False
        time.sleep(2)
    lua(CSS + f"""local l=v.location l.region_pos.x={x} l.region_pos.y={y}
l.embark_pos_min.x={x}*16+6 l.embark_pos_min.y={y}*16+6 l.embark_pos_max.x={x}*16+9 l.embark_pos_max.y={y}*16+9 print('OK')""")
    dfhack(SCREEN, "tile", "120", "40")   # any tile on the map
    time.sleep(4)
    if focus().startswith("setupdwarfgame") or focus().startswith("dwarfmode"):
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


def embark():
    near = old_site_pos()
    open_world()
    sites = find_sites(near)
    for x, y in sites[:12]:
        if try_embark(x, y):
            log(f"new fort: embarking at region tile ({x},{y})")
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
                ["lua", "df.global.enabler.fps=20 df.global.init.fps_cap=20"]):
        dfhack(*cmd)
    remember_site()
    name = lua("local s=dfhack.world.getCurrentSite() print(dfhack.translation.translateName(s.name,true), dfhack.translation.translateName(s.name,false))")
    log(f"new fort: {name} is up; df-ai running")
    return name


def run(mode="retire", world=False):
    try:
        status("starting: " + ("retire, new world, new fort" if world else mode), running=True, error=None, mode=mode, world_mode=world)
        if mode != "title":
            remember_site()
            status("ending the fort")
            end_fort(abandon=(mode == "abandon"))
        if world:
            new_world()
        status("embarking")
        reset_fort_files()
        embark()
        status("starting df-ai")
        name = start_df_ai()
        status(f"done: {name}", running=False)
        return name
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
