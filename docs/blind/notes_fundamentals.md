# Blind DF Tutorial Compilation — Fundamentals notes (part A)

Source: Whisper transcripts in `tlg/audio/` (getting_started, embark, labors, farming, fruit_gathering, plant_cloth, animals, windmills_mills, bees, light_aquifer). DF Steam v50+.
Tags: **[BLUEPRINT]** = room layout / adjacency / counts / stockpile settings / build order / stock targets (df-ai JSON). **[BEHAVIOUR]** = C++ logic (labors, kitchen, seasons, work orders, embark, animals, standing orders).
Timestamps refer to the compilation video. Note: the farming chapter transcript stops at 5:13:22, partway through brewing.

---

## 1. Embark & site selection

- [BEHAVIOUR] Choose a civ with a large population. 180 dwarves is called "very small"; he picks one with 2,900. Settle near your own civ: an isolated site (e.g. an island far from your civ) gets fewer migrants and no traders. (0:05:03–0:05:11, 0:50:46–0:51:11)
- [BEHAVIOUR] Reject sites with a "tower" (necromancer) neighbour, which can mean an undead invasion around day 12. Prefer neighbours that are not hostile, with the nearest hostile civ about 2 days away. (0:06:18–0:06:35, 0:51:53–0:51:56)
- [BEHAVIOUR] Prefer "calm" surroundings. Untamed/haunted/joyous wilds make the site harsher. Difficulty depends on neighbours plus the surrounding wilderness. (0:54:46–0:55:02)
- [BEHAVIOUR] Embark size: 4x4 is the default recommendation, 2x2 or 3x3 on a weak PC. Going up to 6x6 or larger causes lag, and 4x4 always has enough room. (0:07:08–0:07:29, 0:54:09–0:54:25)
- [BEHAVIOUR] Avoid heavy aquifers entirely. A light aquifer is acceptable or even useful (underground water). Prefer some soil: the lack of a soil layer is a minus. (0:53:40–0:53:46, 0:54:00, 2:27:02–2:27:16)
- [BEHAVIOUR] Check each biome in the embark area for metals (iron, copper, tin, etc.) and trees. Mountains have no trees, so include a forest biome for wood. (0:53:50–0:55:16)
- [BEHAVIOUR] Steep cliffs or grades can mean a waterfall or trench, which is a nice feature but optional. (0:06:50–0:07:00)

## 2. Embark supplies & skills (Prepare Carefully, 500 points)

- [BEHAVIOUR] The default loadout is: wheelbarrow, step ladder, crutches, splints, buckets, quivers, ropes, pig tail thread, pig tail bags (for seeds), pond turtle, plump helmets, worm meat, dwarven ale and beer, 2 picks, 2 battle axes, an iron anvil, seeds, and cloth. He says the default alone is "just fine". (0:58:24–0:59:22, 1:00:37)
- [BEHAVIOUR] Raise drinks to about 60 each of ale and beer, so the fort lasts until at least autumn without brewing. Dwarves drink every couple of weeks, and the first caravan arrives about 6 months in. Add a little extra food too. (1:00:50–1:01:32)
- [BEHAVIOUR] Raise the number of plump helmets brought. More helmets can't be gathered until the caverns. Every plump helmet eaten raw yields a spawn (seed); a cooked one doesn't. (1:07:37–1:08:41)
- [BEHAVIOUR] Spend leftover points on an extra wheelbarrow, an extra axe, an extra pick and an extra anvil, for a "very safe and easy embark". (1:08:04–1:08:17)
- [BEHAVIOUR] Animals: 3 turkey hens + 1 gobbler (later more hens and gobblers), giving eggs and leather, needing only a pasture and a nest box, and multiplying "infinitely". Also 2 dogs, to train as hunting dogs, and a lamb. Skip cats early: they create garbage, vermin losses are small, and migrants bring cats anyway. (1:02:22–1:03:16, 1:08:54–1:09:19)
- [BEHAVIOUR] Skills for 7 dwarves:
  - Dwarves 1 and 3: miners (2 picks, so 2 miners).
  - Dwarf 2: 1 point woodcutting + 1 point carpentry, so they chop immediately and make better beds.
  - Dwarf 4: mason, for doors, tables, thrones and blocks.
  - Dwarf 5: optional smith.
  - Dwarf 6: planter/brewer + herbalist. Planting matters most for farm yield.
  - Dwarf 7: general laborer with weaving, cooking, mechanics and tanning.
  - Pre-assigned skills mean the dwarves start the right jobs without any labor setup.

  (0:57:45–0:58:10, 1:03:23–1:06:43)

## 3. Early build order (getting_started walkthrough order)

1. [BEHAVIOUR] Pause immediately on load. (0:08:02)
2. [BLUEPRINT] Put a temporary "all" stockpile on the surface near the wagon, with stone and wood disabled so it isn't flooded with boulders and logs. Refuse and corpses are excluded by "all" anyway. Expand it when the wagon unload fills it. (0:11:00–0:12:14)
3. [BEHAVIOUR] Designate gathering of surface plants (bushes, berries, barley) right away in temperate biomes. (0:10:31–0:10:56)
4. [BLUEPRINT] Dig a staircase down. Put the fort core at least 2 z-levels below the surface, so tree-felling doesn't open holes in the ceiling. The farm level is the exception: it goes in the soil layer. (0:15:12–0:15:36)
5. [BEHAVIOUR] Use dig priorities: dig the lower living area before the upper farm area. Give a pick to the idle expedition leader to get a second miner. (0:16:10–0:16:41)
6. [BLUEPRINT] "Dwarves need three things: food, beer, and beds." Core rooms are a tavern (a large dug-out area at the bottom), bedrooms on another level, and farms in the soil layer. (0:15:43–0:17:14)
7. [BEHAVIOUR] Fell trees early (designate several), but avoid felling big dense clumps all at once, because collapsing trees can kill dwarves. (0:17:18–0:17:42)
8. [BLUEPRINT] Build a carpenter's workshop at the fort entrance, from stone so wood is saved. Queue 7 beds, one per starting dwarf. (0:17:46–0:18:16)
9. [BLUEPRINT] Seed stockpile on the farm level, with barrels set to 0. Remove seeds from the general "all" pile. (0:19:03–0:19:33)
10. [BLUEPRINT] Plump helmet farm plot, all 4 seasons. (0:19:46–0:20:33)
11. [BLUEPRINT] Mason's (stoneworker's) workshop for stone doors and furniture. Blocks are a quarter of a boulder's weight and make construction more efficient. (0:20:47–0:21:23)
12. [BLUEPRINT] Bedrooms: individual rooms with a bed and a door, zoned as bedrooms (multi-select). Dwarves claim them by sleeping there. A bedroom with a door gives a happier thought than a bed alone. (0:21:28–0:22:43)
13. [BLUEPRINT] Pen/pasture zone over grass, with all grazers assigned: donkey, camel, horse, sheep. The walkthrough calls this "extremely crucial". (0:22:45–0:23:33)
14. [BLUEPRINT] Tavern: a meeting-area zone in the big hall with an inn/tavern location, tables, and 1 chair per table. Set access to **citizens and long-term residents only** early on, because visitors drink your alcohol. Without a meeting space, dwarves get depressed (socialize need). (0:23:39–0:25:16)
15. [BLUEPRINT] Put the still in or next to the tavern, so dwarves drink right there. (0:25:18–0:25:43)
16. [BEHAVIOUR] Barrels are needed before brewing works: "no empty food storage items" blocks it. Make a few barrels; repeating barrel jobs would consume all the wood. Alternatives are rock pots (craftsdwarf's shop) and metal barrels. (0:26:00–0:26:32, 5:13:16)
17. [BLUEPRINT] Build a fishery whenever anyone fishes, because raw fish isn't eaten unprepared. (0:27:39–0:27:56)
18. [BEHAVIOUR] Year-round underground farming keeps drinks flowing even if the river freezes. (0:27:22–0:27:30)

## 4. Farming

- [BEHAVIOUR] **Plump helmets in all four seasons** (spring, summer, autumn, winter) on the first plot. They're the most important crop: brewable, eaten raw without complaint, and "the easiest and most prolific to keep planted". (0:19:52–0:20:33, 5:12:29–5:13:06)
- [BEHAVIOUR] **Disable COOKING of plump helmets** in the kitchen menu and keep brewing on. Cooking destroys the spawn, and the fort runs out of seeds. Raw eating and brewing both return seeds. He calls this the first thing a new fort should do. (0:14:21–0:14:39, 1:08:28–1:08:41, 5:11:00–5:11:27, 5:12:08–5:12:19)
- [BLUEPRINT] **Seed stockpile: food → seeds → all, barrels = 0.** Seeds are stored in bags. "Remove barrels from your seed stockpiles as a rule." (0:19:05–0:19:24, 5:09:35–5:10:50)
- [BLUEPRINT] Place the seed stockpile and the still next to the farm (on the level just above or beside it). (5:09:03–5:09:10)
- [BLUEPRINT] Shallow farm: one z-level down into soil (dirt, clay or sand all work). He calls it the "least effective form of farming" but an OK early-game stopgap. (0:18:49–0:18:55, 5:08:30–5:08:48)
- [BEHAVIOUR] Fertilizer: "don't bother". (0:20:14–0:20:16)
- [BEHAVIOUR] An optional second crop is pig tails, alternated with plump helmets. Pig tails only grow in some seasons (summer and autumn on his map). Leave the other seasons blank or use another crop. (0:19:53–0:19:57, 3:52:57–3:53:33)
- [BEHAVIOUR] Standing order "only farmers harvest": the farmers then gain planting skill and get better yields. The alternative is everybody harvests. (2:16:00–2:16:11)
- [BEHAVIOUR] In the kitchen, allow cooking of seeds the fort will never plant, to use them up; dwarves like eating them. (2:17:00–2:17:14)

## 5. Food & drink / kitchen

- [BEHAVIOUR] The kitchen menu has cook and brew toggles for each item. All ale is allowed as a cooking ingredient by default, which can silently drain drinks into fancy meals. Disable it if drink stocks matter. Meat, fish and "others" can stay cookable. (2:16:45–2:17:30)
- [BEHAVIOUR] Pig tails may not be set to brew by default. If cloth is the goal, keep them un-brewed so the plants go to thread. (3:52:47, 3:58:15–3:58:35)
- [BEHAVIOUR] Drinks: grapes and raspberries make wine ("dwarves love that stuff"). Honey makes mead. Plump helmets make dwarven wine. Gathered surface plants are brewable too. (2:35:56–2:36:01, 0:25:49–0:25:57)
- [BEHAVIOUR] Standing order "mix similar foods in barrels / do not mix" is available. (2:16:18)
- [BEHAVIOUR] Injured or imprisoned dwarves are brought water in buckets, so keep buckets and a water source. Set "drink water only from designated zones / prefer zones" when there is an underground well. (2:10:41–2:10:44, 2:16:20–2:16:36)

## 6. Gathering / orchard (fruit_gathering)

- [BEHAVIOUR] Plant-gathering **zones** are for repeated, sustained gathering. One-off gather designations are for single harvests. Gather zones can feed a fort with little or no farming early on. (2:32:16–2:32:27, 2:34:23–2:34:35)
- [BLUEPRINT] A food stockpile with custom → food → fruit & leaves + plants receives the gathered items. (2:32:29–2:33:19)
- [BEHAVIOUR] Gather zone toggles: (1) gather fruit in trees in or just above the zone, which needs **step ladders**; (2) gather fruit from shrubs; (3) gather fallen fruit, only in season. (2:34:47–2:36:10)
- [BLUEPRINT] Keep spare step ladders. Make more at the carpenter's, "build a couple right away", because dwarves can get stuck in trees. (2:35:04–2:35:39)
- [BEHAVIOUR] Use gather zones only in calm biomes, or on a cordoned-off tree area used as an orchard. Avoid them in untamed, haunted or other dangerous wilds. (2:36:22–2:36:53)
- [BEHAVIOUR] Gathering also brings in plant fiber (e.g. rope reed) for cloth. (2:33:58–2:34:04, 3:54:03–3:54:15)

## 7. Plant cloth industry

- [BLUEPRINT] The workshops needed are a **farmer's workshop** (process plants → thread + seeds), a **loom** (thread → cloth) and a **clothier's shop** (cloth → clothing). He puts them together. (3:53:33–3:54:44)
- [BLUEPRINT] A separate small pig tail farm plot (in a corner), alongside the plump helmet farms. (3:52:44–3:53:06)
- [BEHAVIOUR] Fibre plants are pig tail, hemp, ramie and rope reed (rope reed grows wild on the surface). Gather them, then put a repeating "process plants" job at the farmer's workshop. (3:52:16–3:52:24, 3:56:21–3:56:57)
- [BEHAVIOUR] Standing order "automatically weave all thread" (on by default) includes spider silk. Clothing can use any cloth or dyed cloth only. Dimple cups can be used for dye. (2:12:43–2:13:13, 3:55:15–3:55:49, 3:54:37)
- [BEHAVIOUR] Turn off "automatically collect webs" when caverns open with many looms, because civilians run into spider-filled caverns. (2:13:16–2:13:34, 3:55:49)
- [BEHAVIOUR] The farmer's workshop also does milking (into barrels) and cheese making. (3:56:30–3:56:39)

## 8. Animals

- [BLUEPRINT] **Grazers need a pen/pasture zone over grass**, or over floor fungus underground in the caverns. Grazers include the starting wagon animals (donkey, horse, camel, mule, elephant), sheep, and cavies. A hungry icon over a wandering animal means a grazer that needs pasturing. (0:22:50–0:23:33, 5:40:37–5:41:02)
- [BEHAVIOUR] Fowl don't need pasturing. Pasture them anyway with a **nest box** in the pasture: they lay there and dwarves collect the eggs as food automatically. (5:41:02–5:41:21)
- [BLUEPRINT] Put a nest box (built at the farming menu) inside the bird pasture; 1–2 per pasture. (5:41:25–5:41:36)
- [BEHAVIOUR] Eggs: forbid them, with a male present, to hatch more birds. Otherwise they are an "infinite" food source. Breed a stock first, then eat. (5:41:57–5:42:17, 1:02:39–1:02:46)
- [BEHAVIOUR] Releasing caged animals: the easiest way is to assign the caged animal to a pasture zone, and dwarves fetch it out of the cage. Don't release untamed animals. (5:43:05–5:43:42)
- [BLUEPRINT] Animal training zone, used for war or hunting training. (5:43:50–5:43:59)
- [BEHAVIOUR] Training: dogs can be war-trained (assigned to military; they attack dangerous wildlife) or hunting-trained (they fetch small prey). "Available as pet" makes an animal claimable as a pet, which then can't be slaughtered. It takes a few attempts. (5:44:13–5:45:37)
- [BLUEPRINT] Put the **butcher's shop and tanner's shop together**, so hides go straight to the tanner and no leather is wasted. (5:45:43–5:46:03, 5:46:51–5:47:01)
- [BEHAVIOUR] Mark an animal for slaughter and the job is added to the butcher's shop automatically. Standing orders "slaughter any marked animal", "automatically butcher carcasses", "auto clean fish" and "auto tannery" should stay on. Mangled or rotten corpses and intelligent creatures can't be butchered. Bigger animals give more leather. (5:46:05–5:47:08, 2:13:34–2:13:45)
- [BEHAVIOUR] Gelding: at the farmer's workshop, toggle gelding on a unit to control breeding (cats, etc.). (5:47:15–5:48:07)

## 9. Mills / querns / power

- [BLUEPRINT] A windmill must have open sky above it. It's built from wood and gives about 40 power, varying with wind. In v50 it can send power out the sides through horizontal axles, as well as down through a gear assembly underneath. (5:49:01–5:52:20, 5:53:23–5:53:48)
- [BLUEPRINT] Millstone placement: either on the surface, linked to the windmill by an axle, or underground below it, linked through a gear assembly directly under the windmill. (5:51:42–5:53:48)
- [BEHAVIOUR] A millstone grinds plants into flour, a cooking ingredient (e.g. quinoa). It **requires bags** (leather or cloth bags, or buy them), plus **mechanisms**. Build a mechanic's workshop first and make about 2 spare rock mechanisms. Make the millstone itself at the mason's workshop. (5:49:53–5:51:39, 5:52:45–5:53:00)
- [BLUEPRINT] Build a mechanic's workshop before any machinery (millstone, screw press, traps). (5:51:22–5:51:33)

## 10. Bees / mead

- [BEHAVIOUR] This only works if a wild honey bee colony is on the map. (3:20:43–3:20:54)
- [BLUEPRINT] Beehives (rock hives from the craftsdwarf's shop) must be on the surface, or underground with a vent hole to the sky. Place several. (3:21:01–3:21:36, 3:26:01–3:26:04)
- [BEHAVIOUR] The hive has "install colony when ready" and "gather products when ready" options. Gathering needs **jugs**: rock jugs from the craftsdwarf's shop, set on repeat. Mead, honey and royal jelly are stored in jugs. (3:21:48–3:23:12)
- [BLUEPRINT] A screw press needs **2 mechanisms**. It presses honeycomb into honey, royal jelly and a wax cake, presses fruit or paste into liquid, and makes paper slurry and oils. (3:23:21–3:25:47)
- [BLUEPRINT] Make a dedicated stockpile for honey and royal jelly (food → extract animal), because jug items in tool or bin piles cause job cancellations. (3:26:31–3:27:12)
- [BEHAVIOUR] Mead is brewed from honey at the still and needs a free barrel. Wax cake becomes wax crafts at the craftsdwarf's shop, for trade or jewellery. Royal jelly is a cooking ingredient. It's slow: about a game year from hive to mead. (3:27:12–3:28:55)

## 11. Aquifers & underground water

- [BEHAVIOUR] Avoid heavy aquifers, which need pumps. A light aquifer is fine and useful: it gives clean underground water, which matters on dangerous surfaces (haunted or untamed sites, or when there are injured dwarves). (2:26:39–2:27:45, 2:31:51)
- [BLUEPRINT] Getting through a light aquifer:
  1. Dig a 2x2 (or 1x1) staircase down 2 levels at a time until damp walls appear.
  2. Dig into the aquifer layer, then build walls around the stair tiles (any material: wood, stone or blocks).
  3. Dig the next level down. A light aquifer is often only 1 layer thick; you're through when the "damp" tag is gone and you hit stone.

  (2:28:12–2:30:28)
- [BLUEPRINT] Free well: channel or dig a small opening into the aquifer layer below and build a well on top. It slowly fills and gives an infinite clean water supply. Channelling up into an aquifer from below creates mist that dwarves enjoy. (2:30:32–2:31:46)
- [BEHAVIOUR] If digging hits an aquifer unexpectedly, steer room digging away from the damp tiles (he rerouted the bedrooms and farms). The ceiling may drip. (0:16:41–0:16:55, 0:17:10, 0:18:42–0:18:49)

## 12. Labors / work details / standing orders

- [BEHAVIOUR] The dwarf with the highest skill in a work detail takes the job first, and others join as they become free. (2:07:15–2:08:07)
- [BEHAVIOUR] Mining needs a pick, woodcutting needs a battle axe, and hunting needs a quiver, a crossbow or bow, and matching bolts or arrows. These details can't be "everybody". **Keep miners and woodcutters as separate dwarves**, or they swap tools and cancel jobs. Keep hunters few. (0:13:03–0:14:06, 2:08:16–2:08:42)
- [BEHAVIOUR] **Fishing is restricted to specific dwarves**, or they fish nonstop, and fishing is dangerous. Plant gathering can be left open: the most skilled dwarf takes it automatically. (0:12:45–0:12:59, 0:14:09–0:14:14)
- [BEHAVIOUR] Setting labors on an individual dwarf flips that work detail to "only selected". So when specialising, specialise several dwarves, not one. (2:11:40–2:12:04)
- [BEHAVIOUR] Use custom work details for hidden labors such as metalsmithing, gem cutting, crafts, butchery and healthcare. Metalcrafting is the most recommended one to add. (2:09:51–2:11:02)
- [BEHAVIOUR] Orderlies give water and treatment to wounded and imprisoned dwarves. (2:10:10–2:10:31)
- [BEHAVIOUR] Check the hauling standing orders (gather animals, food, furniture, bodies, minerals, wood) are on, because a disabled one silently stops hauling. Also: gather refuse from outside, and forbid used ammunition during sieges. (2:13:45–2:14:41)
- [BEHAVIOUR] Children do hauling chores by default. Keep them away from corpse and refuse hauling and from cleaning, to avoid trauma. Don't depend on children. (2:14:45–2:15:42)
- [BEHAVIOUR] Stone use: economic stones are excluded from non-economic jobs by default; toggle them if a job can't find stone. The menu also shows which materials are lava-safe. (2:17:36–2:18:15)
- [BEHAVIOUR] The tasks screen can unsuspend or unforbid jobs in bulk after cancellations (e.g. after an attack). (2:18:20–2:19:10)

## 13. Furniture / production items mentioned

- [BLUEPRINT] Carpenter's: beds (1 per dwarf), barrels, step ladders, wooden chairs. Mason's: doors, tables, millstone, blocks. Craftsdwarf's: rock hives, jugs, rock pots, wax crafts. Mechanic's: mechanisms (keep a couple spare). (0:18:11, 0:21:08, 0:23:44–0:23:57, 0:26:20, 3:21:01, 3:22:49, 5:51:36)
- [BEHAVIOUR] Use repeat jobs sparingly for barrels: repeating barrel jobs burn through all the wood, so make "a couple". Repeating jobs suit jugs. (0:26:22–0:26:32, 3:22:58)
