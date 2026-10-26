# DF 53.16 (win64 STEAM) world-screen missions: reverse-engineering notes

All work was offline: objdump (`../portraits/df.asm`), DFHack 53.16-r3 headers, and offsets measured with MSVC `offsetof`
(`probe.cpp`). The only live access was one bounded read-only `dfhack-run lua` probe (`probe_live.lua`).
Nothing has been run in a game yet. Addresses are unrebased (image base 0x140000000), so add `vinfo->getRebaseDelta()`.

Files here: `dfai_missions.cpp` (plugin sketch; compiles with `cl /c` against the DFHack headers, never linked or run),
`feed.asm` (world screen feed), `set_focus.asm`, `refresh_details.asm`, `ws_ctor.asm`, `index.json`/`xrefs.pkl`
(function and call indexes over df.asm), `pe.py` (exe reader), `probe*.cpp/.bat/.lua`.

## 1. How the world screen works (viewscreen_worldst, vtable 0x141603050)

vtable: [0] get_rect, [1] feed 0x1401d3ac0, [2] logic 0x1401bf520, [3] render 0x1401c17e0, [9] dtor 0x1401bf2d0.
Constructor 0x1401bc430 (called from 0x1401bc3e0). Every button and map click is handled in **feed**, by testing
`enabler+0x33c` (mouse_lbut) and `enabler+0x345`, with the mouse grid position from `gps+0x1c0/0x1c4` (tile) or
`gps+0x1b8/0x1bc` (pixel/16 when `init.display.flag` bit0 is set).

viewscreen_worldst field offsets (MSVC): view_mode 0x1b4, civ_level_military_goals_hf 0x1b8, military_goals_hf 0x1c0,
meet_workers_hf 0x1c8, focus_ax/ay 0x1d0/0x1d4, focus_site 0x1d8, focus_site_artifact 0x1e0, focus_site_prisoner 0x1f8,
focus_site_messenger_candidate 0x210, focus_site_requestable_worker 0x218, civlist 0x230, army_controller 0x2b8,
selected_ac 0x2d8, new_mission[26] 0x2e4, squad 0x350, squad_flag 0x368, messenger_epp 0x380, messenger_ent 0x398,
messenger_flag 0x3b0, request_nem 0x3d8, diplomacy_topic[17] 0x3f8; sizeof 0x8480.

### Constructor (0x1401bc430): what it fills
- `civ_level_military_goals_hf`: first holder of MILITARY_GOALS in the **civ** (plotinfo.civ_id) whose unit is present.
- `military_goals_hf`: same in the **fortress entity** (plotinfo.main.fortress_entity = site government, group_id).
- `meet_workers_hf`: first present holder of MEET_WORKERS in the fortress entity.
  ("Present" means `hf.unit_id` resolves, `0x14138ed20(unit)` is true, `flags1 & 0x102 == 0` (not inactive, not left),
  and `flags1.important_historical_figure` (bit 31) is set.)
  `historical_entity.assignments_by_type` is at entity+0x1798 (vector[43], 0x18 each): MEET_WORKERS=3 at 0x17e0,
  MILITARY_GOALS=18 at 0x1948, DELIVER_MESSAGES=42 at 0x1b88.
- `army_controller` list: every world.army_controllers.all with `entity_id == plotinfo.group_id` and not
  `flag.done_for_dwarf_mode` (0x10).
- `messenger_epp/ent/flag`: every fortress-entity DELIVER_MESSAGES assignment with histfig != -1; ent = fortress
  entity; flag LOCKED_IN unless the holder is present.
- `squad/squad_flag`: world.squads.all with `squad.entity_id == group_id`; LOCKED_IN only when positions[0] is occupied
  and that leader's unit is not present.
- Calls `0x140f01770(world_data, &tmp, fort_site.pos.x, fort_site.pos.y, -1,0,0,0,1,1)`, a flood fill over the world
  map that fills `region_map[x][y].path_map` relative to `world_data.path_start`. That is what "INACCESSIBLE" reads (below).

### Clicking a map tile (feed 0x1401d812a..0x1401d8499)
`set_focus(ws, x, y)` = **0x1401d84f0** (`this, int x, int y`, world-tile coords; first bytes `48 89 4c 24 08 55 41 54 48 8d 6c 24 b1 48 81 ec`).
It returns at once if x,y equal the current focus_ax/ay. Otherwise it sets focus_ax/ay, does
`focus_site = 0x140f4f410(world_data, x, y)` (site at that tile), rebuilds focus_site_artifact/prisoner,
focus_site_messenger_candidate and focus_site_requestable_worker (MAKE_REQUEST helper 0x1401d9250 when the site isn't our
civ's). It is pure data with no UI work.
If focus_site != null, feed sets **view_mode = NEW_MISSION (8)** and fills `new_mission[g]` for g = 0..25: everything is
NOT_DISPLAYED(1) except:
- **SITE_INVASION (2)**: focus_site == fortress_site → OWN_SITE(2); military_goals_hf null → NO_MILITARY_GOALS_HF(8);
  `0x1401bc2d0(world_data, ax, ay) < 0` → INACCESSIBLE(7); site civ == our civ → OWN_CIV(3); else OKAY(0).
- **MAKE_REQUEST (19)**: own site → 2; meet_workers_hf null → 9; inaccessible → 7; no civ → NO_CIV(5);
  our civ and messenger_candidate → (SiteGovernment with flags bit26 → HOSTILE(17), else requestable_worker empty →
  NO_REQUESTABLE_WORKERS(6) else OKAY); not ours → NOT_UNDER_YOUR_CONTROL(4).
- **DIPLOMACY (25)**: own site → 2; meet_workers_hf null → 9; inaccessible → 7; no civ → 5; our civ → 3;
  `!0x140997980(theirciv, ourciv)` (can communicate: same race, or both races have the speech flag; entity flags bit26
  must match) → CANNOT_COMMUNICATE(16); SiteGovernment with flag bit26 → HOSTILE(17); else OKAY.
`0x1401bc2d0(wd,x,y)` = `region_map[x][y].path_map - wd.path_start` (−1 when out of range or below path_start). It only
means something right after the world screen's constructor has run the flood fill.
"Site civ" = `0x1410825c0(site)` = civ_of(site_gov(site)): site_gov = first `site.entity_links[i]` with flags.residence,
type == All(0), and field +0x14 (DFHack name `start_hr`) == −1. civ_of walks entity_links of type PARENT up to a
Civilization (and returns the last entity reached if there is none).

### Clicking a mission button in NEW_MISSION (feed 0x1401d4c0a..0x1401d5166)
Only rows with `new_mission[g] == OKAY` react. The click **creates the army_controller immediately**:
```
ac = 0x14013e720()                 // alloc_army_controller: pool alloc, id = army_controller_next_id++,
                                   // pushed into world.army_controllers.all, fields init to -1/0, goal=-1, data=null
ac.entity_id = fortress_entity.id  // plotinfo+0x8fb8 → +4
ac.flag |= 8                       // civ_rep
0x1400fe960(ac, g)                 // set_goal: free old goal data, operator new + init the goal struct, ac.goal = g
<goal-specific part>
ac.year = cur_year; ac.year_tick = cur_year_tick
ac.site_id = focus_site.id
ac.pos_x = ((site.global_min_x + site.global_max_x) >> 1) * 3 + 1   (same for y)
ac.master_id = ac.id; ac.parent_id = -1
ac.master_hf = <hf>.id; ac.commander_hf = -1
insert_sorted(fortress_entity.army_controllers /*+0x1420*/, ac)       // 0x1400b9fa0
ws.army_controller.push_back(ac); view_mode = MISSION_DETAILS(3); selected_ac = index; 0x1401d9660(ws)
```
- DIPLOMACY: `data.source_abs_smm_x/y` = same formula on the **fortress** site; master_hf = meet_workers_hf.
- MAKE_REQUEST: data+0x1c/+0x20 source_abs_smm_x/y; master_hf = meet_workers_hf.
- SITE_INVASION: civ = site civ; data.source_abs_smm_x/y (+0x5c/+0x60); `invasion_intent = civ ? RAID(4) : EXPLORE(5)`;
  data.flag |= FREE_OWN_CAPTIVES|FREE_OTHER_CAPTIVES|TAKE_ARTIFACTS|TAKE_ITEMS|STEAL_LIVESTOCK (0xf8);
  invasion_stage = 1; ac.percentage_pop = 0; ac.number_pop = 0;
  master_hf = (civ_level_military_goals_hf ?: military_goals_hf).id.
- RESCUE_HF (18, from the citizens list, 0x1401d773f) and RECOVER_ARTIFACT (17, 0x1401d7c88) follow the same pattern
  with site_id = −1, pos = −1 and data[0] = hf id / artifact id.

There is **no "send" button**. MISSION_DETAILS only edits the AC that already exists. The squads leave as soon as they
carry the raid order (the game must be unpaused). "Done" just closes the panel. The X/cancel buttons call
`0x1400ff2d0(&world.army_controllers.all, ac)` → `0x14013e7a0(ac)` (delete: frees mission_report and goal data, unlinks
from the entity and world lists, sets flag.delete_me; the pool slot is reclaimed later).

### MISSION_DETAILS edits (feed 0x1401d5214..)
SITE_INVASION option rows (only when intent != EXPLORE; this writes data.invasion_intent and data.flag):
| row | intent | flag change |
|---|---|---|
| Raid | 4 | clear 0x2,0x4,0x200 |
| Pillage | 6 | clear 0x2,0x4,0x200 |
| Raze | 0 OBLITERATION | clear 0x2,0x4,0x200 |
| Demand one-time tribute | 3 DEMAND_TRIBUTE | set 0x2, clear 0x4,0x200 |
| **Demand ongoing tribute** | **3 DEMAND_TRIBUTE** | **clear 0x2, set 0x4 (DEMAND_TRIBUTE_ONGOING), clear 0x200** |
| Install puppet | 2 | clear 0x2,0x4,0x200 |
| Demand surrender | 2 | clear 0x2,0x4, set 0x200 |
For intent ∉ {1,2,3} (or EXPLORE), the loot toggles XOR 0x8/0x10/0x20/0x40/0x80.

**Squad row** (0x1401d5f15), skipped if squad_flag LOCKED_IN:
- If `squad.assigned_army_controller_id (+0x1d0) == ac.id`, unassign: `0x1400ff870(squad,1)`, remove the id from
  ac.assigned_squads, set the field to −1.
- Otherwise:
  1. `0x1400ff870(squad, true)` deletes ALL squad.orders and every position's orders.
  2. If the squad was on another AC, remove it from that AC's assigned_squads (sorted erase) and set the field to −1.
  3. Create a new order for SITE_INVASION: `squad_order_raid_sitest` (0x30 bytes, vtable 0x141603290, ctor 0x1401bbad0:
     issuer/recipient −1, flags 0, exit_point −30000s) with year/year_tick = now, origin_army_controller = ac.id,
     site_id = ac.site_id. RECOVER_ARTIFACT uses retrieve_artifact (ctor 0x1401bb950); RESCUE_HF uses rescue_hf
     (0x1401bbbd0).
  4. `squad.orders.push_back(order)`; if orders is non-empty, `insert_sorted(ac.assigned_squads, squad.id)` and
     `squad.assigned_army_controller_id = ac.id`.

**Messenger row** (0x1401d64d0; DIPLOMACY/MAKE_REQUEST only; skipped if LOCKED_IN):
- If `epp.assigned_army_controller_id (+0x58) == ac.id`, unassign: `0x1401f9e60(ent.id, epp.id, &ac.assigned_epp_entity_id, &ac.assigned_epp_epp_id)`, then set the field to −1.
- Otherwise: `ac.assigned_epp_entity_id.push_back(fortress_entity.id)`, `ac.assigned_epp_epp_id.push_back(epp.id)`,
  `epp.assigned_army_controller_id = ac.id`. (DFHack: that epp field is "not saved", so the AC vectors are the real record.)

**Diplomacy topic row** (0x1401d5591, only when diplomacy_topic[t] == OKAY):
- If the topic is already in data.topic, erase that index from topic, topic_id1 and topic_id2.
- Otherwise: if t ∈ {RequestPeace 1, DemandSurrender 10, DeclareWar 13}, clear all topics first; else remove any of
  those three. Then push topic = t (int16), topic_id1 = `0x141082590(site)` = **their civ id**, topic_id2 = −1.

Topic statuses (refresh_details 0x1401d9660). rel = our civ's `relations.diplomacy.state[]` entry for their civ
(missing → NoContact 2). Topics 0,2–9,11,12 are never offered (NOT_DISPLAYED), so **TributeAgreement (9) cannot be
asked for by messenger**.
- RequestPeace/DemandSurrender: rel==NoContact → NOT_IN_CONTACT; rel ∈ {TotalWar 1, Skirmishing 5} → OKAY;
  else ALREADY_HAVE_PEACE.
- DeclareWar: at war → ALREADY_AT_WAR, else OKAY.
- SeekAlliance: no civ-level MILITARY_GOALS hf → NO_CIVILIZATION_MILITARY_GOALS_HF; Peace and state.flags bit2 →
  ALREADY_HAVE_ALLIANCE; ethics clash → HOSTILE; at war → AT_WAR; NoContact → NOT_IN_CONTACT; else OKAY.
- **OpenTrade**: ethics clash → HOSTILE; at war → AT_WAR; **NoContact → OKAY** (so a messenger can make first contact);
  their entity flags bit0 && `0x140955a80(theirciv)` → ALREADY_TRADING; else OKAY.
- **ImproveTrade**: NoContact → NOT_IN_CONTACT; HOSTILE; AT_WAR; trading → OKAY else NOT_TRADING.
- "Ethics clash" (r11b) compares `entity_raw+0x3a0` ethic bytes of the two civs.

## 2. Recipe A (recommended): C++ plugin writes the same data (no screen, no mouse)
See `dfai_missions.cpp`. It makes two native calls, both pure data with no UI:
| fn | addr | signature | first 16 bytes |
|---|---|---|---|
| alloc_army_controller | 0x14013e720 | `army_controller* ()` | 40 53 48 83 ec 20 e8 e5 2b 00 00 48 8b 0d 6e db |
| army_controller_set_goal | 0x1400fe960 | `void (army_controller*, int32 goal)` | 48 89 5c 24 20 56 48 83 ec 20 8b 81 38 01 00 00 |
| delete_army_controller (cancel) | 0x14013e7a0 | `void (army_controller*)` | 40 56 48 83 ec 20 48 89 6c 24 38 48 8b f1 48 8b |
Optional, only with a live viewscreen_worldst: set_focus 0x1401d84f0 `void(ws*, int x, int y)` and refresh_details
0x1401d9660 `void(ws*)` (it reads ws.army_controller[selected_ac]).

**The AC must come from alloc (0x14013e720).** ACs live in a pool (`pool_id`, block list at 0x14238c2a0, mutex
0x14238c2d0). An AC made with `df.army_controller:new()` would give the pool a bogus pool_id when DF frees it.
Everything else can be written from C++ or Lua: goal data via set_goal (DF's operator new); the squad order via
`df::allocate<df::squad_order_raid_sitest>()` (DFHack puts the real DF vtable from symbols.xml in it, and that address
matches the ctor's 0x141603290); and deleting old orders with `delete` (virtual dtor slot 5, the same as DF's
`call [vt+0x28]`).

Tribute (first contact): `tribute(site_id, "squadid,...", ongoing=true)` does the following.
1. Checks: target != fortress_site; site civ != our civ; a present MILITARY_GOALS holder exists.
   INACCESSIBLE is not checked (see risks).
2. alloc, entity_id/civ_rep, set_goal(SITE_INVASION), the SITE_INVASION fields above, then intent = DEMAND_TRIBUTE,
   flags ONGOING set and ONE_TIME/SURRENDER cleared. The raid bits stay set, exactly as the UI leaves them.
3. Per squad (fort's, not LOCKED_IN): clear orders, detach from any old AC, push a raid_site order, sorted-insert into
   assigned_squads, set squad.assigned_army_controller_id.
4. Unpause; the squads walk off the map.

Messenger: `messenger(site_id, epp_id, "15,16")` (OpenTrade=15, ImproveTrade=16, RequestPeace=1, SeekAlliance=14,
DeclareWar=13, DemandSurrender=10). The target is any site of the other civ.
1. Checks: site has a civ; it isn't ours; a MEET_WORKERS holder is present; epp is a present DELIVER_MESSAGES holder.
2. alloc, set_goal(DIPLOMACY), source = fort, master_hf = meet_workers hf.
3. Push the topics with topic_id1 = their civ id and topic_id2 = −1.
4. Push fortress_entity.id / epp.id into assigned_epp_*, and set epp.assigned_army_controller_id = ac.id.
The plugin does NOT check topic status; the caller must follow the table above.

Live fort data (read-only probe, 2026-10-26): group 1297, civ 105, site 350; MEET_WORKERS and MILITARY_GOALS are both
epp 7 (hf 6824); DELIVER_MESSAGES are epp 22 (hf 6917) and epp 23 (hf 6855); squads 85–97 all have no AC; the fort has no ACs.

## 3. Recipe B (fallback): drive the real screen's data, still no mouse
Open the screen with `D_WORLD`. From C++, call set_focus(ws, x, y) and fill new_mission[] as above, then do the
Recipe A writes, push the AC into ws.army_controller, set selected_ac and view_mode=3, and call 0x1401d9660(ws).
This only makes the screen display it, so it has no advantage beyond a visual check. Note: writing focus_site +
NEW_MISSION alone gave garbage earlier because the new_mission[] statuses were never filled (feed does that, not
set_focus).

## 4. Risks
- The departure and travel of squads and messengers are DF-internal. They are triggered by the same data (raid order +
  AC; epp ↔ AC link), but the dispatch code for messengers was NOT located. If anything else in render/logic writes
  state at click time, it was missed. A scan of render (0x1401c17e0) found only status/drawing calls (0x1410825c0,
  0x140997980, 0x1401bc2d0, set_focus).
- INACCESSIBLE: path_map is unsaved and only valid after the world screen ctor's flood fill (0x140f01770). Pick targets
  on the fort's landmass (or open D_WORLD first and read `region_map[x][y].path_map - world_data.path_start >= 0`).
  An unreachable target may give stuck armies (fix/stuck-squad exists for that).
- Pool alloc takes a CRITICAL_SECTION. Call only on DF's main thread with the core suspended (a Lua call via
  dfhack-run, or onupdate). Never call it from a render overlay.
- The plugin clears all existing squad orders, as the UI does.
- epp.assigned_army_controller_id is unsaved; after a reload DF rebuilds it (presumably) from the AC vectors.
- Demanding tribute can start a war if refused. The user wants an OK before war-risk moves.
- Tribute/OpenTrade outcomes depend on DF's AI and are not guaranteed.

## 5. Test plan (copy of a save, never the stream fort)
1. Copy the stream save to `<name>-aitest`. Load it in a second session or after the stream (in-game-testing.md).
   Autosave off.
2. Build `dfai_missions` as a df-ai sibling plugin (same CMake as dfai_portrait). `load dfai_missions` → status "ok".
3. Control run: on another copy, make a tribute mission with the REAL mouse once. Dump the AC, goal data, squad order
   and squad fields with a Lua dumper (extend probe_live.lua) as the reference.
4. On the test copy: `lua require('plugins.dfai_missions').tribute(<site>, "<squad>", true)`. Dump the same fields and
   diff them against the reference (only ids and times should differ).
5. `D_WORLD` → Missions list: the mission shows with its squad and "Demand ongoing tribute". Grab a screenshot.
6. Unpause and watch the squad leave (units flags1.left; hf.info.whereabouts.army_id; army.controller == ac).
   Wait for the mission report, the return, and the contact (civlist grows, relations entry exists). Save and reload
   mid-mission, and check it continues.
7. Messenger: `messenger(<site>, 22, "15")` → the messenger leaves, then the announcement on return. Then ImproveTrade
   next year.
8. Cancel path: create one, then `cancel(id)` before unpausing → squad orders cleared, AC gone from lists, no crash after
   several in-game days.
9. Only after all of this, wire it into df-ai or the supervisor, with the user's OK for tribute (war risk).

## 6. Confidence
- High: the field layout and the exact values the UI writes (read directly from feed's code, offsets checked with offsetof).
- Medium-high: the two native calls are safe and sufficient (they have simple signatures and no UI dependency).
- Medium: DF dispatches squads and messengers from this data alone (not traced; the UI writes nothing else).
- Untested in game.
