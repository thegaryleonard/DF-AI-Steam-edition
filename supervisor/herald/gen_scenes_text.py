# -*- coding: utf-8 -*-
"""Words for the sketch artist's pre-drawn scenes (overlay.html SCENES). Writes library/scenes.json.
Each scene was drawn for one situation; these lines are written for that drawing, with slots filled from the live event:
{who} {first} the dwarf, {item} the thing made ("pig tail cloth"), {art} the artifact's name, {prof}, {shop}, {mineral}, {fort}, {pop}, {season}.
Caps and labels describe the drawing, so they only ever appear under it. Run: python herald/gen_scenes_text.py"""
import json, os

S = {}
def sc(sid, heads=(), caps=(), labels=(), says=()):
    S[sid] = {"heads": list(heads), "caps": list(caps), "labels": list(labels), "says": list(says)}

# ---------------- masterpieces: the maker with the very thing they made ----------------
sc("weaver",
   ["MASTERWORK {item} COMES OFF THE LOOM", "LOOM PRODUCES LEGEND, WEAVER PRODUCES SPEECH", "{first} WEAVES THE FINEST {item} YET", "THREAD, PATIENCE, GLORY", "WEAVING ROOM IN UPROAR OVER ONE BOLT", "THE CLOTH THAT STOPPED THE HAULERS"],
   ["{who} holds up the {item}, fresh off the loom. The artist has drawn the weave as stripes; it is much finer than stripes.", "The loom, the weaver and the cloth. Only one of the three is still humming.",
    "Our artist could not draw the pattern, so he drew {first} pointing at it, which is how {first} spent the afternoon anyway.", "The bolt of {item}, held aloft so nobody can miss it, and nobody has.",
    "The masterwork cloth on the day it was cut from the loom. The loom looks tired. It has earned it.", "A weaver and her best work. The artist was told twice not to wipe his hands on it."],
   ["THE CLOTH", "THE LOOM (TIRED)", "WARP AND WEFT", "ONE BOLT, PERFECT"],
   ["Feel it. No, gently!", "Not a single dropped thread.", "This one is not for socks.", "Weave it once, weave it right."])
sc("clothier",
   ["{first} STITCHES A MASTERWORK {item}", "FINEST {item} IN {fort}, SAYS EVERYONE WHO SAW IT", "CLOTHIER'S TRIUMPH ON THE DUMMY", "A MASTERWORK YOU CAN WEAR", "FASHION ARRIVES BENEATH THE MOUNTAIN", "NEEDLE AND THREAD WIN THE DAY"],
   ["The {item} on the dressmaker's dummy, with {first} beside it, refusing to let anyone try it on yet.", "Our artist's sketch of the masterwork {item}. The stitches are too small to draw, which is rather the point.",
    "{who} and the dummy wearing the {item}. The dummy has never looked better and knows it.", "A masterwork garment on display. Several dwarves have asked whether it comes in their size. It does not; it comes in one.",
    "The finished {item}, sparkling the way only a masterwork does in a newspaper drawing.", "Clothier and creation. The artist got the sleeves right on the fourth attempt."],
   ["THE {item}", "THE DUMMY (SMUG)", "SEAMS: PERFECT", "DO NOT TOUCH"],
   ["Every seam by hand!", "Try it on? Absolutely not.", "It fits like a promise.", "Wear it to a funeral. Or a feast."])
sc("weaponsmith",
   ["A MASTERWORK {item} LEAVES THE FORGE", "{first} FORGES A BLADE FOR THE AGES", "GOBLINS ADVISED: NEW {item} IN TOWN", "ANVIL SINGS, SMITH GRINS", "THE FORGE'S FINEST HOUR", "SHARP NEWS FROM THE SMITHY"],
   ["{who} raises the masterwork {item} beside the forge. The artist stood well back.", "The {item}, still warm, held up for the militia to admire. The militia admired it from a respectful distance.",
    "Forge, anvil and the masterwork {item}. The sparks were added by the artist for honesty's sake.", "Our sketch of the finest {item} the forge has produced. The real one is shinier and much less wobbly.",
    "A smith and a weapon, both glowing. Only the smith will cool down by supper.", "The masterwork weapon, drawn from life. The artist did not test the edge and asks that nobody else does either."],
   ["THE {item}", "THE ANVIL", "THE FORGE (HOT)", "MIND THE EDGE"],
   ["Balanced to a hair!", "Who wants to hold it? Carefully.", "The militia will love this.", "Hammered true, every blow."])
sc("armorer",
   ["MASTERWORK {item} STANDS READY", "{first} MAKES ARMOR WORTH WEARING", "THE NEW {item} TURNS ANY BLOW", "ARMORER'S BEST WORK ON DISPLAY", "PROTECTION, PERFECTED", "THE FORGE TURNS OUT A SHELL OF STEEL NERVES"],
   ["The masterwork {item} on its stand, with {first} pointing out every rivet to anyone who stops.", "Our artist sketched the {item} and then knocked on it to check. It went 'tonk', which is good.",
    "{who} beside the {item}. The stand has never held anything this fine and is standing up straighter.", "Armor on a stand, an anvil, and a very proud maker. Readers can work out which is which.",
    "The masterwork {item}. Goblins are invited to view it from the front, at speed.", "The armorer's finest, displayed where the militia can see what they are missing."],
   ["THE {item}", "PROUD ARMORER", "NO DENTS", "THE STAND"],
   ["Hit it. Go on. Not too hard.", "Not a rivet out of place.", "This one could stop a beast.", "Wear it with pride. And a helm."])
sc("furniture",
   ["MASTERWORK {item} UNVEILED", "{first} BUILDS THE FINEST {item} IN {fort}", "THIS {item} IS FIT FOR A NOBLE (DO NOT TELL THE NOBLES)", "FURNITURE OF LEGEND, SAWDUST OF NOTE", "THE {item} EVERYONE WANTS IN THEIR ROOM", "CRAFTSMANSHIP YOU CAN USE"],
   ["The masterwork {item}, with {first} waving at it in case anyone missed it. Sawdust shown for authenticity.", "Our artist's study of the {item}. Every joint is tight. The artist's lines are not.",
    "{who} and the {item}. The nobles have already asked who it is for. It is for the stockpile, as the Overseer decreed.", "A masterwork piece of furniture, sparkling, as all masterworks do in this paper.",
    "The {item}, drawn in the workshop it came from. The workshop has never been so clean, or so proud.", "The finest {item} we have seen. Our artist measured it twice and drew it once."],
   ["THE {item}", "SAWDUST", "PERFECT JOINTS", "THE MAKER (CHUFFED)"],
   ["Not one wobble!", "Who gets this one? Nobody, yet.", "Built to outlast us all.", "Mind the finish, it's still drying."])
sc("container",
   ["MASTERWORK {item} HOLDS ITS OWN", "{first}'S NEW {item}: ONE TO BE PROUD OF", "THE FINEST {item} IN THE STORES", "A VESSEL OF LEGEND (CONTENTS TBC)", "HAULERS GASP AT THE NEW {item}", "THE STOCKPILE HAS A NEW FAVOURITE"],
   ["{who} admiring the masterwork {item}. The heart was not in the original; the artist felt it was implied.", "The {item}, drawn lovingly. It holds things beautifully, which in a fort is the highest praise.",
    "A masterwork {item} and its maker. The haulers are already arguing about what goes in it first.", "Our sketch of the {item}. The artist was not allowed to put anything inside it.",
    "Maker and vessel. One of them is watertight; the other has had three ales.", "The {item} on its way to the stockpile, where it will outshine everything around it."],
   ["THE {item}", "MAKER (IN LOVE)", "EMPTY (FOR NOW)", "SEALED TIGHT"],
   ["Not a single leak.", "Fill it with something good.", "Look at those joins!", "Don't put rocks in it."])
sc("drinkware",
   ["MASTERWORK {item} RAISED IN A TOAST", "{first}'S NEW {item} IS WORTHY OF ALE", "TAVERN DEMANDS THE NEW {item}", "DRINKING VESSEL OF LEGEND", "THIS {item} IS TOO GOOD TO DRINK FROM (WE DRANK FROM IT)", "CHEERS ECHO OVER ONE CUP"],
   ["{who} toasting with the masterwork {item}. It was empty; the artist was told it was full.", "The {item}, held high over the tavern table. A friend looks on and is already thirsty.",
    "A maker and a masterwork {item}. The sparkles are artistic; the ale stains are real.", "Our sketch of the {item}. It holds exactly one drink, which is one more than our artist was offered.",
    "The masterwork {item} in its natural home, held aloft over a table.", "The finest {item} in {fort}. Every dwarf who saw it went to look for a drink."],
   ["THE {item}", "THIRSTY FRIEND", "THE TABLE", "FULL (PROBABLY)"],
   ["To the finest cup in the fort!", "Fill it up!", "First drink is mine.", "It even holds the foam right."])
sc("jeweler",
   ["A MASTERWORK {item} SPARKLES", "{first}'S {item} COULD DAZZLE A KING", "JEWELLERY OF LEGEND LEAVES THE BENCH", "THE {item} THAT OUTSHINES THE LAMPS", "FINE WORK, FINER SPARKLE", "NOBLES ALREADY JEALOUS OF ONE {item}"],
   ["{who} holds up the masterwork {item}. The sparkles are real, the artist insists, and so is the squinting.", "The {item}, raised so the light catches it. The light has never been so flattered.",
    "Our artist's sketch of the masterwork {item}. Real jewels are smaller and much harder to draw.", "Jeweler and jewel. The workbench behind them has seen a great deal of swearing over small stones.",
    "The {item} in all its glory, drawn twice the real size so readers can see it at all.", "A masterwork piece of jewellery and a very satisfied maker."],
   ["THE {item}", "SPARKLE (REAL)", "THE BENCH", "ALL HANDMADE"],
   ["Look how it catches the light!", "Not for any noble. Yet.", "Fits like it was born there.", "Every facet, by hand."])
sc("trinket",
   ["A MASTERWORK {item}, TINY AND PERFECT", "{first} MAKES A SMALL THING VERY WELL", "THE LITTLE {item} EVERYONE IS TALKING ABOUT", "SMALL CRAFT, BIG PRIDE", "CRAFTSDWARF PERFECTS THE {item}", "A MASTERPIECE YOU CAN HOLD IN ONE HAND"],
   ["{who} peering at the masterwork {item} through a glass. A friend peers at {first} peering.", "The {item} on the bench, drawn much bigger than life so readers can see why it matters.",
    "Our sketch of the little {item}. Every tiny line is there in the real thing; only some are here.", "Craftsdwarf, lens and {item}. The lens is borrowed; the skill is not.",
    "The masterwork {item}, admired from both ends of the bench.", "A small thing done perfectly, with two dwarves leaning in to prove it."],
   ["THE {item}", "MAGNIFYING GLASS", "THE BENCH", "VERY SMALL, VERY GOOD"],
   ["Look closer. Closer.", "Every tiny detail!", "Small, but it's a masterwork.", "Don't sneeze near it."])
sc("sculptor",
   ["A MASTERWORK {item} RISES IN THE HALL", "{first} CARVES A LIKENESS FOR THE AGES", "STONE COMES ALIVE UNDER ONE CHISEL", "THE {item} THAT MADE THE FORT STOP AND STARE", "SCULPTOR'S TRIUMPH", "CHIPS FLY, LEGEND STANDS"],
   ["The masterwork {item} on its plinth, with {who} and the chisel that did it. The chips are still on the floor.", "Our artist drew the {item}; the {item} is better. That is the nature of statues.",
    "Sculptor and sculpture. Only one of them has been standing still all day.", "The {item}, arms raised in triumph, which is also how the sculptor stood when it was done.",
    "A masterwork statue, drawn from the front. The back is just as good, we are told.", "The finished {item}, with the stone dust still settling around {first}."],
   ["THE {item}", "STONE CHIPS", "THE CHISEL", "THE PLINTH"],
   ["It was in the stone all along.", "Don't climb on it.", "One more chip... no. Done.", "It looks better than the original."])
sc("musician",
   ["A MASTERWORK {item} SINGS", "{first} MAKES AN INSTRUMENT THAT PLAYS ITSELF (NEARLY)", "THE TAVERN HAS A NEW SOUND", "MUSIC FROM A MASTER'S HANDS", "ONE {item}, ONE STANDING OVATION", "DANCING BREAKS OUT OVER NEW INSTRUMENT"],
   ["{who} tries out the masterwork {item} while two listeners decide whether to dance. One decided yes.", "The {item}, being played. The notes are drawn as notes; the real ones were better.",
    "Our sketch of the masterwork {item} in use. The artist hummed along and was asked to stop.", "A maker, the {item} and an audience, which in {fort} counts as a concert.",
    "The masterwork {item}, with music coming out of it in the traditional newspaper manner.", "Player and instrument, in perfect tune for once."],
   ["THE {item}", "MUSIC (LOUD)", "DANCER", "AUDIENCE"],
   ["Listen to that!", "One more tune!", "It's never out of tune.", "Dance, you lot!"])
sc("gemcutter",
   ["A MASTERWORK GEM CUT AT LAST", "{first} CUTS A STONE THAT CUTS THE DARK", "{item}: FLAWLESS, SAYS THE LENS", "THE BENCH, THE LENS, THE PERFECT GEM", "A JEWEL FOR THE AGES", "GEM CUTTER'S HAND NEVER WAVERED"],
   ["{who} studies the masterwork {item} through a lens. The gem is drawn at five times its real size.", "The {item} on the jeweler's bench, every facet perfect. The artist drew six of them; there are more.",
    "Gem and gem cutter. The cutter has not blinked since breakfast.", "Our sketch of the {item}. It sparkles in the drawing because it sparkled in life.",
    "The masterwork cut gem, sitting on the bench like it owns the workshop. It may.", "A lens, a bench and a gem worth a whole caravan."],
   ["THE GEM", "THE LENS", "FACETS (MANY)", "THE BENCH"],
   ["Not one flaw.", "Look at it catch the light!", "Cut true, every face.", "Careful. That's worth a wagon."])
sc("cook",
   ["MASTERWORK {item} SERVED", "{first} COOKS A MEAL FOR THE AGES", "THE KITCHEN'S FINEST HOUR", "DINING HALL STUNNED BY ONE DISH", "A MASTERPIECE YOU CAN EAT (QUICKLY)", "CHEF'S TRIUMPH, STILL STEAMING"],
   ["{who} presents the masterwork {item}, still steaming. A diner at the table has already picked up a spoon.", "Our sketch of the {item}. It smelled better than this drawing looks, and this drawing looks good.",
    "The chef, the dish and the first hungry customer. The dish will not last the afternoon.", "A masterwork meal held high. The artist ate the model afterwards and has no regrets.",
    "The {item}, steaming, carried in triumph from the kitchen. Masterwork food is rare; eating it is rarer.", "Cook and creation. Only one of them will be eaten tonight."],
   ["THE DISH", "STEAM (DELICIOUS)", "HUNGRY DINER", "CHEF'S HAT"],
   ["Eat it while it's hot!", "Seasoned to perfection.", "Don't let the cat near it.", "Seconds? There are no seconds."])
sc("brewer",
   ["THE STILL PRODUCES A MASTERWORK BREW", "{first} BREWS A LEGEND", "A BARREL WORTH GUARDING", "THE TAVERN'S NEW PRIDE", "ONE SIP AND THE FORT FELL SILENT", "BREWER'S TRIUMPH"],
   ["The barrel of masterwork brew, with {first} holding the first mug drawn from it.", "Our artist drew the barrel. The brew itself could not be drawn; it could only be enjoyed.",
    "Brewer, barrel and mug. The mug is already half empty.", "The finest barrel in {fort}, with the brewer standing guard.",
    "A masterwork brew, sealed in its barrel. The haulers have been told to walk, not run.", "The tap, the barrel and the brewer who will never be thirsty again."],
   ["THE BREW", "THE MUG", "THE TAP", "DO NOT SHAKE"],
   ["Smell that!", "First mug's mine.", "Aged to perfection.", "Hands off till dinner."])
sc("scribe",
   ["A MASTERWORK {item} IS WRITTEN", "{first} PENS A BOOK FOR THE AGES", "LIBRARY ACQUIRES A LEGEND", "THE {item} EVERYONE WANTS TO BORROW", "INK, PATIENCE AND GENIUS", "SCRIBE'S TRIUMPH HELD ALOFT"],
   ["{who} holds up the masterwork {item}. The pages are drawn as lines; the real ones are full of very small words.", "The {item}, raised high above the writing desk where it was made.",
    "Our sketch of the masterwork {item}. Nobody would let the artist read it first.", "Scribe and book. Both are a little smudged with ink.",
    "The finished {item}, the desk and a very pleased author.", "A masterwork book. The library has already made room for it, which meant moving a cat."],
   ["THE {item}", "THE DESK", "INK (EVERYWHERE)", "THE PAGES"],
   ["Every word in its place.", "Read it! Carefully.", "Bound and finished.", "The library gets it first."])
sc("mechanic",
   ["MASTERWORK {item} CLICKS INTO PLACE", "{first} BUILDS A CONTRAPTION OF GENIUS", "THE FINEST {item} IN THE WORKS", "GEARS, GENIUS, GLORY", "A MASTERWORK THAT ACTUALLY WORKS", "ENGINEERS APPLAUD ONE {item}"],
   ["The masterwork {item}, with {who} holding the tool that finished it. The artist drew the gears turning; they were.", "Our sketch of the {item}. It is more complicated than this; the artist ran out of lines.",
    "Maker and contraption. Only the contraption knows exactly how it works.", "The masterwork {item} on the floor of the workshop, ready for duty.",
    "A {item} made perfectly. The engineers have asked to borrow it; the maker said no.", "The finished piece, all its teeth and joints in perfect order."],
   ["THE {item}", "THE TOOL", "MOVING PARTS", "DO NOT POKE"],
   ["Listen to it click!", "Not a loose part.", "It works first time!", "Built to last a century."])
sc("fletcher",
   ["MASTERWORK {item} FLY TRUE", "{first} MAKES AMMUNITION OF LEGEND", "THE TARGET NEVER STOOD A CHANCE", "STRAIGHT, SHARP AND MASTERWORK", "MARKSDWARVES QUEUE FOR THE NEW {item}", "A VOLLEY WORTH WAITING FOR"],
   ["A bundle of masterwork {item}, and the target that met the first one. Dead centre.", "Our sketch of the {item}. Each one is straighter than the artist's lines.",
    "The bundle and the bullseye. The marksdwarves have asked to keep the target as a souvenir.", "Masterwork {item}, ready for the next goblin who wants to test them.",
    "The {item} in their bundle, one already in the target to prove the point.", "A quiverful of perfect shots, waiting for the militia."],
   ["THE {item}", "THE TARGET", "DEAD CENTRE", "THE BUNDLE"],
   [])
sc("engraver",
   ["A MASTERWORK ENGRAVING ON THE WALL", "{first} CARVES A PICTURE INTO THE ROCK", "THE WALL THAT TELLS A STORY", "ENGRAVER'S TRIUMPH, SET IN STONE", "FORT GATHERS TO READ ONE WALL", "ART YOU CANNOT STEAL"],
   ["{who} stands back from the masterwork engraving. The wall now shows a dwarf, raising their arms, which is how {first} stood when it was done.", "The engraved wall, with the chisel still in hand. The stone has never looked so interesting.",
    "Our artist drew the engraving; the engraving is better. It was carved into the rock itself.", "A wall, a picture in the wall, and the dwarf who put it there.",
    "The masterwork engraving. Passers-by stop, look, and walk into each other.", "The finished engraving, with a little dwarf on the wall looking very pleased about it."],
   ["THE ENGRAVING", "THE WALL", "THE CHISEL", "SET IN STONE"],
   ["Read the wall!", "It'll be here in a thousand years.", "Every line carved by hand.", "Don't lean on it."])
sc("tanner",
   ["MASTERWORK LEATHER STRETCHED AND READY", "{first} TANS A HIDE TO REMEMBER", "THE FINEST {item} ON THE FRAME", "LEATHERWORK OF LEGEND", "TANNERY TRIUMPH", "A HIDE WITHOUT A FLAW"],
   ["The {item} on its frame, with {who} celebrating. The smell, mercifully, could not be drawn.", "Our sketch of the masterwork {item}. Soft, even and ready for a leatherworker.",
    "Frame, hide and tanner. The tanner is the one with arms up.", "The {item}, stretched tight and perfect. Bags, belts and boots await.",
    "A masterwork hide. The artist kept his distance for reasons of smell.", "The finished leather, on display where the leatherworkers can admire it."],
   ["THE HIDE", "THE FRAME", "SMELL (NOT SHOWN)", "PERFECTLY EVEN"],
   [])
sc("smelter",
   ["MASTERWORK METAL FROM THE FURNACE", "{first} POURS A PERFECT BAR", "FURNACE TURNS OUT GOLDEN WORK", "THE SMELTER'S PROUDEST DAY", "BARS OF LEGEND STACKED", "PURE METAL, PURE PRIDE"],
   ["The {item}, stacked by the furnace, with {who} celebrating. The smiths are already eyeing them.", "Our sketch of the bars. They are heavier than they look and look very heavy.",
    "Furnace, bars and smelter. The furnace is still hot; so is the smelter's temper about being drawn.", "A stack of masterwork metal, the start of something great.",
    "The bars beside the furnace that made them.", "The finished bars, gleaming, waiting for a smith worthy of them."],
   ["THE BARS", "THE FURNACE", "STILL HOT", "THE STACK"],
   [])
sc("unveiling",
   ["A MASTERPIECE, UNDER WRAPS FOR NOW", "{first} MAKES SOMETHING WONDERFUL", "THE FORT WAITS FOR THE GREAT REVEAL", "MASTERWORK ANNOUNCED, DETAILS TO FOLLOW", "WHAT IS UNDER THE SHEET?", "SKILL MEETS ITS PEAK"],
   ["The masterpiece under a sheet, with {who} refusing to lift it until a crowd gathers.", "Our artist was not allowed a look, so he drew the sheet. It is a very good sheet.",
    "A masterwork, wrapped for the unveiling. The question mark is the artist's.", "{first} and a mystery masterpiece. Guesses at the tavern range from 'something small' to 'something big'.",
    "The covered masterwork. Whatever it is, it is the finest of its kind in {fort}.", "The great reveal, about to happen. Our artist had to leave for deadline."],
   ["UNDER WRAPS", "THE MAKER", "?", "DO NOT PEEK"],
   ["No peeking!", "Gather round, everyone!", "Wait for it...", "You'll love it. Probably."])

# ---------------- artifacts: the same workshops, plus a crowd and the name on a plaque ----------------
ART = {
 "art-weaver": (["LEGENDARY CLOTH: {art}", "A WEAVER'S MOOD ENDS IN LEGEND", "{art}, A CLOTH WITHOUT EQUAL", "THE LOOM GIVES BIRTH TO AN ARTIFACT"],
   ["{art}, the legendary {item}, held up beside the loom while the fort crowds in to look.", "The loom where {art} was woven. The crowd at the edges have been there since dawn.", "{who} with {art}, the {item} that will be spoken of after we are all gone.", "The artifact cloth and its maker, with the name engraved on the plaque below by a very nervous engraver."],
   ["{art}", "THE LOOM", "THE CROWD"]),
 "art-clothier": (["A GARMENT OF LEGEND: {art}", "{art}: THE {item} NOBODY MAY WEAR", "MOOD ENDS IN A LEGENDARY {item}", "FASHION'S GREATEST DAY"],
   ["{art}, the legendary {item}, on the dummy where everyone can see it and nobody can borrow it.", "The crowd admiring {art}. One dwarf asked if it came in blue and was escorted out.", "{who} beside {art}. The stitches are said to be too fine for any eye.", "The artifact garment on display, its name on a plaque because nobody can pronounce it twice."],
   ["{art}", "THE DUMMY", "ADMIRERS"]),
 "art-weaponsmith": (["A LEGENDARY {item}: {art}", "{art} IS FORGED", "THE FORGE GIVES THE FORT A LEGEND", "GOBLINS, TAKE NOTE: {art}"],
   ["{art}, the legendary {item}, raised by {who} beside the forge while the fort looks on.", "The forge, the anvil and {art}. The crowd keeps a very respectful distance from the sharp end.", "The legendary weapon {art}. The militia captain has already asked for it. The answer was no.", "Our sketch of {art}. Weapons with names tend to make history; this one is just getting started."],
   ["{art}", "THE FORGE", "THE CROWD (AWED)"]),
 "art-armorer": (["LEGENDARY ARMOR: {art}", "{art}, THE {item} OF LEGEND", "MOOD PRODUCES IMPENETRABLE MASTERPIECE", "A LEGEND STANDS ON ITS STAND"],
   ["{art}, the legendary {item}, on its stand while the fort gathers.", "The artifact armor {art}. The crowd knocks on it, quietly, for luck.", "{who} beside {art}, the finest {item} ever made in {fort}.", "Our artist drew {art} with great care and still could not get the shine right."],
   ["{art}", "THE STAND", "ONLOOKERS"]),
 "art-furniture": (["A LEGENDARY {item}: {art}", "{art} JOINS THE FORT", "THE LAST WORD IN FURNITURE: {art}", "MOOD ENDS, FURNITURE BECOMES LEGEND"],
   ["{art}, the legendary {item}, with its maker and a crowd who all want to sit on it. Nobody may.", "The crowd around {art}. It has a name, a plaque and a guard.", "{who} beside {art}, the {item} that will outlast the fort.", "The artifact furniture {art}, sketched while the crowd held its breath."],
   ["{art}", "THE CROWD", "DO NOT SIT"]),
 "art-container": (["A LEGENDARY {item}: {art}", "{art}, THE VESSEL OF LEGEND", "MOOD PRODUCES AN ARTIFACT {item}", "THE STORES HAVE A TREASURE"],
   ["{art}, the legendary {item}, with its maker and the crowd that followed it out of the workshop.", "The artifact {item} {art}. Whatever goes in it will feel very honoured.", "{who} with {art}. The haulers have been told to carry it with both hands, always.", "Our sketch of {art}, with a crowd for scale."],
   ["{art}", "ADMIRERS", "HANDLE WITH CARE"]),
 "art-drinkware": (["A LEGENDARY {item}: {art}", "{art}, THE CUP OF LEGEND", "A TOAST TO {art}", "MOOD ENDS IN THE FINEST {item} EVER MADE"],
   ["{art}, the legendary {item}, raised in a toast while the crowd raises theirs.", "The artifact {item} {art}. Drinking from it is forbidden; looking at it is encouraged.", "{who} with {art}. Every mug in the tavern looks a little worse today.", "Our sketch of {art}, held high over the table."],
   ["{art}", "THE TABLE", "THIRSTY CROWD"]),
 "art-jeweler": (["A LEGENDARY {item}: {art}", "{art} DAZZLES {fort}", "JEWEL OF LEGEND LEAVES THE BENCH", "THE NOBLES WILL WANT {art}. THEY CANNOT HAVE IT."],
   ["{art}, the legendary {item}, held up to the light while the crowd shields its eyes.", "The artifact {item} {art}. The sparkles are underdrawn, if anything.", "{who} with {art}. Its name is on the plaque; its shine is everywhere.", "Our sketch of {art}. The real one made the artist sit down for a while."],
   ["{art}", "SPARKLE", "THE CROWD"]),
 "art-trinket": (["A LEGENDARY {item}: {art}", "{art}: SMALL, PERFECT, LEGENDARY", "TINY ARTIFACT, HUGE CROWD", "MOOD ENDS IN A LITTLE MIRACLE"],
   ["{art}, the legendary {item}, on the bench, with half the fort leaning in to see it.", "The artifact {item} {art}, drawn bigger than life so readers can see it at all.", "{who} beside {art}. The lens has been passed around eleven times.", "Our sketch of {art}. Its name is longer than it is."],
   ["{art}", "THE LENS", "LEANING CROWD"]),
 "art-sculptor": (["A LEGENDARY {item}: {art}", "{art} STANDS IN {fort}", "STONE BECOMES LEGEND", "THE STATUE THAT WILL OUTLIVE US"],
   ["{art}, the legendary {item}, on its plinth while the crowd stares up at it.", "The artifact statue {art}, with stone dust still on its maker's beard.", "{who} beside {art}. The likeness is said to be uncanny.", "Our sketch of {art}. The real one looks back at you."],
   ["{art}", "THE PLINTH", "THE CROWD"]),
 "art-musician": (["A LEGENDARY {item}: {art}", "{art} PLAYS FOR {fort}", "THE INSTRUMENT OF LEGEND", "MOOD ENDS IN MUSIC"],
   ["{art}, the legendary {item}, played for the first time while the crowd dances.", "The artifact {item} {art}. Its first tune brought the whole hall in.", "{who} plays {art}. The notes are drawn; the tears are not.", "Our sketch of {art} in use, the crowd swaying at the edges."],
   ["{art}", "THE MUSIC", "DANCERS"]),
 "art-gemcutter": (["A LEGENDARY GEM: {art}", "{art}, THE STONE OF LEGEND", "THE GEM THAT LIGHTS THE HALL", "MOOD ENDS IN PERFECTION"],
   ["{art}, the legendary {item}, on the bench while the crowd queues for a look through the lens.", "The artifact gem {art}. Merchants have already started making offers. All refused.", "{who} studies {art} one last time before the crowd gets it.", "Our sketch of {art}, glowing on the bench."],
   ["{art}", "THE LENS", "QUEUE"]),
 "art-cook": (["A LEGENDARY {item}: {art}", "{art} SERVED (NOT EATEN)", "THE MEAL OF LEGEND", "A DISH WITH A NAME"],
   ["{art}, the legendary {item}, carried out of the kitchen to gasps.", "The artifact dish {art}. Nobody dares eat it; everybody wants to.", "{who} presents {art} to a crowd that has forgotten its own dinner.", "Our sketch of {art}, still steaming."],
   ["{art}", "STEAM", "HUNGRY CROWD"]),
 "art-brewer": (["A LEGENDARY BREW: {art}", "{art} IS BREWED", "THE BARREL OF LEGEND", "MOOD ENDS IN THE TAVERN"],
   ["{art}, the legendary brew, in its barrel, with a crowd that has brought its own mugs.", "The artifact barrel {art}. It is not to be tapped. Several dwarves are weeping.", "{who} beside {art}.", "Our sketch of {art} and an extremely interested crowd."],
   ["{art}", "THE BARREL", "MUGS AT READY"]),
 "art-scribe": (["A LEGENDARY {item}: {art}", "{art} IS WRITTEN", "THE BOOK OF LEGEND", "MOOD ENDS IN A MASTERPIECE OF WORDS"],
   ["{art}, the legendary {item}, held aloft while the crowd tries to read it from below.", "The artifact book {art}. The library has cleared a whole shelf.", "{who} with {art}. Every page is said to be perfect.", "Our sketch of {art}. Reading it is by appointment only."],
   ["{art}", "THE DESK", "READERS"]),
 "art-mechanic": (["A LEGENDARY {item}: {art}", "{art} TURNS AND CLICKS", "THE MACHINE OF LEGEND", "MOOD ENDS IN A MARVEL"],
   ["{art}, the legendary {item}, ticking quietly while the crowd watches it work.", "The artifact {item} {art}. The engineers want to take it apart; they may not.", "{who} beside {art}.", "Our sketch of {art}. The gears move in real life; please imagine it."],
   ["{art}", "GEARS", "THE CROWD"]),
 "art-fletcher": (["LEGENDARY {item}: {art}", "{art}: AMMUNITION OF LEGEND", "THE TARGET NEVER RECOVERED", "MOOD ENDS IN A PERFECT VOLLEY"],
   ["{art}, the legendary {item}, beside the target it ruined.", "The artifact {item} {art}, with a crowd of marksdwarves taking notes.", "Our sketch of {art}. Do not stand downrange.", "The bundle and the bullseye, with the name on a plaque."],
   ["{art}", "THE TARGET", "MARKSDWARVES"]),
 "art-engraver": (["A LEGENDARY ENGRAVING", "THE WALL OF LEGEND", "MOOD ENDS ON THE WALL", "ART SET IN STONE FOREVER"],
   ["The legendary engraving, with its maker and a crowd reading the wall.", "Our sketch of the artifact engraving. The original cannot be moved, which is a comfort.", "{who} stands back from the finished wall while the crowd looks on.", "The wall that became a legend, with the name on a plaque beneath."],
   ["THE WALL", "THE CROWD", "THE PICTURE"]),
 "art-tanner": (["A LEGENDARY {item}: {art}", "{art}, THE HIDE OF LEGEND", "MOOD ENDS AT THE TANNERY", "LEATHER BECOMES LEGEND"],
   ["{art}, the legendary {item}, stretched on its frame while the crowd holds its nose and its breath.", "The artifact hide {art}.", "{who} with {art}.", "Our sketch of {art}. The smell is not included."],
   ["{art}", "THE FRAME", "THE CROWD"]),
 "art-smelter": (["LEGENDARY METAL: {art}", "{art} POURED", "THE FURNACE'S LEGEND", "MOOD ENDS IN METAL"],
   ["{art}, the legendary {item}, beside the furnace while the crowd keeps back from the heat.", "The artifact metal {art}.", "{who} with {art}.", "Our sketch of {art}, still warm."],
   ["{art}", "THE FURNACE", "THE CROWD"]),
 "art-unveiling": (["A LEGEND IS BORN: {art}", "{art}: THE {item} OF LEGEND", "THE MOOD IS OVER; THE LEGEND BEGINS", "{fort} HAS AN ARTIFACT"],
   ["{art}, still under its sheet, with a crowd that has been waiting all day for the reveal.", "The artifact {art} before its unveiling. Its maker would not let our artist peek.", "{who} beside {art}. The crowd is on tiptoe.", "Our sketch of {art}, under wraps. The plaque is already engraved."],
   ["{art}", "UNDER WRAPS", "THE CROWD"]),
}
for sid, (h, c, l) in ART.items():
    sc(sid, h, c, l, ["Behold!", "It has a name now!", "Make way!", "Look what {first} made!"])

# ---------------- strange moods, by kind of mood ----------------
sc("mood-fey", ["{first} TAKEN BY A FEY MOOD", "FEY DWARF SEIZES A WORKSHOP", "INSPIRATION STRIKES {fort}", "A FEY LOOK AND A CLAIMED WORKSHOP", "THE MUSE HAS COME FOR {first}", "{prof} STRUCK BY A STRANGE INSPIRATION"],
   ["{who}, taken by a fey mood, points at the workshop as if it were the only one in the world.", "A fey dwarf and the workshop they have chosen. The sparkles are around {first}'s eyes; the artist saw them.", "The fey look, as sketched from a safe distance. The workshop was claimed within the hour.", "Our artist's study of a fey mood: arms up, eyes wide, mind elsewhere."],
   ["THE WORKSHOP", "FEY LOOK", "MINE NOW"], ["I know exactly what to make!", "Bring me materials!", "It's all so clear!", "Nobody touch my workshop!"])
sc("mood-secretive", ["{first} WITHDRAWS FROM SOCIETY", "SECRETIVE MOOD: DWARF DRAWS PICTURES", "WHAT IS {first} SKETCHING?", "A MOOD DRAWN ON THE WALL", "{prof} VANISHES INTO A SECRET PROJECT", "SKETCHES ON THE WALL, NOBODY KNOWS WHY"],
   ["{who}, withdrawn and secretive, has drawn what they need on the wall instead of saying it. Our artist copied the copies.", "The wall of sketches: a bone, a skull, a gem and a question mark. Haulers are trying to work it out.", "A secretive mood, explained through pictures. The pictures are not very helpful.", "{first} at the wall, adding another sketch. The bookkeeper is taking notes."],
   ["THE SKETCHES", "?", "A HINT, MAYBE"], [])
sc("mood-possessed", ["{first} POSSESSED!", "UNKNOWN FORCES SEIZE A DWARF", "POSSESSION IN {fort}: KEEP CALM", "{prof} TAKEN BY SOMETHING ELSE", "A STRANGE VOICE IN THE HALLS", "THE SPIRIT MOVES {first}"],
   ["{who}, possessed, hovering just above the floor. The artist swears it was real; the artist was also sober.", "A swirl of unknown forces over a possessed dwarf. The workshop in the corner is next.", "Our artist's impression of possession: arms up, feet barely touching, eyes elsewhere.", "{first}, possessed, drifting towards a workshop. Everyone else drifted the other way."],
   ["UNKNOWN FORCES", "FEET (BARELY TOUCHING)", "THE WORKSHOP"], [])
sc("mood-macabre", ["{first} BEGINS TO STALK AND BROOD", "MACABRE MOOD GRIPS {fort}", "A BROODING DWARF AND A PILE OF BONES", "{prof} SEEKS DARK MATERIALS", "BONES WANTED. NO QUESTIONS.", "A DARK INSPIRATION"],
   ["{who}, brooding among bones and a skull. Nobody has asked what for, and nobody will.", "The macabre mood, drawn gently. The bones are animal bones, we are told, and we are choosing to believe it.", "A brooding dwarf, a dark sky and the materials of a very particular project.", "Our artist kept the drawing small and left early."],
   ["MATERIALS", "THE SKULL", "BROODING"], ["Bring me bones.", "It must be... darker.", "Leave me.", "Not those bones. Better bones."])
sc("mood-fell", ["{first} LOOSES A FELL AND TERRIBLE LAUGH", "FELL MOOD! LOCK YOUR DOORS", "A TERRIBLE LAUGHTER IN THE HALLS", "{prof} IN THE GRIP OF A FELL MOOD", "THUNDER, LAUGHTER, TROUBLE", "THE FORT HOLDS ITS BREATH"],
   ["{who}, laughing a fell and terrible laugh while lightning does something it should not do underground.", "A fell mood, sketched from behind a door. The artist recommends everyone else stay behind one too.", "The laughter echoed through the halls; our artist wrote it down as HA, which does not do it justice.", "A dwarf in a fell mood. The fort is advised to keep its distance and its wits."],
   ["FELL MOOD", "HA", "THE DOOR (SHUT)"], [])
sc("mood-claim", ["WORKSHOP CLAIMED BY A MOODY DWARF", "{first} CLAIMS A WORKSHOP", "KEEP OUT, SAYS THE NEW SIGN", "A MOOD MOVES INTO THE {shop}", "THE {shop} IS SPOKEN FOR", "SOMETHING IS BEING MADE IN THERE"],
   ["{who} outside the claimed workshop. The sign went up first; the explanation never did.", "The {shop}, claimed for a strange mood. Its regular workers are drinking elsewhere, looking wistful.", "A moody dwarf and a workshop with a KEEP OUT sign. The artist kept out.", "The claimed workshop. Haulers are told to leave materials at the door and walk away quickly."],
   ["THE WORKSHOP", "KEEP OUT", "THE {shop}"], ["Mine. All mine.", "Nobody comes in.", "Bring what I ask for!", "I'll know it when I see it."])

# ---------------- deaths, by cause ----------------
DEATH = {
 "death-funeral": (["{fort} MOURNS {first}", "FAREWELL TO A {prof}", "THE HALLS FALL QUIET", "A COFFIN FOR {first}", "REST WELL, {first}", "ONE FEWER AT THE TABLE"],
   ["Mourners at the coffin of {who}. The artist drew the tears as lines; there were more of them.", "A coffin and two friends. Our artist kept this one simple, out of respect.", "The fort says goodbye to {first}. A slab will follow.", "Friends of the late {prof} gather. The tavern will be quiet tonight."], ["R.I.P.", "MOURNER", "THE COFFIN"]),
 "death-thirst": (["{first} DIES OF THIRST", "A DRY DEATH IN {fort}", "THIRST CLAIMS A {prof}", "TOO FAR FROM THE DRINK", "THE BARRELS WERE RIGHT THERE", "DEHYDRATED, AND MISSED"],
   ["Barrels, a well and a slab. The artist leaves readers to draw the sad conclusion.", "The drinks and the well, a short walk from where {first} was found. Please drink something today.", "A memorial beside the barrels. Nobody in {fort} should die thirsty.", "Our sketch of what was close by. It was never far enough to excuse."], ["DRINKS (UNDRUNK)", "THE WELL", "SO CLOSE"]),
 "death-hunger": (["{first} STARVES", "HUNGER CLAIMS A {prof}", "AN EMPTY PLATE AND A SLAB", "{fort} LOSES ONE TO HUNGER", "NOBODY SHOULD STARVE BELOW THE MOUNTAIN", "THE KITCHEN GOES QUIET"],
   ["An empty plate on the table and a slab beside it. The artist drew it plainly.", "The dining table where {first} should have eaten. The kitchen has been asked to cook more.", "A memorial for a hungry dwarf. Every stockpile in {fort} has been checked twice since.", "An empty plate. That is the whole drawing, and it is enough."], ["EMPTY PLATE", "THE TABLE", "MEMORIAL"]),
 "death-battle": (["{first} STRUCK DOWN", "A {prof} FALLS IN BATTLE", "{fort} LOSES A FIGHTER", "HONOUR TO THE FALLEN", "THE SHIELD LIES STILL", "FELL WITH THEIR BOOTS ON"],
   ["A slab, a shield and an axe. {first} went down fighting, and the fort will remember it.", "The fallen dwarf's gear, laid by the memorial. A friend stands watch.", "Our artist's tribute to {who}, struck down. The axe was theirs.", "Shield, axe and slab. The militia saluted as they passed."], ["FELL WITH HONOUR", "THE SHIELD", "THE AXE"]),
 "death-drowning": (["{first} DROWNS", "THE WATER TAKES A {prof}", "A DROWNING IN {fort}", "DEEP WATER, SAD DAY", "{fort} MOURNS A DROWNED DWARF", "WATER, WATER, NOWHERE SAFE"],
   ["The water where {first} went under. A few bubbles, then nothing. The slab stands on dry ground.", "Our sketch of the water. Dwarves are not swimmers, and this one was no exception.", "The waves, drawn as the artist remembers them, and a slab on the bank.", "Where the water took {who}. Engineers have been asked to look at the channel."], ["THE WATER", "BUBBLES", "THE BANK"]),
 "death-vampire": (["{first} FOUND DRAINED OF BLOOD", "VAMPIRE IN {fort}?", "A BLOODLESS DEATH, A WORRIED FORT", "SOMETHING BITES IN THE NIGHT", "WHO DRAINED {first}?", "LOCK YOUR DOORS AT NIGHT"],
   ["A coffin, a moon and bats. Our artist got carried away, but the sheriff is not laughing.", "{who} was found drained of blood. Somebody in {fort} does not sleep at night.", "The coffin of {first}. The question of who is still open.", "Our artist's impression of the culprit. The artist has started sleeping with a candle lit."], ["NOT GARLIC", "THE COFFIN", "BATS"]),
 "death-collapse": (["{first} CRUSHED", "THE CEILING COMES DOWN", "A {prof} BURIED BY STONE", "ROCKFALL CLAIMS A LIFE", "MIND THE CEILING", "{fort} COUNTS THE COST OF A CAVE-IN"],
   ["Falling rock and a slab. Our artist drew the rocks loosely, out of respect for the engineers.", "Where the ceiling came down on {who}. The miners have been asked to check their supports.", "A rockfall, drawn from memory, and a memorial beside it.", "The stones that fell. The fort mourns, and looks up nervously."], ["THE CEILING", "ROCKS", "THE SLAB"]),
 "death-fire": (["{first} LOST TO THE FLAMES", "FIRE CLAIMS A {prof}", "A BURNING DAY IN {fort}", "TOO CLOSE TO THE HEAT", "SMOKE AND SORROW", "THE FIRE TAKES ONE OF US"],
   ["Flames, a slab and a mourner. Our artist used orange sparingly.", "Where the fire took {who}. The fort has been reminded where the water is kept.", "A fire, drawn small, and a memorial drawn large.", "The flames that took {first}, and the friend who saw it."], ["TOO HOT", "THE FLAMES", "MOURNER"]),
 "death-fall": (["{first} FALLS", "A LONG DROP CLAIMS A {prof}", "DEATH BY HEIGHT", "MIND THE EDGE", "{fort} MOURNS A FALL", "THE GROUND CAME UP TOO FAST"],
   ["A long way down, and a slab at the bottom. Our artist drew the drop with three quick lines.", "Where {who} fell. Railings have been requested.", "The height, the fall and the memorial, from top to bottom.", "A sad sketch of a short trip. Watch your step, {fort}."], ["A LONG WAY DOWN", "THE EDGE", "THE SLAB"]),
 "death-age": (["{first} DIES OF OLD AGE", "A LONG LIFE ENDS", "THE OLDEST BEARD RESTS", "{fort} SAYS GOODBYE TO AN ELDER", "A GOOD LONG RUN", "AN EMPTY CHAIR BY THE FIRE"],
   ["The old chair, empty now, and a slab with a star. {first} had a long life, and earned every year of it.", "The elder's favourite seat. Nobody will sit in it for a while.", "A long life, a quiet end, and a fort that remembers.", "Our artist's tribute to {who}: a chair, a star and a stone."], ["THE OLD CHAIR", "A STAR", "THE SLAB"]),
 "death-sick": (["{first} SUCCUMBS", "SICKNESS CLAIMS A {prof}", "A HARD DEATH IN THE HOSPITAL", "THE SICKBED STANDS EMPTY", "{fort} LOSES A PATIENT", "THE DOCTORS COULD NOT SAVE {first}"],
   ["The sickbed, a crutch and a slab. The doctors tried.", "Where {who} spent their last days. The hospital has gone quiet.", "An empty bed and a memorial. Our artist drew it gently.", "The sickbed of {first}. Wash your hands, {fort}."], ["THE SICKBED", "THE CRUTCH", "THE SLAB"]),
}
for sid, (h, c, l) in DEATH.items(): sc(sid, h, c, l, [])

# ---------------- pets ----------------
sc("pet-grave", ["A BELOVED ANIMAL IS GONE", "{fort} MOURNS A PET", "A SMALL GRAVE IN THE HALLS", "GOODBYE, OLD FRIEND", "THE BOWL SITS EMPTY", "ONE FEWER PAW IN THE FORT"],
   ["A small grave, an empty bowl and a sad owner. Our artist drew the animal as it was: happy.", "The animal, as remembered, beside its little memorial.", "An empty bowl. The owner keeps filling it anyway.", "Our sketch of a good animal and the stone that marks it."],
   ["GOOD ANIMAL", "EMPTY BOWL", "THE OWNER (SAD)"], [])
sc("pet-butcher", ["THE BUTCHER'S SHOP REPORTS", "STRAY BECOMES SUPPER", "THE KITCHEN THANKS THE BUTCHER", "MEAT ON THE MENU", "A STRAY'S LAST JOB", "BUTCHER BUSY, LARDER FULL"],
   ["The butcher's table, freshly stocked. The artist chose not to draw the details.", "The butcher and the evening's sausages. Dinner is served, and nobody is asking which stray.", "A cleaver, a table and a fuller larder. That is the fort for you.", "Our sketch of the butcher's shop. Vegetarians are advised to turn the page."],
   ["SUPPER", "THE CLEAVER", "SAUSAGES"], [])

# ---------------- strikes and discoveries ----------------
STRIKE = {
 "strike-gem": (["MINERS STRIKE {mineral}!", "GEMS IN THE WALL", "{fort} HITS A POCKET OF {mineral}", "SPARKLE IN THE DARK", "A GEM STRIKE!", "THE ROCK WAS HIDING JEWELS"],
   ["A miner, a pick and {mineral} glittering in the rock. The jeweler has been told and is already sharpening tools.", "The gem in the wall, drawn bigger than it is. Gems in this paper always are.", "Our sketch of the find: one swing, one sparkle, one very happy miner.", "{mineral}, as it looked in the lamplight. The jewelers want first look."], ["GEM", "THE PICK", "SPARKLE"], ["Gems!", "Look at that shine!", "Fetch the jeweler!", "Strike the earth!"]),
 "strike-ore": (["MINERS STRIKE {mineral}!", "A VEIN OF {mineral} FOUND", "ORE FOR THE FORGES", "{fort} STRIKES METAL", "THE SMELTERS WILL BE BUSY", "A RICH VEIN BELOW"],
   ["The vein of {mineral} running through the rock, and the first cart waiting to carry it off.", "A miner, a vein and an ore cart. The smelters have been warned.", "Our sketch of the {mineral} vein. It runs further than the artist could draw.", "The find, in streaks across the wall. The forges are already warming up."], ["ORE", "THE VEIN", "THE CART"], ["Ore! Fetch the cart!", "Look at that vein!", "The smiths will love this.", "Strike the earth!"]),
 "strike-coal": (["MINERS STRIKE {mineral}!", "FUEL FOUND BELOW", "COAL FOR THE FURNACES", "{fort} WILL BE WARM", "BLACK GOLD IN THE WALL", "THE FORGES CHEER"],
   ["Lumps of {mineral} in the rock, and a little flame to show what it is for.", "A miner and a seam of {mineral}. The smelters have stopped worrying about wood.", "Our sketch of the find: black, lumpy and very useful.", "The {mineral} seam, drawn in the darkest ink we had."], ["FUEL", "THE SEAM", "WARMTH"], ["Fuel for years!", "Burn, baby, burn.", "The furnaces are saved!", "Strike the earth!"]),
 "strike-stone": (["MINERS STRIKE {mineral}", "A USEFUL ROCK IS FOUND", "{mineral} IN THE WALLS", "STONE OF NOTE", "THE MASONS NOD APPROVINGLY", "ROCK, BUT A GOOD ONE"],
   ["A miner and a great round lump of {mineral}. Useful rock, the experts say, which is a dwarf's highest praise for a rock.", "Our sketch of the {mineral}. It is a rock. It is a good rock.", "The find, sketched honestly: big, round and grey.", "A miner beside a fine boulder of {mineral}. The masons have already put in an order."], ["ROCK (GOOD)", "THE BOULDER", "THE MINER"], ["Good rock!", "That'll do nicely.", "Fetch the masons.", "Strike the earth!"]),
 "strike-cavern": (["A CAVERN OPENS BELOW {fort}", "THE DEEP IS FOUND", "MUSHROOM FORESTS IN THE DARK", "MINERS BREAK INTO A CAVERN", "A WHOLE NEW WORLD, VERY DAMP", "WHAT LIVES DOWN THERE?"],
   ["A miner looking into the dark of a new cavern, where mushrooms grow taller than trees.", "The cavern, drawn as a dark square with mushrooms. It is bigger than that.", "Our sketch of the opening. The question mark belongs to the miner.", "The edge of the deep, and a dwarf deciding whether to step in."], ["THE DEEP", "MUSHROOMS", "?"], ["Is that a tree?", "Hello? ...hello?", "It goes on forever.", "We should wall this up."]),
 "strike-magma": (["MAGMA FOUND BELOW", "THE HOT ROCK IS HERE", "{fort} DIGS INTO FIRE", "MAGMA! EVERYONE STEP BACK", "A GLOWING DISCOVERY", "THE FORGES DREAM OF MAGMA"],
   ["A pool of magma glowing at the bottom of the dig, and a miner stepping smartly back.", "Our sketch of the magma. The artist used all the orange and borrowed a red.", "The heat, the glow and a very quick retreat.", "Where the rock turns to fire. Engineers are already drawing plans."], ["MAGMA (HOT)", "THE GLOW", "RETREAT"], ["Hot! Hot!", "Back! Back!", "Magma forges, here we come!", "Nobody fall in."]),
 "strike-other": (["MINERS FIND SOMETHING", "A DISCOVERY BELOW", "THE ROCK GIVES UP A PRIZE", "STRIKE THE EARTH!", "NEWS FROM THE MINES", "A LUCKY SWING"],
   ["A miner and the find. The artist was not told what it was and drew a gem, to be safe.", "Our sketch of the discovery, as described by an excited miner.", "One swing, one discovery.", "The miner, the pick and the mystery."], ["THE FIND", "THE PICK", "THE MINER"], []),
}
for sid, (h, c, l, y) in STRIKE.items(): sc(sid, h, c, l, y)

# ---------------- the other kinds keep their classic drawings ----------------
sc("k-siege", ["ENEMIES AT THE GATES", "SIEGE! TO THE WALLS", "{fort} UNDER ATTACK", "SPEARS AT THE DOOR", "THE MILITIA IS CALLED", "WAR COMES TO {fort}"],
   ["The enemy at the walls, spears up, and one defender on the battlements with an axe.", "Our artist's view of the siege, from a safe spot behind the wall.", "Three attackers and one wall. The wall is winning, so far.", "The siege, drawn quickly and from a distance."], ["THE ENEMY", "THE WALL", "ONE DEFENDER"], [])
sc("k-beast", ["A MONSTER COMES TO {fort}", "BEAST SIGHTED!", "TEETH, CLAWS, TROUBLE", "THE BIG ONE HAS ARRIVED", "RUN, SAYS EVERYONE", "A CREATURE OF TERRIBLE SIZE"],
   ["The beast, all teeth, and one dwarf making the sensible choice.", "Our artist's impression of the creature, drawn while running.", "A very large monster and a very small dwarf. The scale is accurate.", "The beast, from the artist's hiding place."], ["VERY BIG", "TEETH", "RUNNING DWARF"], [])
sc("k-berserk", ["TANTRUM IN THE HALLS", "A DWARF LOSES THEIR TEMPER", "FURNITURE IN DANGER", "BAD DAY GETS WORSE", "{fort} BRACES FOR A TANTRUM", "MUGS FLY"],
   ["A furious dwarf, a flying mug and a barrel that has seen better days.", "Our artist's sketch of the outburst. Language has been replaced with symbols.", "The incident, from a safe distance.", "Steam, shouting and one unlucky barrel."], ["!!!", "THE MUG", "THE BARREL"], [])
sc("k-migrants", ["MIGRANTS ARRIVE IN {fort}", "NEW FACES AT THE GATE", "THE WAGON IS FULL OF BEARDS", "{fort} GROWS", "MORE DWARVES, MORE BEDS NEEDED", "WELCOME, NEWCOMERS"],
   ["The new arrivals, beards first, on a wagon that has seen a long road.", "Our sketch of the migrants. All beards, no luggage.", "A wagon full of hope and a dwarf waving them in.", "The newcomers, as they rolled through the gate."], ["MORE OF THEM", "THE WAGON", "WELCOME"], [])
sc("k-caravan", ["CARAVAN ARRIVES", "TRADERS AT THE DEPOT", "WARES AND HAGGLING", "THE MERCHANTS ARE HERE", "TRADE WINDS BLOW INTO {fort}", "HIDE THE GOOD MUGS"],
   ["The merchants' wagon and a stack of barrels for trade.", "Our sketch of the caravan. Prices could not be drawn.", "Wares, wagons and the start of a very long haggle.", "The traders' wagon, parked at the depot."], ["WARES", "THE WAGON", "BARRELS"], [])
sc("k-birth", ["A CHILD IS BORN IN {fort}", "WELCOME, LITTLE ONE", "A NEW BEARD (EVENTUALLY)", "{fort} GROWS BY ONE", "THE CRADLE IS FULL", "BIRTH ANNOUNCEMENT"],
   ["A proud parent and a brand new baby. The beard, we are told, will come.", "Our sketch of the newest citizen. Very small, very loud.", "Parent and child, on the first day.", "The baby, drawn at slightly larger than actual size."], ["ALREADY BEARDED", "THE BABY", "PROUD PARENT"], [])
sc("k-marriage", ["WEDDING BELLS BENEATH THE MOUNTAIN", "TWO HEARTS, ONE FORT", "{fort} CELEBRATES A MARRIAGE", "LOVE IN THE HALLS", "A WEDDING!", "MARRIED AT LAST"],
   ["The happy couple, with a heart over them, as is traditional in newspaper drawings.", "Two dwarves, one heart. Our artist was not invited and drew this from the doorway.", "The couple on the big day.", "A marriage in {fort}, sketched with great affection."], ["THE COUPLE", "LOVE", "THE BIG DAY"], [])
sc("k-ghost", ["GHOST IN THE HALLS", "THE DEAD WALK IN {fort}", "BOO, SAYS THE GHOST", "A RESTLESS SPIRIT", "HAUNTING REPORTED", "BURY YOUR DEAD"],
   ["The ghost, drawn by a witness with their eyes mostly closed.", "A spirit and a fleeing dwarf. A slab would settle it.", "Our artist's impression of the haunting.", "The apparition, as it drifted through the hall."], ["BOO", "THE GHOST", "FLEEING DWARF"], [])
sc("k-collapse", ["CAVE-IN!", "THE CEILING FALLS", "ROCKS RAIN IN {fort}", "MIND YOUR HEADS", "A COLLAPSE BELOW", "STONES FALL, DWARVES SCATTER"],
   ["Falling rocks and a dwarf with arms up, which does not help.", "Our sketch of the collapse, reconstructed using rocks.", "The ceiling, now on the floor.", "A cave-in, seen from underneath."], ["OOF", "ROCKS", "THE CEILING"], [])
sc("k-soldier", ["A SOLDIER ACHIEVES MASTERY", "{fort} HAS A NEW CHAMPION", "MASTER OF ARMS", "THE MILITIA GAINS A LEGEND", "TRAINING PAYS OFF", "GOBLINS, BEWARE"],
   ["A master of arms, axe raised, sparkling with skill.", "Our sketch of the champion. The sparkles are earned.", "Years of training, one proud pose.", "The new master, ready for anything."], ["CHAMPION", "THE AXE", "SKILL"], [])
sc("k-pet", [], [], [], [])

out = {"scenes": {}}
n = 0
for sid, parts in S.items():
    d = {}
    for part, lst in parts.items():
        if not lst: continue
        d[part] = [{"id": f"sc-{sid}-{part[0]}{i + 1}", "text": t} for i, t in enumerate(lst)]
        n += len(lst)
    if d: out["scenes"][sid] = d
HERE = os.path.dirname(os.path.abspath(__file__))
json.dump(out, open(os.path.join(HERE, "library", "scenes.json"), "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=1)
print(len(out["scenes"]), "scenes,", n, "entries")
