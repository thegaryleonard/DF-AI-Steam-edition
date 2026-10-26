# -*- coding: utf-8 -*-
"""Third wave of tailored Herald content (python herald/gen_tailored3.py from supervisor/): lines for one exact item noun
(a throne is sat on, a helm is worn on the head, a mug is drunk from), for the dead or moody dwarf's own profession,
horoscopes per month, weather-and-season pieces, pet deaths by species and the butcher's lot, and extra lines per death
cause, condition and mood. Every piece is fit-tagged or condition-gated. Writes library/tailored3_*.json."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tailored_banks import DEATH, MOODS, SHOPS, MINERALS
from gen_tailored import fill, gen
from gen_tailored2 import COND, BEASTS

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")

# one exact noun: n_<noun> fit (plus its category). use = what it is for, sit = where it goes, joke = a line only true of it
NOUN = {
 "throne": ("furniture", "sat upon by somebody important", "the noble quarters", "every noble has suddenly remembered they are tired"),
 "table": ("furniture", "set for dinner", "the dining hall", "dinner will be served on it, and dinner will feel honoured"),
 "chair": ("furniture", "sat on", "the dining hall", "the queue to sit on it has its own chairs"),
 "bed": ("furniture", "slept in", "a lucky dwarf's bedroom", "whoever gets it will never be late for work again, or ever wake up"),
 "door": ("furniture", "hung in a doorway", "the main hall", "it opens, it closes, and it does both beautifully"),
 "cabinet": ("furniture", "filled with somebody's belongings", "a bedroom", "belongings have never been stored so grandly"),
 "armor stand": ("furniture", "used to display a soldier's kit", "the barracks", "the kit on it will look better than the soldier"),
 "weapon rack": ("furniture", "hung with the squad's weapons", "the barracks", "the weapons on it are standing up straighter"),
 "coffin": ("furniture", "kept ready for a funeral", "the tombs", "nobody is in a hurry to try it"),
 "statue": ("statue", "set up in the great hall", "the great hall", "it looks back at you, kindly"),
 "barrel": ("container", "filled and stacked", "the stores", "it rolls straight and stands steady, which the haulers appreciate"),
 "bin": ("container", "filled with goods", "the stockpile", "it holds things so neatly the haulers have started weeping"),
 "bag": ("container", "filled and carried", "the stores", "it carries anything without a single split seam"),
 "chest": ("container", "locked with something precious inside", "a bedroom", "the lid closes with a very satisfying thunk"),
 "mug": ("drinkware", "raised at the tavern", "the tavern", "every toast sounds better from it"),
 "goblet": ("drinkware", "raised at a feast", "the tavern", "wine in it looks like a noble's dream"),
 "crown": ("jewelry", "placed on a noble head", "the treasury", "the nobles have started measuring their heads"),
 "ring": ("jewelry", "slipped on a finger", "the treasury", "it fits any finger that the bookkeeper approves"),
 "bracelet": ("jewelry", "fastened on a wrist", "the treasury", "it jingles just enough to be noticed"),
 "amulet": ("jewelry", "presented to a noble", "the treasury", "it is said to bring luck, which is new for this fort"),
 "scepter": ("jewelry", "carried at ceremonies", "the treasury", "the mayor has practised holding it in a mirror"),
 "figurine": ("figurine", "set on a shelf", "a high shelf", "it is small enough to pocket and too good to"),
 "sword": ("weapon", "carried into battle", "the armory", "it sings when swung, the swordsdwarves say"),
 "axe": ("weapon", "swung at the enemy", "the armory", "the axedwarves have begun drawing lots for it"),
 "spear": ("weapon", "levelled at the enemy", "the armory", "it is long, sharp and very well behaved"),
 "mace": ("weapon", "swung at goblin heads", "the armory", "the macedwarves are humming happily"),
 "hammer": ("weapon", "swung in battle", "the armory", "the hammerdwarves have formed a fan club"),
 "crossbow": ("weapon", "aimed from the walls", "the armory", "the marksdwarves are already arguing over it"),
 "helm": ("armor", "worn on the head", "the armory", "whoever wears it will have the best-protected thoughts in the fort"),
 "breastplate": ("armor", "worn into battle", "the armory", "it fits like it was waiting for its soldier"),
 "shield": ("armor", "carried into the line", "the armory", "the shield wall just got one good shield stronger"),
 "gauntlet": ("armor", "worn on a soldier's hand", "the armory", "it grips a weapon like a promise"),
 "boot": ("armor", "worn on the march", "the armory", "the soldier who wears it will march in comfort"),
 "greaves": ("armor", "strapped to a soldier's legs", "the armory", "the shins of the militia are safer for it"),
 "shirt": ("clothing", "worn under everything else", "the clothing stockpile", "it is soft enough to wear all week, which somebody will"),
 "cloak": ("clothing", "worn against the cold", "the clothing stockpile", "it billows nicely in the corridor draughts"),
 "trousers": ("clothing", "worn every day", "the clothing stockpile", "the seams are perfect, which is rare in trousers"),
 "sock": ("clothing", "worn on one foot", "the clothing stockpile", "it is the finest sock in the fort, and it has a partner somewhere"),
 "hood": ("clothing", "worn against the wind", "the clothing stockpile", "the outdoor workers want one each"),
 "roast": ("food", "served at dinner", "the dining hall", "the smell reached three levels up"),
 "biscuits": ("food", "eaten at breakfast", "the dining hall", "they crunch in exactly the right way"),
 "book": ("book", "read in the library", "the library", "the scholars have stopped arguing to read it"),
 "mechanism": ("tool", "fitted into a lever or a trap", "the engineers' stores", "it clicks as sweetly as a cat purrs"),
 "splint": ("tool", "used on a broken leg", "the hospital", "the doctor hopes nobody needs it, and is glad it's there"),
 "crutch": ("tool", "leaned on by the wounded", "the hospital", "it is so comfortable patients are reluctant to give it back"),
 "bucket": ("tool", "filled at the well", "the well", "it carries water without spilling a drop"),
 "cage": ("tool", "set as a trap", "the trap corridor", "it is ready for the next unwelcome visitor"),
 "lyre": ("instrument", "played at the tavern", "the tavern", "the performers want to borrow it every night"),
 "flute": ("instrument", "played at the tavern", "the tavern", "its notes carry down every corridor"),
 "drum": ("instrument", "beaten at the tavern", "the tavern", "the dancers keep time to it without trying"),
 "bolt": ("ammo", "loosed at the enemy", "the ammunition stockpile", "the marksdwarves have promised to aim carefully"),
}
N_HEADS = ["A MASTERWORK {item}, READY TO BE <USE_UP>", "THE FINEST <NOUN_UP> IN {fort}", "{first}'S <NOUN_UP>: A MASTERWORK", "THE <NOUN_UP> TO BEAT"]
N_REPS = ["{who} has made a masterwork {item}, fit to be <use>. Its place will be <sit>, and <joke>.",
  "A masterwork <noun> is a rare thing. {first}'s {item} will be <use>, and <joke>.",
  "The new {item} is headed for <sit>. Those who have seen it say <joke>.",
  "Of all the <noun>s in {fort}, the new {item} is the best by far. It will be <use> with pride.",
  "{first} says the {item} was made to be <use>. The Herald adds that <joke>."]
N_KICKS = ["The {item} will be <use> soon.", "Find the {item} at <sit>.", "Every <noun> in {fort} feels slightly worse today."]
NA_HEADS = ["{art}: A <NOUN_UP> OF LEGEND", "THE LEGENDARY <NOUN_UP> CALLED {art}"]
NA_REPS = ["{art} is a legendary <noun>, made to be <use>. It will be kept at <sit>, and <joke>.",
  "A legendary <noun>! {art} will be <use> only on the grandest occasions, and <joke>.",
  "{who} has made {art}, a <noun> like no other. The fort agrees <joke>."]
NF_NOTICES = ["The masterwork {masterwork} by {masterwright} will be <use>. Please do not borrow it first.",
  "Now at <sit>: the masterwork {masterwork} by {masterwright}. Admire it; <joke>.",
  "Requests to have the masterwork {masterwork} <use> should go to {masterwright}. Expect a long wait."]

# the dwarf's own trade (prof_<profession> from the announcement)
PROF = {
 "miner": ("the mines", "pick", "dug half the corridors we walk"), "woodcutter": ("the forest edge", "axe", "kept the carpenters busy"),
 "carpenter": ("the carpenter's workshop", "saw", "built half the beds in the fort"), "mason": ("the mason's workshop", "chisel", "set the stones we live among"),
 "stonecrafter": ("the craftsdwarf's workshop", "chisel", "carved the fort's best mugs"), "engraver": ("the halls", "chisel", "carved pictures into our walls"),
 "weaponsmith": ("the forge", "hammer", "armed the militia"), "armorer": ("the forge", "hammer", "kept the militia's armor in shape"),
 "blacksmith": ("the forge", "hammer", "made the fort's tools and fittings"), "metalcrafter": ("the forge", "hammer", "made the fort's finest metal trinkets"),
 "jeweler": ("the jeweler's workshop", "lens", "cut our gems"), "gem cutter": ("the jeweler's workshop", "lens", "cut our gems"), "gem setter": ("the jeweler's workshop", "lens", "set our gems"),
 "craftsdwarf": ("the craftsdwarf's workshop", "file", "made the fort's crafts"), "woodcrafter": ("the craftsdwarf's workshop", "knife", "carved the fort's wooden goods"),
 "bone carver": ("the craftsdwarf's workshop", "file", "turned bones into treasures"), "weaver": ("the loom", "shuttle", "wove the fort's cloth"),
 "clothier": ("the clothier's shop", "needle", "dressed the fort"), "leatherworker": ("the leather works", "awl", "made the fort's bags and belts"),
 "tanner": ("the tanner's shop", "scraper", "tanned the fort's hides"), "brewer": ("the still", "barrel", "kept the fort in drink"),
 "cook": ("the kitchen", "ladle", "fed the fort"), "farmer": ("the fields", "hoe", "grew our food"), "planter": ("the fields", "hoe", "grew our food"),
 "herbalist": ("the wilds", "basket", "gathered plants from the wild"), "fisherdwarf": ("the water's edge", "rod", "brought in our fish"),
 "hunter": ("the wilds", "crossbow", "brought home meat"), "butcher": ("the butcher's shop", "cleaver", "kept the larder stocked"),
 "animal caretaker": ("the pastures", "feed bucket", "cared for our animals"), "animal trainer": ("the pastures", "whistle", "trained our animals"),
 "milker": ("the pastures", "pail", "kept the fort in milk"), "cheese maker": ("the farmer's workshop", "press", "made the fort's cheese"),
 "thresher": ("the farmer's workshop", "flail", "processed the harvest"), "miller": ("the mill", "quern", "ground our flour"),
 "mechanic": ("the mechanic's workshop", "wrench", "built our mechanisms"), "pump operator": ("the pumps", "crank", "kept the water moving"),
 "furnace operator": ("the furnaces", "tongs", "kept the furnaces lit"), "glassmaker": ("the glass furnace", "pipe", "made the fort's glass"),
 "potter": ("the kiln", "wheel", "made our pots"), "doctor": ("the hospital", "bandages", "patched up the wounded"), "surgeon": ("the hospital", "knife", "saved more lives than anyone counted"),
 "bone doctor": ("the hospital", "splint", "set our broken bones"), "diagnostician": ("the hospital", "notebook", "found out what was wrong"),
 "scholar": ("the library", "quill", "asked the questions nobody else would"), "bookkeeper": ("the office", "ledger", "counted everything we own"),
 "manager": ("the office", "work orders", "kept the work flowing"), "broker": ("the trade depot", "scales", "haggled for the fort"),
 "peasant": ("wherever they were needed", "hands", "did whatever needed doing"), "dwarven child": ("the halls", "toys", "made the halls louder and happier"),
 "recruit": ("the barracks", "training weapon", "stood ready to defend us"), "axedwarf": ("the barracks", "axe", "stood in the line for us"),
 "macedwarf": ("the barracks", "mace", "stood in the line for us"), "hammerdwarf": ("the barracks", "hammer", "stood in the line for us"),
 "swordsdwarf": ("the barracks", "sword", "stood in the line for us"), "speardwarf": ("the barracks", "spear", "stood in the line for us"),
 "marksdwarf": ("the walls", "crossbow", "watched the walls for us"), "wrestler": ("the barracks", "bare hands", "stood in the line for us"),
 "militia commander": ("the barracks", "orders", "led our soldiers"), "militia captain": ("the barracks", "orders", "led a squad"),
 "administrator": ("the office", "paperwork", "kept the records"), "expedition leader": ("the founding camp", "map", "led the founders here"),
}
P_DHEADS = ["{fort} LOSES ITS <PROF_UP>", "THE <PROF_UP> IS GONE", "<PLACE_UP> FALLS QUIET"]
P_DREPS = ["{who}, the fort's <prof>, has died. They <did>, and <place> is quiet without them.",
  "The <tool> of {first}, a <prof> who <did>, has been set aside in their memory.",
  "{first} <did>. The fort will need a new <prof>, and will never quite replace this one."]
P_MHEADS = ["THE <PROF_UP> TAKEN BY A MOOD", "{first}, <PROF_UP>, IN A STRANGE MOOD"]
P_MREPS = ["{who}, the fort's <prof>, has fallen into a strange mood. <Place> will have to manage without them for a while.",
  "The fort's <prof> has set down their usual work and taken up something stranger: a strange mood."]
CRAFT_PROF = re.compile(r"weav|cloth|tann|leather|jewel|gem|smith|armor|carpent|mason|stonecraft|engrav|craft|bone|carver|bowyer|glass|potter|mechanic|brewer|cook|butcher|metal")

MONTHS = {
 "Granite": ("steady", "a solid foundation"), "Slate": ("quiet", "a clean start"), "Felsite": ("bright", "a spark of an idea"), "Hematite": ("strong", "red iron in the hills"),
 "Malachite": ("lucky", "green fortune"), "Galena": ("heavy", "silver in the lead"), "Limestone": ("patient", "slow good work"), "Sandstone": ("warm", "the late summer sun"),
 "Timber": ("busy", "a full woodpile"), "Moonstone": ("dreamy", "a pale glow"), "Opal": ("changeable", "colours in the dark"), "Obsidian": ("sharp", "a clear edge"),
}
H_FR = ["<Month> brings a <mood> spirit. Look for <luck>, and take it when it comes.", "Born under <month>? This month you are <mood>. The stars point to <luck>.",
  "<Month>: a <mood> month. Expect <luck>, and a full mug.", "The stones say <month> is <mood>. Trust it, and watch for <luck>.",
  "<Month>, your sign favours <luck>. Be <mood>, and avoid the cats.", "A <mood> <month> lies ahead. <Luck> is closer than it looks.",
  "<Month>: put down the pick for an hour. <Luck> will wait; the ale will not.", "For <month>, the omens are <mood>. Share your luck: <luck> is better shared.",
  "<Month> dwarves are <mood> this season. Your lucky find: <luck>.", "<Month>: the stars are <mood>, the cellar is full, and <luck> is near."]

WS = [("rain", "spring", "spring rain waters the fields"), ("rain", "summer", "a summer shower cools the surface"), ("rain", "autumn", "autumn rain soaks the harvest"),
      ("rain", "winter", "cold winter rain falls"), ("snow", "winter", "winter snow covers the land"), ("snow", "autumn", "early snow dusts the hills"),
      ("snow", "spring", "late snow lingers into spring"), ("clear", "spring", "the spring sky is clear"), ("clear", "summer", "the summer sun is blazing"),
      ("clear", "autumn", "a clear autumn day"), ("clear", "winter", "a bright, cold winter sky")]
WS_FR = ["Weather desk: <what>. Those working outside are thanked; everyone else may stay in.", "Outside, <what>. Inside, the ale is the right temperature.",
  "Today's forecast: <what>. The Herald's advice: work underground.", "Report from the gate: <what>. The guards have opinions.", "<What>, says the gate guard, who would like a hot drink."]

PET_SP = {"sp_cat": ("cat", "purr", "the warm spots by the forge", "mousing"), "sp_dog": ("dog", "bark", "the foot of the bed", "guarding")}
PS_HEADS = ["THE FORT MOURNS A <ANIMAL_UP>", "GOODBYE, GOOD <ANIMAL_UP>", "A <ANIMAL_UP> IS GONE", "NO MORE <SOUND_UP>S IN THE HALLS"]
PS_REPS = ["A beloved <animal> has died. It loved <spot> and was very good at <job>.", "The halls are quieter without the <animal>'s <sound>. Its owner is taking it hard.",
  "Every <animal> has a favourite spot. This one's was <spot>, which is now empty.", "The <animal> will be remembered for its <job>, its <sound>, and its excellent naps."]
SL_HEADS = ["THE BUTCHER'S REPORT", "MEAT FOR THE LARDER", "A STRAY BECOMES SUPPER", "LARDER GAINS, NOBODY ASKS", "SAUSAGES TONIGHT", "THE CLEAVER FALLS"]
SL_REPS = ["The butcher has been busy. The larder is fuller, and the fort has agreed not to ask which animal.", "A stray has been slaughtered for the kitchen. In a fort, nothing goes to waste.",
  "Meat, fat and bone are on their way to the stockpiles. The cook is pleased; the cats are very pleased.", "The butcher reports a good day's work. Dinner reports are expected to be excellent.",
  "A slaughter has added to the stores. The Herald will spare readers the details.", "Strays wander in and the kitchen sends them out as stew. It is the way of things."]
SL_KICKS = ["Dinner is at the usual time.", "The butcher thanks you for your understanding.", "Bones to the craftsdwarves, please.", "Fat to the soap maker."]

D2_HEADS = ["<SHORT>: A WARNING TO {fort}", "{first}, LOST TO <SHORT>", "WHAT TOOK {first}: <SHORT>", "MOURNING IN THE HALLS AFTER <SHORT>", "<SHORT> TAKES A {prof}", "NEVER AGAIN, VOWS {fort}"]
D2_REPS = ["The Overseer has ordered <remedy> after {first} <how>. It is too late for {first}; it may not be too late for the next dwarf.",
  "{first} <how>, the bookkeeper writes, and underlines it. Below that: <remedy>.", "A {prof} <how> <scene>. The fort is asked to look out for one another.",
  "Those who knew {first} say they would want the fort to <lesson>. Let us.", "The cause was <sign>. The cure, say the elders, is <remedy>.",
  "{first}'s friends have asked the Herald to print one sentence: please <lesson>.", "Grief is heavy and the fort carries it together. {first} <how>; the fort remembers.",
  "Let {first}'s end teach us something: <remedy>, and soon."]
D2_KICKS = ["Remember {first}.", "<Remedy>, please.", "A mug will be raised tonight.", "The slab will read: {first}."]

MO2_REPS = ["The fort has seen <word> moods before. They end in legend or in sorrow; the Herald hopes for legend.", "{first} has <look>. Haulers are on standby for whatever is asked.",
  "In a <word> mood, a dwarf will not eat, drink or rest until the work begins. Please help {first} begin.", "Those passing the workshop report {first} <act>. Normal, for a <word> mood."]
SH2_REPS = ["The {shop} is claimed. Whatever {first} makes in there will need <needs>, and probably soon.", "Expect <made> from the {shop}, if the stockpiles hold <needs>.",
  "A mood in the {shop}: the fort's supply of <needs> has never been so closely watched."]
ST2_REPS = ["Every dwarf likes a lucky strike. This one is {mineral}, and <fan> are delighted.", "{mineral} in the rock. It will be <use>; first, it will be admired.",
  "The miners struck {mineral} and the cheer echoed. <Fan> have already started planning."]
B2_REPS = ["A <name> threatens {fort}. Stay calm, stay inside, and <plan>.", "The <name> has the fort's attention. Its arrival from <from_> was not welcomed.",
  "News of the <name> has spread through every hall. <Plan>, says the captain."]
C2_NOTICES = ["{fort} notes that <fact>. Plan accordingly.", "Fact of the week: <fact>.", "Your Herald reports that <fact>; <adv>.", "Remember: <fact>. And <joke>.", "The Overseer is aware that <fact>."]


def main():
    out = {"tailored3_kinds.json": {"kinds": {}}, "tailored3_fold.json": {"notices": [], "horoscopes": {}, "weather_jokes": [], "proverbs": []}}
    K, F = out["tailored3_kinds.json"]["kinds"], out["tailored3_fold.json"]
    add = lambda k, part, items: K.setdefault(k, {}).setdefault(part, []).extend(items)
    for noun, (cat, use, sit, joke) in NOUN.items():
        b = {"noun": noun, "use": use, "sit": sit, "joke": joke}
        slug = re.sub(r"\W+", "", noun); fit = [cat, "n_" + noun]
        add("master", "heads", gen(N_HEADS, b, f"t3-n-{slug}-h", fit))
        add("master", "reps", gen(N_REPS, b, f"t3-n-{slug}-r", fit))
        add("master", "kickers", gen(N_KICKS, b, f"t3-n-{slug}-k", fit))
        add("artifact", "heads", gen(NA_HEADS, b, f"t3-na-{slug}-h", fit))
        add("artifact", "reps", gen(NA_REPS, b, f"t3-na-{slug}-r", fit))
        F["notices"] += gen(NF_NOTICES, b, f"t3-nf-{slug}", fit, ["recent_masterpiece"])
    for prof, (place, tool, did) in PROF.items():
        b = {"prof": prof, "place": place, "tool": tool, "did": did}
        slug = re.sub(r"\W+", "", prof); fit = ["prof_" + prof]
        add("death", "heads", gen(P_DHEADS, b, f"t3-pd-{slug}-h", fit))
        add("death", "reps", gen(P_DREPS, b, f"t3-pd-{slug}-r", fit))
        if CRAFT_PROF.search(prof): continue   # a crafter's trade would hint at what the mood demands
        add("mood", "heads", gen(P_MHEADS, b, f"t3-pm-{slug}-h", fit))
        add("mood", "reps", gen(P_MREPS, b, f"t3-pm-{slug}-r", fit))
    for m, (mood, luck) in MONTHS.items():
        b = {"month": m, "mood": mood, "luck": luck}
        F["horoscopes"][m] = [{"id": f"t3-hs-{m.lower()}-{i + 1}", "text": fill(f, b, i)} for i, f in enumerate(H_FR)]
    for w, s_, what in WS:
        F["weather_jokes"] += [{"id": f"t3-ws-{w}-{s_}-{i + 1}", "text": fill(f, {"what": what}, i), "when": [w, s_]} for i, f in enumerate(WS_FR)]
    for sp, (animal, sound, spot, job) in PET_SP.items():
        b = {"animal": animal, "sound": sound, "spot": spot, "job": job}
        add("pet", "heads", gen(PS_HEADS, b, f"t3-ps-{animal}-h", [sp, "!die_slaughter"]))
        add("pet", "reps", gen(PS_REPS, b, f"t3-ps-{animal}-r", [sp, "!die_slaughter"]))
    add("pet", "heads", gen(SL_HEADS, {}, "t3-sl-h", ["die_slaughter"]))
    add("pet", "reps", gen(SL_REPS, {}, "t3-sl-r", ["die_slaughter"]))
    add("pet", "kickers", gen(SL_KICKS, {}, "t3-sl-k", ["die_slaughter"]))
    for cause, b in DEATH.items():
        b = dict(b); fit = ["die_" + cause]
        add("death", "heads", gen(D2_HEADS, b, f"t3-d-{cause}-h", fit))
        add("death", "reps", gen(D2_REPS, b, f"t3-d-{cause}-r", fit))
        add("death", "kickers", gen(D2_KICKS, b, f"t3-d-{cause}-k", fit))
    for mk, b in MOODS.items():
        add("mood", "reps", gen(MO2_REPS, b, f"t3-mo-{mk}-r", ["mood_" + mk]))
    for shop, b in SHOPS.items():
        slug = re.sub(r"\W+", "", shop.lower())
        add("mood", "reps", gen([x.replace("{shop}", shop) for x in SH2_REPS], b, f"t3-sh-{slug}-r", ["shop_" + shop]))
    for mc, b in MINERALS.items():
        add("strike", "reps", gen(ST2_REPS, b, f"t3-st-{mc}-r", [mc]))
    for bk, b in BEASTS.items():
        add("beast", "reps", gen(B2_REPS, b, f"t3-b-{bk}-r", ["beast_" + bk]))
    for c, b in COND.items():
        F["notices"] += [{"id": f"t3-cn-{c}-{i + 1}", "text": fill(f, b, i), "when": [c]} for i, f in enumerate(C2_NOTICES)]
    total = 0
    for fn, d in out.items():
        json.dump(d, open(os.path.join(HERE, fn), "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=1)
        c = json.dumps(d).count('"id"'); total += c; print(fn, c)
    print("total", total)


if __name__ == "__main__":
    main()
