# -*- coding: utf-8 -*-
"""Second wave of tailored Herald content (python herald/gen_tailored2.py from supervisor/), each piece gated so it can't
contradict the live fort: condition-gated notices/almanac/proverbs/classifieds (only while that condition holds), running-
story installments per shortage, Board counters per event kind, sketch-scene words for every mood/death/strike/beast
drawing, beast-type reports, factual quiz and trivia from DF tables, follow-ups. Writes library/tailored2_*.json."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tailored_banks import DEATH, MOODS, MINERALS
from gen_tailored import fill, gen

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")
ITEMCATS = json.load(open(os.path.join(HERE, "itemcats.json"), encoding="utf-8"))["itemcats"]

# ---- live conditions: what is true while the condition holds (subject, a true observation, advice, a joke) ----
COND = {
 "food_low": dict(subj="the larder", fact="the food stockpile is running thin", adv="eat what you take and take only what you eat", joke="the cook has started counting plump helmets out loud", up="FOOD"),
 "food_ok": dict(subj="the larder", fact="the larder is in decent shape", adv="keep the farms planted all the same", joke="the cook has been seen smiling, briefly", up="FOOD"),
 "food_high": dict(subj="the kitchens", fact="there are more prepared meals than mouths", adv="share a meal with a friend", joke="the dining hall has run out of table, not food", up="MEALS"),
 "drinks_low": dict(subj="the cellar", fact="the drink stockpile is low", adv="brewers to the stills, everyone else to the farms", joke="the tavern keeper is pouring smaller mugs and hoping nobody notices", up="DRINK"),
 "drinks_ok": dict(subj="the cellar", fact="the cellar is well stocked", adv="drink, but leave some for the haulers", joke="the brewers have been granted an extra nap", up="DRINK"),
 "drinks_high": dict(subj="the cellar", fact="the barrels are stacked to the ceiling", adv="walk to the cellar before you get thirsty, not after", joke="the cellar now has a cellar", up="BARRELS"),
 "no_meat": dict(subj="the butcher's block", fact="there is no meat or fish in the stores", adv="the hunters and fishers are needed", joke="the butcher has taken up knitting", up="MEAT"),
 "has_meat": dict(subj="the larder", fact="there is meat and fish in the stores", adv="thank the hunters and the fishers", joke="the cats have started visiting the kitchen hourly", up="MEAT"),
 "no_fish": dict(subj="the fishery", fact="there is not a single fish in the stores", adv="send a fisher to the water", joke="the carp are said to be gloating", up="FISH"),
 "has_eggs": dict(subj="the henhouse", fact="there are eggs in the stores", adv="thank a hen today", joke="the hens have formed a union", up="EGGS"),
 "rain": dict(subj="the surface", fact="it is raining outside", adv="keep below, or bring a hood", joke="the outdoor workers have discovered why dwarves live underground", up="RAIN"),
 "snow": dict(subj="the surface", fact="snow is falling outside", adv="keep the gate clear and the boots dry", joke="the snow has been asked to leave and has declined", up="SNOW"),
 "clear": dict(subj="the sky", fact="the sky is clear", adv="if you must go up, go now", joke="the sky is still there, for those who check", up="SKY"),
 "spring": dict(subj="the season", fact="it is spring", adv="plant the fields and watch the gate for migrants", joke="the surface has turned green again, which upsets the miners", up="SPRING"),
 "summer": dict(subj="the season", fact="it is summer", adv="harvest what is ripe and drink plenty", joke="the surface is hot and bright and nobody likes it", up="SUMMER"),
 "autumn": dict(subj="the season", fact="it is autumn", adv="bring in the harvest and check the barrels", joke="the trees are dropping their leaves, which is how trees apologise", up="AUTUMN"),
 "winter": dict(subj="the season", fact="it is winter", adv="keep the stores full and the fires lit", joke="the outdoor pond is now a floor", up="WINTER"),
 "pop_big": dict(subj="the halls", fact="the halls are crowded", adv="be patient in the corridors", joke="there is now a queue for the queue", up="CROWDS"),
 "pop_small": dict(subj="the fort", fact="the fort is small and everyone knows everyone", adv="look after your neighbours, you have so few", joke="the roll call takes no time at all", up="FEW"),
 "pop_mid": dict(subj="the fort", fact="the fort is growing steadily", adv="build bedrooms before they are needed", joke="new faces outnumber old excuses", up="GROWTH"),
 "young_fort": dict(subj="the fort", fact="the fort is still young", adv="dig deep and build the basics first", joke="the founders still argue about where the first stair went", up="NEW"),
 "old_fort": dict(subj="the fort", fact="the fort has seen more than a year", adv="tell the young ones the old stories", joke="the oldest corridor now has a name and a grudge", up="HISTORY"),
 "caverns": dict(subj="the caverns", fact="the caverns are open below", adv="keep the cavern doors shut at night", joke="something down there keeps rearranging the mushrooms", up="CAVERNS"),
 "deep": dict(subj="the deep works", fact="the fort reaches very deep", adv="mind the stairs on the way down", joke="the deepest miners write home by bucket", up="DEPTHS"),
 "caravan_here": dict(subj="the depot", fact="merchants are at the depot", adv="bring your best goods and your hardest bargaining", joke="the merchants have noticed our mugs", up="TRADE"),
 "no_caravan_here": dict(subj="the depot", fact="the depot is quiet", adv="make goods now, so they are ready when the merchants come", joke="the depot clerk is talking to the wagons that aren't there", up="DEPOT"),
 "peace": dict(subj="the borders", fact="the fort is at peace", adv="train anyway; peace is a season, not a promise", joke="the militia has been polishing things that are already shiny", up="PEACE"),
 "at_war": dict(subj="the borders", fact="the fort is at war with {enemy}", adv="keep the gate guarded and the militia drilled", joke="{enemy} are said to read this paper, so the paper says the walls are very high", up="WAR"),
 "has_military": dict(subj="the militia", fact="the fort has a militia", adv="feed the soldiers well", joke="the barracks smell of polish and determination", up="MILITIA"),
 "army_big": dict(subj="the militia", fact="the militia is large", adv="keep them training in turns", joke="the training yard needs its own training yard", up="ARMY"),
 "no_military": dict(subj="the defences", fact="the fort has no militia", adv="raise a squad before you need one", joke="the official defence plan is 'run'", up="DEFENCE"),
 "cats_many": dict(subj="the cats", fact="the fort has a great many cats", adv="watch where you step", joke="the cats have begun holding meetings", up="CATS"),
 "herd_big": dict(subj="the herds", fact="the herds are large", adv="keep the pastures in good order", joke="the animals now outnumber the excuses for not shearing them", up="HERDS"),
 "herd_small": dict(subj="the herds", fact="the fort keeps only a few animals", adv="look after the ones we have", joke="every animal has a name and an opinion", up="ANIMALS"),
 "gems_many": dict(subj="the gem stores", fact="the gem stores are full", adv="keep a few rough ones for strange moods", joke="the jewelers have run out of shelf", up="GEMS"),
 "bars_low": dict(subj="the forges", fact="metal bars are scarce", adv="send the smelters ore and fuel", joke="the smiths are hammering very carefully", up="BARS"),
 "bars_many": dict(subj="the forges", fact="the bar stockpile is full", adv="let the smiths make something grand", joke="the bookkeeper counts the bars twice for the pleasure of it", up="METAL"),
 "wood_low": dict(subj="the woodpile", fact="wood is scarce", adv="send the woodcutters out, carefully", joke="the carpenter is building very small things", up="WOOD"),
 "wood_ok": dict(subj="the woodpile", fact="there is wood in the stores", adv="the carpenter is ready for orders", joke="the woodpile has been described as 'adequate', the highest praise for a woodpile", up="WOOD"),
 "stone_glut": dict(subj="the stone stockpile", fact="there is far more stone than anyone needs", adv="build something big", joke="the stone has started stacking itself out of boredom", up="STONE"),
 "thread_glut": dict(subj="the thread stores", fact="there is a mountain of thread", adv="weave it before it tangles", joke="the weavers have been seen hiding from the thread", up="THREAD"),
 "seeds_many": dict(subj="the seed bags", fact="the seed stores are overflowing", adv="plant more fields", joke="the seeds outnumber the dwarves several hundred to one", up="SEEDS"),
 "farms_many": dict(subj="the farms", fact="the fort has many farm plots", adv="keep the farmers fed and rested", joke="the farmers have started naming the plots", up="FARMS"),
 "has_tavern": dict(subj="the tavern", fact="the fort has a tavern", adv="raise a mug with a stranger", joke="the tavern keeper knows every secret and tells none of them, mostly", up="TAVERN"),
 "has_temple": dict(subj="the temple", fact="the fort has a temple", adv="pray, meditate, or at least sit quietly", joke="the temple is the only room in the fort where nobody hauls anything", up="TEMPLE"),
 "has_library": dict(subj="the library", fact="the fort has a library", adv="read something today", joke="the librarian shushes even the cats", up="LIBRARY"),
 "has_hospital": dict(subj="the hospital", fact="the fort has a hospital", adv="see the doctor when you are hurt, not after", joke="the hospital has more splints than patients, which is how it should be", up="HOSPITAL"),
 "has_catacombs": dict(subj="the catacombs", fact="the fort has catacombs for the dead", adv="visit the tombs and remember", joke="the catacombs are the quietest neighbours in the fort", up="TOMBS"),
 "has_jail": dict(subj="the jail", fact="the fort has a jail", adv="behave", joke="the jail is cleaner than most bedrooms", up="JAIL"),
}
C_NOTICES = ["A reminder from the Herald: <fact>. Please <adv>.", "Notice to all citizens: <fact>. The Overseer asks that you <adv>.", "<Subj> reports: <fact>. Our advice is to <adv>.",
  "Note: <fact>, and <joke>.", "This week <fact>. Readers are asked to <adv>, and to stop asking the Herald about it.", "Public notice regarding <subj>: <fact>.",
  "From the Overseer's office: <fact>. Act accordingly.", "<Fact>. <Joke>."]
C_ALMANAC = ["Almanac: <fact>. The wise dwarf will <adv>.", "Old wisdom for days when <fact>: <adv>.", "When <fact>, the elders say: <adv>.", "Signs of the times: <fact>, and <joke>.",
  "The almanac notes that <fact>. It also notes that <joke>.", "Today's reckoning: <fact>."]
C_PROVERBS = ["When <fact>, <adv>.", "A wise dwarf hears that <fact> and decides to <adv>.", "Mind <subj>, and <subj> will mind you.", "<Fact>; so <adv>."]
C_CLASS = [("Notice", "<Fact>. Please <adv>."), ("Wanted", "Volunteers to help, since <fact>. Apply at <subj>."), ("Advice", "Since <fact>: <adv>."), ("Gossip", "Word is that <joke>.")]
C_GOSSIP = ["Corridor talk: <joke>. Nobody is surprised, since <fact>.", "Our sources at <subj> say <joke>.", "Overheard: 'You know <fact>?' 'Yes. And <joke>.'"]

# ---- running shortages: installments while the streak runs ({days}, {since}, {n}) ----
STREAK = {
 "no_meat": dict(what="no meat", up="MEAT WATCH", end="meat is back", who="the hunters and fishers", sad="the butcher's block stays empty"),
 "no_fish": dict(what="no fish", up="FISH WATCH", end="fish are back in the stores", who="the fishers", sad="the fish stall is still bare"),
 "drinks_low": dict(what="low drink", up="DRY SPELL", end="the cellar is full again", who="the brewers", sad="the tavern pours small mugs"),
 "famine": dict(what="famine", up="FAMINE", end="the larder has recovered", who="the farmers and cooks", sad="plates are thin"),
 "wood_low": dict(what="no wood", up="WOOD SHORTAGE", end="the woodpile is restocked", who="the woodcutters", sad="the carpenter sits idle"),
 "rain": dict(what="rain", up="THE RAINS", end="the rain has stopped", who="the outdoor workers", sad="the surface is soaked"),
 "snow": dict(what="snow", up="THE SNOWS", end="the snow has stopped", who="the gate guards", sad="the surface is white and cold"),
 "drinks_high": dict(what="more drink than room", up="THE GREAT CELLAR", end="the cellar is merely full again", who="the haulers", sad="barrels crowd the corridors"),
 "stone_glut": dict(what="too much stone", up="STONE MOUNTAIN", end="the stone pile has shrunk", who="the masons", sad="the stockpile overflows"),
}
SK_HEADS = ["<UP>, DAY {days}", "<UP>: DAY {days} AND COUNTING", "{days} DAYS OF <WHAT>", "<UP> CONTINUES", "REPORT NO. {n}: <UP>", "STILL <WHAT>, SAYS THE BOOKKEEPER"]
SK_BODIES = ["It has been {days} days of <what> since {since}. <Who> are doing what they can, and <sad>.", "Day {days} of <what>. <Sad>, and the Herald will keep counting until it ends.",
  "Report number {n} on <what>, which began {since}. <Who> ask for patience; <sad>.", "{days} days now. <Sad>. Everyone is asked to help <who> however they can."]
SK_EHEADS = ["IT'S OVER: <UP> ENDS", "<UP> ENDS AFTER {days} DAYS", "GOOD NEWS: <END>", "THE END OF <WHAT>"]
SK_EBODIES = ["After {days} days, <end>. <Who> are thanked, and a mug has been raised.", "<End>. The streak that began {since} lasted {days} days and is now history.",
  "The bookkeeper has closed the file on <what>: {days} days, now over. <Who> may rest."]

# ---- the Board: days since each kind of event ----
COUNTERS = {"death": "a funeral", "pet": "we lost a pet", "tantrum": "a tantrum", "mood": "a strange mood", "artifact": "a new artifact", "masterpiece": "a masterpiece",
  "migrants": "migrants arrived", "caravan": "the last caravan", "strike": "a lucky strike", "birth": "a birth", "siege": "an attack"}
CNT = ["Days since <ev>: {days}", "Days without <ev>: {days}", "It has been {days} days since <ev>", "Count since <ev>: {days} days"]

# ---- scene words for every non-item drawing ----
DEATH_SCENE = {"thirst": "death-thirst", "hunger": "death-hunger", "combat": "death-battle", "bleeding": "death-battle", "drowning": "death-drowning", "vampire": "death-vampire",
  "collapse": "death-collapse", "fire": "death-fire", "fall": "death-fall", "age": "death-age", "infection": "death-sick", "suffocation": "death-sick"}
DS_CAPS = ["A memorial for {who}, who <how> <scene>. Our artist drew it plainly.", "The scene, sketched with care: {first} <how>. The fort is asked to <lesson>.",
  "Our artist's tribute to {first}. Below it, in small letters: <remedy>.", "The place where {first} <how>. Friends have left small things beside the slab.",
  "A quiet drawing for a sad day. {who} <how>."]
DS_HEADS = ["SKETCH: FAREWELL TO {first}", "{first} <HOW_UP>", "OUR ARTIST REMEMBERS {first}"]
DS_LABELS = ["<SHORT>", "IN MEMORY"]
MOOD_SCENE = {"fey": "mood-fey", "secretive": "mood-secretive", "possessed": "mood-possessed", "macabre": "mood-macabre", "fell": "mood-fell"}
MS_CAPS = ["{who} in a <word> mood, with <look>. Our artist kept a respectful distance.", "The <word> mood, sketched from the doorway: {first} <act>.",
  "{first}, <word>, and the workshop that is about to become very busy.", "Our artist's impression of a <word> mood. The real thing is stranger."]
MS_HEADS = ["SKETCH: A <UP> MOOD", "{first}, <UP>, AS DRAWN"]
STRIKE_SCENE = {"gem": "strike-gem", "ore": "strike-ore", "coal": "strike-coal", "stone": "strike-stone"}
SS_CAPS = ["The miner who found {mineral}, sketched mid-cheer. <Fan> are already on their way.", "{mineral}, as it looked in the rock. It will be <use>.",
  "Our artist went down the mine for this one: {mineral}, and a very happy miner.", "The {mineral} strike, drawn by lamplight. The <feel> was real."]
SS_HEADS = ["SKETCH: THE {mineral} STRIKE", "{mineral}, DRAWN FROM THE MINE"]

# ---- beasts by type (beast_<kind> facts from the announcement) ----
BEASTS = {
 "forgotten": dict(name="forgotten beast", up="FORGOTTEN BEAST", from_="the caverns", how="crawled up out of the dark", fear="whatever it breathes or spits", plan="seal the cavern doors and call the squads"),
 "titan": dict(name="titan", up="TITAN", from_="the wilds", how="strode in over the hills", fear="its size, mostly", plan="close the gate and man the walls"),
 "were": dict(name="werebeast", up="WEREBEAST", from_="the night", how="came howling out of the dark", fear="its bite, which spreads the curse", plan="keep everyone inside until the moon passes"),
 "mega": dict(name="great monster", up="MONSTER", from_="the far mountains", how="arrived like a storm", fear="everything about it", plan="send the best squad and pray"),
 "other": dict(name="beast", up="BEAST", from_="the wilds", how="showed up uninvited", fear="its teeth", plan="keep clear and let the militia handle it"),
}
B_HEADS = ["<UP> ATTACKS {fort}", "A <UP> FROM <FROM_>", "<UP>! TO ARMS!", "THE <UP> IS HERE", "{fort} FACES A <UP>", "BEWARE THE <UP>"]
B_REPS = ["A <name> <how>. Citizens are asked to <plan>, and to keep well clear of <fear>.", "The <name> came from <from_>. The militia is moving; everyone else is moving the other way.",
  "Elders say a <name> is to be respected and avoided. The Herald agrees: <plan>.", "The fort's plan for the <name> is simple: <plan>. The fort's fear is also simple: <fear>.",
  "A <name> has come to {fort}. If you see it, you are too close."]
B_KICKS = ["Stay inside. <Plan>.", "Squads to their posts.", "Do not feed the <name>.", "More news as it happens."]
B_CAPS = ["The <name>, sketched from a very safe distance, and a soldier facing it.", "Our artist's impression of the <name>. Our artist is now under a table.",
  "The <name> and the militia. Only one of them was invited."]

# ---- factual quiz and trivia from the game's own tables ----
def quiz_and_trivia():
    quiz, triv = [], []
    om = ITEMCATS["oremetals"]
    metals = sorted({m for v in om.values() for m in v})
    for i, (ore, ms) in enumerate(sorted(om.items())):
        if ore in ("adamantine",): continue
        right = ms[0]; wrong = [m for m in metals if m not in ms]
        opts = [right, wrong[i % len(wrong)], wrong[(i + 3) % len(wrong)]]
        k = i % 3; opts[0], opts[k] = opts[k], opts[0]
        quiz.append({"id": f"tq-ore-{re.sub(r'\W', '', ore)}", "q": f"Which metal is smelted from {ore}?", "options": opts, "answer": k})
        triv.append({"id": f"tt-ore-{re.sub(r'\W', '', ore)}", "text": f"Did you know? {ore[0].upper() + ore[1:]} is an ore: smelt it and you get {' and '.join(ms)}."})
    shops = {"Clothier's Shop": "clothing", "Loom": "cloth", "Leather Works": "leather goods", "Metalsmith's Forge": "metal weapons, armor and furniture",
             "Carpenter's Workshop": "wooden furniture and barrels", "Jeweler's Workshop": "cut gems and decorations", "Kitchen": "prepared meals", "Still": "drinks",
             "Smelter": "metal bars", "Bowyer's Workshop": "crossbows and bolts", "Mechanic's Workshop": "mechanisms", "Craftsdwarf's Workshop": "crafts, mugs and toys",
             "Mason's Workshop": "stone furniture", "Tanner's Shop": "tanned hides", "Glass Furnace": "glass goods", "Kiln": "pottery and ash", "Siege Workshop": "ballistas and catapults",
             "Farmer's Workshop": "thread, cheese and processed plants", "Butcher's Shop": "meat, fat and bones", "Fishery": "prepared fish"}
    names = list(shops)
    for i, s in enumerate(names):
        w = [names[(i + 5) % len(names)], names[(i + 11) % len(names)]]
        opts = [s] + w; k = i % 3; opts[0], opts[k] = opts[k], opts[0]
        quiz.append({"id": f"tq-shop-{re.sub(r'\W', '', s.lower())}", "q": f"Where would a dwarf make {shops[s]}?", "options": opts, "answer": k})
        triv.append({"id": f"tt-shop-{re.sub(r'\W', '', s.lower())}", "text": f"Did you know? The {s} is where {shops[s]} are made. Ask nicely and bring materials."})
    moods = [("is taken by a fey mood!", "fey"), ("withdraws from society...", "secretive"), ("has been possessed!", "possessed"), ("begins to stalk and brood...", "macabre"), ("looses a roaring laughter, fell and terrible!", "fell")]
    kinds = [m[1] for m in moods]
    for i, (ann, k_) in enumerate(moods):
        opts = [k_, kinds[(i + 1) % 5], kinds[(i + 3) % 5]]; k = i % 3; opts[0], opts[k] = opts[k], opts[0]
        quiz.append({"id": f"tq-mood-{k_}", "q": f"A dwarf who '{ann}' is in which kind of strange mood?", "options": opts, "answer": k})
    gems = ["emerald", "ruby", "sapphire", "amethyst", "rock crystal", "black zircon", "bloodstone", "moonstone", "onyx", "jet", "carnelian", "lapis lazuli"]
    stones = ["microcline", "orthoclase", "granite", "basalt", "limestone", "dolomite", "marble", "obsidian", "gneiss", "slate", "mica", "alunite"]
    for i, g in enumerate(gems):
        opts = [g, stones[i], stones[(i + 4) % len(stones)]]; k = i % 3; opts[0], opts[k] = opts[k], opts[0]
        quiz.append({"id": f"tq-gem-{re.sub(r'\W', '', g)}", "q": "Which of these would a jeweler cut?", "options": opts, "answer": k})
        triv.append({"id": f"tt-gem-{re.sub(r'\W', '', g)}", "text": f"Did you know? {g[0].upper() + g[1:]} is a gem. Miners who strike it should tell the jeweler, and then hide it from strange moods."})
    for i, s in enumerate(stones):
        triv.append({"id": f"tt-stone-{s}", "text": f"Did you know? {s[0].upper() + s[1:]} is plain stone to a jeweler, but a mason can turn it into blocks, tables and doors."})
    facts = [
     "A masterwork is the best a dwarf can make by skill alone; only an artifact from a strange mood is finer.",
     "Every dwarf gets at most one artifact in a lifetime, and only through a strange mood.",
     "A secretive mood is just like a fey mood, except the dwarf draws pictures of what they need instead of saying it.",
     "A moody dwarf who cannot start work within a few months may go insane.",
     "Dwarves who are not buried or memorialised may return as ghosts.",
     "A dwarf drinking alcohol works faster; a dwarf without it is soon unhappy.",
     "Cats adopt dwarves, not the other way round.",
     "Strange moods only strike dwarves in forts with enough citizens.",
     "Grazing animals can feed on cave moss in an underground pasture.",
     "A slab engraved for the dead keeps their ghost at rest.",
     "Taverns, temples and libraries all fill needs a dwarf cannot fill alone.",
     "Masterworks give their makers a happy thought; losing one gives a very unhappy one.",
     "Ore must be smelted at a smelter before a smith can use the metal.",
     "Rough gems are cut at the jeweler's workshop and can then be set into other work.",
     "A caravan can only buy what is brought to the trade depot.",
     "Soldiers who train together fight better together.",
    ]
    for i, f in enumerate(facts):
        triv.append({"id": f"tt-fact-{i + 1}", "text": "Did you know? " + f})
    return quiz, triv


def main():
    out = {"tailored2_fold.json": {"notices": [], "almanac": [], "proverbs": [], "classifieds": [], "gossip": [], "weather_jokes": [], "quiz": [], "trivia": []},
           "tailored2_stories.json": {"stories": {}, "counters": {}},
           "tailored2_kinds.json": {"kinds": {}, "scenes": {}}}
    F, ST, KS = out["tailored2_fold.json"], out["tailored2_stories.json"], out["tailored2_kinds.json"]
    for c, b in COND.items():
        b = dict(b); b["fact"] = b["fact"]
        F["notices"] += gen(C_NOTICES, b, f"t2-nt-{c}", [], [c])
        F["almanac"] += gen(C_ALMANAC, b, f"t2-al-{c}", [], [c])
        F["proverbs"] += gen(C_PROVERBS, b, f"t2-pv-{c}", [], [c])
        F["gossip"] += gen(C_GOSSIP, b, f"t2-gs-{c}", [], [c])
        for i, (tag, f) in enumerate(C_CLASS):
            F["classifieds"].append({"id": f"t2-cl-{c}-{i + 1}", "tag": tag, "text": fill(f, b, i), "when": [c]})
        if c in ("rain", "snow", "clear"):
            F["weather_jokes"] += gen(["<Fact>. <Joke>.", "Weather desk: <fact>; <adv>.", "Outside, <fact>. Inside, <joke>.", "Forecast: <fact>. Advice: <adv>."], b, f"t2-wj-{c}", [], [c])
    for e in F["notices"] + F["almanac"] + F["proverbs"] + F["gossip"] + F["weather_jokes"]:
        e.pop("fit", None); e.pop("fit_auto", None)
    for k, b in STREAK.items():
        d = ST["stories"].setdefault(k, {})
        d["heads"] = [{"id": f"t2-sk-{k}-h{i + 1}", "text": fill(f, b, i)} for i, f in enumerate(SK_HEADS)]
        d["bodies"] = [{"id": f"t2-sk-{k}-b{i + 1}", "text": fill(f, b, i)} for i, f in enumerate(SK_BODIES)]
        d["ended_heads"] = [{"id": f"t2-sk-{k}-eh{i + 1}", "text": fill(f, b, i)} for i, f in enumerate(SK_EHEADS)]
        d["ended_bodies"] = [{"id": f"t2-sk-{k}-eb{i + 1}", "text": fill(f, b, i)} for i, f in enumerate(SK_EBODIES)]
    for k, ev in COUNTERS.items():
        ST["counters"][k] = [{"id": f"t2-cn-{k}-{i + 1}", "text": fill(f, {"ev": ev}, i)} for i, f in enumerate(CNT)]
    add = lambda d, k, part, items: d.setdefault(k, {}).setdefault(part, []).extend(items)
    for cause, sid in DEATH_SCENE.items():
        b = dict(DEATH[cause]); b["how_up"] = b["how"].upper()
        fit = ["die_" + cause]
        add(KS["scenes"], sid, "caps", gen(DS_CAPS, b, f"t2-ds-{cause}-c", fit))
        add(KS["scenes"], sid, "heads", gen(DS_HEADS, b, f"t2-ds-{cause}-h", fit))
        add(KS["scenes"], sid, "labels", gen(DS_LABELS, b, f"t2-ds-{cause}-l", fit))
    for mk, sid in MOOD_SCENE.items():
        b = dict(MOODS[mk]); fit = ["mood_" + mk]
        add(KS["scenes"], sid, "caps", gen(MS_CAPS, b, f"t2-ms-{mk}-c", fit))
        add(KS["scenes"], sid, "heads", gen(MS_HEADS, b, f"t2-ms-{mk}-h", fit))
    for mc, sid in STRIKE_SCENE.items():
        b = dict(MINERALS[mc]); fit = [mc]
        add(KS["scenes"], sid, "caps", gen(SS_CAPS, b, f"t2-ss-{mc}-c", fit))
        add(KS["scenes"], sid, "heads", gen(SS_HEADS, b, f"t2-ss-{mc}-h", fit))
    for bk, b in BEASTS.items():
        fit = ["beast_" + bk]
        add(KS["kinds"], "beast", "heads", gen(B_HEADS, b, f"t2-b-{bk}-h", fit))
        add(KS["kinds"], "beast", "reps", gen(B_REPS, b, f"t2-b-{bk}-r", fit))
        add(KS["kinds"], "beast", "kickers", gen(B_KICKS, b, f"t2-b-{bk}-k", fit))
        add(KS["scenes"], "beast-squad", "caps", gen(B_CAPS, b, f"t2-bs-{bk}-c", fit))
        add(KS["scenes"], "beast-squad", "heads", gen(["<UP> MEETS THE MILITIA", "SKETCH: THE <UP>"], b, f"t2-bs-{bk}-h", fit))
    q, t = quiz_and_trivia()
    F["quiz"] += q; F["trivia"] += t
    total = 0
    for fn, d in out.items():
        json.dump(d, open(os.path.join(HERE, fn), "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=1)
        c = json.dumps(d).count('"id"'); total += c; print(fn, c)
    print("total", total)


if __name__ == "__main__":
    main()
