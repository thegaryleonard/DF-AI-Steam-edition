# Beast trap chamber (forgotten beasts, titans, megabeasts)

User request (2026-11-10, after forgotten beasts killed ~24 Cloisterbolt dwarves, one of them 13 soldiers in 5 game days):

> the fix is to have a chamber you can lock on both sides to trap the beast that has a wall you can shoot through and another path for the archers so they dont have to cross the beast.

Status: research and design done; the behaviour change (archers shoot, melee holds until the beast is badly wounded) is in df-ai (`Population::military_great_beast`). The chamber itself is NOT built yet; the build plan is below and in the dwarf-fortress-modding skill section "Beast trap chamber (user request, in progress)".

## What the research says

Sources: DF wiki (v53.17) Forgotten beast, Building destroyer, Fortification; the beast-trap video "Dwarf Fortress tutorial ep. 20: building a trap for a forgotten beast" (youtube hqcdFgHfdtE, transcript read in full); Quickfort Community Blueprints and blueprints.fortplanner.com (searched: bedrooms, stairs, industry, pump stacks, tombs, hallways; no beast trap or containment blueprint in either library, so the layout below is our own).

Forgotten beasts
- Every one is a building destroyer, `[TRAPAVOID]` and `[NOSTUN]`: cage traps and weapon traps do nothing (except a cage trap a giant cave spider has webbed, and a non-webber that is itself webbed).
- Bridges cannot be raised or lowered while the beast stands on (or under) them. A trigger must check the bridge tiles are empty in the same tick.
- "Walls and raised drawbridges stop them." Doors, hatches, floodgates, grates and bars are destroyed (not just toppled) by building destroyers. Constructions (walls, floors, fortifications) are safe. The wiki contradicts itself on raised bridges ("act like a constructed wall, without the danger of being destroyed" vs "can destroy raised bridges but tend to prefer an unblocked path"): treat a raised bridge as the strongest movable barrier DF has, and back it with a wall-in when a beast stays trapped for long.
- Building destroyers only reach buildings they can path to on the building's own level; a forbidden/locked hatch above them is safe.
- The video's author says that in his version forgotten beasts had stopped destroying buildings and only opened doors, but he still built for destroyers ("the moment the update hits... this has to be another bridge"). Do the same.
- Special attacks: webs (deadliest in melee, "not much at range ... as long as the ranged squad is out of reach"; a webber shoots webs even at targets it can't path to), fire breath and fireballs (fireballs can't be blocked by shields), deadly dust (acts like cave-in dust: flings dwarves into walls, knocks them out; can come from all directions), syndrome breath/secretions (gaseous secretions work even through a cage).
- Beasts of steel or stone are near-unkillable by normal weapons: locking them away forever is the answer. Beasts of ash, steam, fire, mud die to the first hits.
- They are drawn by wealth and noise and "just know where to go" once a path to the fort is open; furniture (as building destroyers) and live animals (bait) pull them.

Fortifications
- Let projectiles through both ways, and also liquids, mist, steam, webs, fire, miasma and smoke. Breath, webs and dust come through them: a fortification wall protects archers from the beast's body, NOT from its ranged attacks.
- A marksdwarf must be Accomplished (skill 7+) to shoot through fortifications from a distance; below that he has to stand right next to the fortification. Known bug: marksdwarves often fail to notice enemies beyond a fortification unless they stand next to it; a 1-tile hall behind the fortifications helps.
- Bug 8160: "creatures can now jump through fortifications". Rare, but a trapped beast is not 100% sealed by fortifications alone.
- Carved fortifications (from smoothed natural or constructed wall) keep a roof; constructed ones are open on top (fliers get over).

Video procedure (the parts that matter)
- A funnel/maze from the caverns to the chamber so the beast wastes time, the chamber on the only path into the fort ("your trap has to have a direct connection to the rest of your fortress otherwise the monster won't be lured"), bridges on both ends, doors as a second layer, carved fortifications for the shooting side.
- A lever room out of the beast's reach; the lever puller kept beside his lever in a burrow so he is there at the moment it matters; civilians in a burrow while it happens.
- Close behind the beast once it is inside; bait animals (cheap, caged/chained) to pull it the last tiles.

## Design (generic, any fort)

```
   fort side                                cavern side
   ----------+                      +---------------
   corridor  B1  . . . . . . . . .  B2  corridor (the beast's way in)
   ----------+  . . . chamber . .  +---------------
             #  . . . 7 x 5  . . .  #
             #  F F F F F F F F F   #   F = carved fortification wall
             #  g g g g g g g g g   #   g = shooting gallery (1-2 tiles deep)
             +--- archer corridor --+--> joins the fort away from B1
```

- Site: on the fort's own way to the caverns (the tunnel `dfai-cavern-seal` walls up or doors; df-ai's cavern outpost access), so every beast that walks to the fort walks through it. 7x5 interior, solid rock all round (`safe()` from dfai-catacomb: no flow, aquifer, outside or feature tiles within 1), no df-ai room on it.
- Locks: a raising drawbridge across each end (B1 fort side, B2 cavern side), 1 tile wide in a 1-tile doorway, raising INTO the doorway so raised it is a wall. Behind B1 a constructed wall slot (built by the script once a beast stays locked more than a few days, removed when it is dead).
- Shooting wall: one long side of the chamber is carved fortifications (smooth, then carve: `dfhack.designations` / quickfort dig `F`... carve needs the stonecutter's engrave job; constructed `Cf` where the wall is not natural rock).
- Gallery: a 1-tile hall right behind the fortifications plus a second row, reached by its own corridor that joins the fort on the fort side of B1 and never touches the chamber, B1, B2 or the cavern tunnel (`canWalkBetween` from the gallery to the chamber interior must be FALSE with both bridges raised, and the gallery corridor must not cross the beast's route with both lowered).
- Ranged attacks: the gallery is in the beast's line of sight by definition (archers need it). Limits to state plainly: webs and dust reach the gallery (webbed archers are stuck but out of reach of the body), fire breath can burn it, syndrome breath/gas can poison it. Mitigations: gallery 2 tiles deep so Accomplished+ archers stand back from the line; only Accomplished+ marksdwarves are posted there (others stay home); a beast whose caste has a breath/spit interaction (`caste.body_info.interactions` / `CAN_BREATHE`-type attack flags) gets the chamber shut and NO gallery crew: it stays locked until it dies or forever.
- Triggers: `ai trigger <bridge id> 0` raises a drawbridge (setTriggerState, tested on the atom smasher; 0 raises, 1 lowers), no lever puller needed (a mild cheat: say so). Optional real levers for show.
- Same-tick safety rule: raise B1 and B2 only in a tick where (a) a great beast stands on an interior tile, not a bridge tile, (b) no unit of our civ (citizen, tame animal) stands inside the chamber or on either bridge, (c) no unit at all stands on a bridge tile (DF refuses to move a bridge with someone on it; the check makes the refusal visible). Never check, then act later.
- Lure: both bridges stay lowered in peacetime, so the cavern route runs through the chamber (traffic cost High on the chamber so dwarves avoid lingering). When a great beast is seen in the caverns: civilians to the Safety burrow (already automatic), the gallery corridor's door forbidden to civilians, archers to the gallery. Bait: if the beast stalls in the caverns for a few days, a caged animal on a restraint in the chamber centre (later; not needed when the chamber is on the only path).
- Behaviour while trapped: crossbow squads station in the gallery (a station order at the gallery tiles, through the same move-order mechanism dfai-archer-posts uses, tagged), melee squads stay home behind B1 (already the df-ai rule until the beast is badly wounded; while it is locked, melee never goes in at all: no door is opened for them).
- Release: once the beast is dead (and nothing else hostile is in the chamber), lower both bridges, take down the wall-in. Corpse, webs and items are hauled as usual.

## What is built (2026-11-10)

- df-ai C++ `Population::military_great_beast` (military.cpp tag_enemies, for megabeasts, semi-megabeasts, forgotten beasts, titans, unique demons): squads with ammunition get the kill order; melee squads get it only when `beast_badly_wounded` (40% of its blood lost or 3+ severed parts, 8+ wounds only for bloodless beasts, or unconscious/webbed) or when no armed squad with ammunition is at home; melee kill orders on the beast are withdrawn while they wait. `ai threats` prints a dry run for every great beast on the map, hidden ones included.
- dfai-archer-posts (existing) still posts the crossbow squads with a line of fire when the beast is in the fort's own space.

## Still to build

See the skill section "Beast trap chamber (user request, in progress)". In short: a generic `dfai-beast-trap.lua` (find / build / arm / status, a desk card, a dfai-projects box, a tour stop), sited on the cavern route, quickfort phases dig -> fortifications -> bridges -> gallery, the same-tick trigger loop, gallery station orders, the wall-in for long stays, and tests: `find` dry run, trigger directions on an empty bridge, the walkability proofs above.
