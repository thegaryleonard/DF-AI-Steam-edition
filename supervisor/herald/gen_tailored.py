# -*- coding: utf-8 -*-
"""Category-tailored Herald content: headlines, reports, kickers, notices, gossip and follow-ups written once as frames
and filled per item category / death cause / mood / mineral from tailored_banks.py. Every entry carries a fit tag
(fit_auto: false, so tag_library.py keeps it) and only prints for a matching event. Writes library/tailored_*.json.
Run from supervisor/: python herald/gen_tailored.py   (then tag_library.py, validate_library.py, node herald/test_fit.js)"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tailored_banks import CAT, DEATH, MOODS, SHOPS, MINERALS, METALS

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")


def pickv(v, i):
    return v[i % len(v)] if isinstance(v, list) else v


def fill(frame, bank, i):
    """<key> -> bank value (rotating through lists by i); <KEY> -> the same value in capitals"""
    def sub(m):
        k = m.group(1)
        if k.lower() not in bank and k.lower().endswith("_up"):
            return pickv(bank[k.lower()[:-3]], i + len(k)).upper()
        v = pickv(bank[k.lower()], i + len(k))
        if k.isupper() and len(k) > 1 or k == "M": return v.upper()
        return v[0].upper() + v[1:] if k[0].isupper() else v
    out = re.sub(r"<(\w+)>", sub, frame)
    out = re.sub(r"\b([Aa]) (?=[AEIOUaeiou])(?![Uu](?:ni|s)|[Oo]ne)", lambda m: m.group(1) + ("N " if m.group(1) == "A" and re.sub(r"\{\w+\}", "", out).isupper() else "n "), out)
    # a live slot may start with a vowel ("a {prof}" -> "a animal trainer"), so use "the" before any slot
    out = re.sub(r"\b(a|A|an|An|AN) (?=\{)", lambda m: "THE " if re.sub(r"\{\w+\}", "", out).isupper() else ("The " if m.group(1)[0] == "A" else "the "), out)
    return out[0].upper() + out[1:] if out and out[0].islower() and not out.startswith("{") else out


def gen(frames, bank, prefix, fit, when=None, extra=None):
    out = []
    for i, f in enumerate(frames):
        e = {"id": f"{prefix}-{i + 1}", "text": fill(f, bank, i), "fit": fit, "fit_auto": False}
        if when: e["when"] = when
        if extra: e.update(extra)
        out.append(e)
    return out


# ---------------- masterpieces, per item category ----------------
M_HEADS = ["<MAKER> TURNS OUT A MASTERWORK", "MASTERWORK FROM <SHOP>", "{first} SETS A NEW STANDARD FOR <MAKERS>", "<VERB> TO PERFECTION",
  "THE FINEST <THING> IN {fort}", "<SHOP> CELEBRATES", "A MASTERWORK, AND <FAN> KNOW IT", "{first}: <PRAISE>, AND PROUD OF IT",
  "MASTERWORK {item} STUNS <FAN>", "ONE {item}, ZERO FLAWS", "<MAKERS> SALUTE {first}", "SKILL MEETS ITS PEAK AT <SHOP>",
  "A {item} FOR THE RECORDS", "{fort}'S BEST {item} YET", "<PRAISE> AND MASTERWORK: THE NEW {item}", "<MAKER>'S PRIDE: ONE MASTERWORK {item}",
  "QUALITY ARRIVES AT <SHOP>", "<FAN> QUEUE TO SEE THE NEW {item}", "THE {item} EVERYONE IS TALKING ABOUT", "FROM <SHOP>, WITH PRIDE"]
M_REPS = ["{who} has finished a masterwork {item}. <Fan> came to look, stayed to admire, and left talking about nothing else.",
  "The {item} came out of <shop> <praise> in every respect. {first} says the secret is the <tool>, and patience, and more patience.",
  "Fellow <makers> were seen examining the {item} closely, looking for a flaw. They found none and went back to work in a thoughtful mood.",
  "The masterwork {item} will be <use>. <Fan> have already asked to be first in line.",
  "{first}, a <maker> of some standing, has now made a masterwork {item}. The standing has improved considerably.",
  "Experts at <shop> rate the {item} '<praise>', the highest word they have for it, and have asked {first} to explain how. {first} declined.",
  "The only worry about the new {item}, say those who saw it, is <risk>. Precautions are being taken.",
  "A masterwork {item} is the best a dwarf can make by skill alone. {first} has made one, and the whole of <shop> is quietly delighted.",
  "The {item} was <verb> with the care that only a master's hands bring. <Fan> are said to be envious, and are not hiding it well.",
  "Asked what made this {item} special, {first} pointed at it and said 'look at it.' The Herald looked. It is very good.",
  "<Shop> has never turned out a finer {item}. The workshop has been tidied in its honour, which has never happened before either.",
  "{who} would like it known that the masterwork {item} took skill, years of practice and one good night's sleep, in roughly that order.",
  "The {item} is headed for <place>, where it will be the finest thing in sight for some time to come.",
  "<Fan> have offered {first} drinks in exchange for a closer look at the {item}. {first} has accepted every offer.",
  "A craft is judged by its best work, and today <shop> was judged very well indeed. The {item} is <praise>.",
  "If the {item} has a fault, it is that it makes every other one in {fort} look ordinary. {first} is not sorry.",
  "The bookkeeper has valued the masterwork {item} and then gone back to check the figure. The figure was correct.",
  "Witnesses say {first} held up the finished {item}, said nothing, and smiled for an hour. That is a dwarven speech of great length.",
  "The {item} is <praise>. {first} would like that printed in large letters. Here it is: <PRAISE>.",
  "Even the Overseer stopped to look at the {item}, and the Overseer stops for nothing.",
  "{first} has made plenty of ordinary pieces at <shop>. This {item} is not one of them.",
  "The whole of <shop> downed tools for a moment to look at the {item}. Then they picked them up again, inspired.",
  "Rumour says {first} talked to the {item} while finishing it. {first} says it talked back. Either way, it came out <praise>.",
  "Visitors to <place> are asked to admire the {item} with their eyes, not their hands.",
  "The masterwork {item} is proof that <makers> in {fort} can match the best anywhere. {first} is proof of who.",
  "The Herald's critic examined the {item} and wrote one word in the margin: '<praise>.' That is a rave review.",
  "<Fan> have started a waiting list for the next piece like it. {first} has started pretending not to hear.",
  "The {item} took the usual materials, an unusual amount of care and one very good day. The result is a masterwork.",
  "Asked about the {item}, the <maker>'s apprentice said only 'I helped.' The apprentice tidied up afterwards. It was, in fairness, very well tidied.",
  "A masterwork {item} raises the value of everything around it. <Place> has never been worth so much."]
M_KICKS = ["<Fan> may view the {item} at <place>.", "{first} accepts compliments at <shop>, all day.", "The {item} is not for sale. Yet.",
  "Next commission: whatever {first} likes.", "Handle the {item} with care. And clean hands.", "<Makers> across {fort} are practising harder tonight.",
  "The <tool> used is being retired with honours.", "{first} has been granted a long lunch.", "A happy maker makes happy work. Feed {first}.",
  "Masterworks are rare. Enjoy this one.", "Applause may be directed to <shop>.", "{first} is available for compliments.", "The {item} has been logged by the bookkeeper. Twice.",
  "<Fan>, please form an orderly queue.", "The next masterwork is already being planned.", "Feed the <maker>. Masterworks follow."]

# ---------------- artifacts, per item category ----------------
A_HEADS = ["A LEGENDARY {item}: {art}", "{art} IS MADE", "MOOD ENDS IN A LEGEND FROM <SHOP>", "{first} EMERGES WITH {art}",
  "<FAN> STUNNED BY {art}", "{fort} HAS A NEW TREASURE", "THE {item} CALLED {art}", "LEGEND ARRIVES: A {item} LIKE NO OTHER",
  "{art}: <PRAISE> BEYOND WORDS", "<MAKERS> SALUTE {art}", "A NAME FOR THE AGES: {art}", "THE MOOD IS OVER; {art} BEGINS"]
A_REPS = ["{who} has emerged from a strange mood with {art}, a {item} of legend. <Fan> crowded in to see it and had to be gently moved along.",
  "{art} is a {item} <verb> in a single burst of inspiration. It is <praise>, and nobody in {fort} will ever make another like it.",
  "The legendary {item} {art} will be kept at <place>. Guards have been asked to stand near it and try not to stare.",
  "Artifacts come from strange moods and cannot be made on purpose. {first} could not explain {art}, and nobody asked them to try.",
  "<Fan> have already asked to borrow {art}. The answer, delivered kindly, was no.",
  "{art}, the new {item}, is valued at more than most of the fort's stockpiles put together. The bookkeeper sat down after writing the number.",
  "Those who saw {first} at work say the {item} took shape as if it already knew what it wanted to be. It wanted to be {art}.",
  "The fort's only concern about {art} is <risk>. Plans are in hand.",
  "{art} is the finest {item} ever made in {fort}, and the first to have a name of its own. It will not be the last thing remembered about {first}.",
  "A legendary {item} brings a happy thought to its maker and a long line of visitors to its door. {art} has both.",
  "Scholars will write about {art}. Merchants will dream about it. {first} would like a drink and a long sleep.",
  "Every <maker> in {fort} came to see {art}. Several went quietly back to their benches to try harder.",
  "{art} is not for trade, not for loan and not to be <use> without asking. It is to be admired, and it is being admired.",
  "The legend begins: {art}, a {item}, <verb> by {who}. The Herald will keep a close eye on its adventures.",
  "{art} is <praise>, the visitors agree. They have agreed loudly, often and in the corridor.",
  "{first} slept for a whole day after finishing {art}. Nobody blamed them, and <fan> tiptoed past the door.",
  "The workshop where {art} was made has become a place of pilgrimage. <Shop> is not sure how it feels about this.",
  "{art} has been entered in the fort's records as its finest {item}. The bookkeeper underlined it.",
  "What makes {art} legendary? Ask <fan>; they will tell you at length. Ask {first}; they will just smile."]
A_KICKS = ["{art} may be viewed at <place>. Look, don't touch.", "{first} is resting. Please let them.", "Artifacts cannot be traded. Do not ask the merchants.",
  "Guards are posted. Thieves, take note.", "The name {art} is spelled the way it is spelled.", "<Makers> are inspired. Expect better work all round.",
  "A legend needs a good home. {art} has one.", "Visiting hours: whenever {first} is not looking."]

# ---------------- Sketch-artist scenes: extra words for each drawing (by the category it shows) ----------------
SC_CAPS = ["{who} shows off the masterwork {item} at <shop>. The artist drew it twice, then gave up and drew it once, properly.",
  "Our artist's sketch of the {item}, <praise>, and its maker, <praise_b>.", "The {item} and the <maker> who made it, both looking pleased with the day's work.",
  "The masterwork {item}, held up so the whole of <shop> can see. Everyone did.", "The finished {item}, sketched quickly before <fan> carried {first} off to celebrate.",
  "{first} with the masterwork {item}. The <tool> is just out of frame, resting after a hard day.", "A <maker> and a masterwork. Our artist notes that only one of them sat still for the drawing.",
  "The {item}, drawn from life. In life it is <praise>; in ink it is our best effort.", "The scene at <shop>: the {item}, its maker, and a great deal of pride.",
  "The masterwork {item} on its way to <place>. Our artist ran alongside with a pencil.",
  "{first} at <shop>, holding up the {item} for our artist. Our artist asked for one more minute. {first} gave thirty seconds.",
  "The {item}, the maker and the workshop. All three looked very pleased about it.", "A quick sketch of the masterwork {item} before <fan> arrived to admire it.",
  "Our artist's impression of the {item}. The real one is more <praise> and less smudged.", "{who} and the {item}, as seen by our sketch artist on a busy day at <shop>.",
  "The {item} is held up proudly. Behind it, <shop> looks on in approval."]
SC_HEADS = ["SKETCH: THE MASTERWORK {item}", "{first} AND THE {item}, DRAWN FROM LIFE", "AT <SHOP>, A MASTERWORK", "OUR ARTIST VISITS <SHOP>", "THE {item}, AS SEEN BY OUR ARTIST", "A <MAKER>'S FINEST HOUR"]
SC_SAYS = ["<Praise>, if I say so myself.", "Mind the {item}!", "Took me all day!", "Best work I've done.", "Fetch <fan>!", "Look at that!", "Not bad, eh?", "My finest!", "Don't touch, just look."]
SC_LABELS = ["THE {item}", "<MAKER>", "<PRAISE>", "MASTERWORK"]
SCENE_OF = {"cloth": "weaver", "clothing": "clothier", "weapon": "weaponsmith", "armor": "armorer", "furniture": "furniture", "container": "container",
  "drinkware": "drinkware", "jewelry": "jeweler", "figurine": "trinket", "toy": "trinket", "crafts": "trinket", "statue": "sculptor", "instrument": "musician",
  "gem": "gemcutter", "food": "cook", "book": "scribe", "tool": "mechanic", "ammo": "fletcher", "engraving": "engraver", "leather": "tanner", "metal": "smelter"}
ART_CAPS = ["{art}, the legendary {item}, with {who} and a crowd that will not go home.", "The crowd at <shop>, come to see {art}. Our artist stood on a crate for this view.",
  "{art}, sketched in a hurry before <fan> crowded in. It is <praise>; the sketch is merely good.", "The maker of {art}, the crowd, and the plaque that makes it official.",
  "{first} with {art}, a {item} that will outlast us all. The crowd agrees.", "{art} on display at last. The queue is longer than the drawing.",
  "The unveiling of {art}. Our artist was elbowed twice and drew it anyway.", "{art}, the legendary {item}, and the dwarves who could not stop staring at it."]

# ---------------- fold pieces about the last masterwork/artifact, per category ----------------
N_NOTICES = ["The masterwork {masterwork} by {masterwright} is now at <place>. <Fan> are asked to admire it quietly.",
  "<Makers> are reminded that {masterwright}'s {masterwork} is not a challenge. It is a little bit of a challenge.",
  "Please do not ask {masterwright} how the {masterwork} was <verb>. The answer takes an hour.",
  "Lost: the <tool> that made the masterwork {masterwork}. Return to <shop>; {masterwright} is inconsolable.",
  "Viewing of the {masterwork} by {masterwright} is free. Comments must be kind.",
  "Congratulations to {masterwright} on the masterwork {masterwork}. <Shop> is buying the first round."]
N_GOSSIP = ["Word at <shop> is that {masterwright} has been humming since the {masterwork} was finished. Nobody minds. Yet.",
  "Our sources say <fan> have already argued twice over who gets the {masterwork}. {masterwright} has kept out of it, wisely.",
  "A rival <maker> was overheard saying the {masterwork} is 'all right, I suppose.' The rival has not slept since.",
  "{masterwright} was spotted visiting the {masterwork} at <place>, 'just to check on it.' Three times.",
  "Since the {masterwork} was finished, every <maker> in {fort} has asked {masterwright} for advice. The advice is 'practise.'"]
N_TRIVIA = ["Did you know? A masterwork like {masterwright}'s {masterwork} is the highest quality a dwarf can reach by skill alone; only a strange mood goes further.",
  "Did you know? A masterwork such as the {masterwork} gives its maker a happy thought, and its loss would give them a very unhappy one.",
  "Did you know? The {masterwork} by {masterwright} was <verb> at <shop>, the same place that turns out most of {fort}'s <thing_s>."]
AF_NOTICES = ["{artifact_new}, the legendary {artifact_new_item}, is at <place>. Viewing by appointment with {artifact_maker}.",
  "Do not touch {artifact_new}. Do not breathe on {artifact_new}. Do not ask to borrow {artifact_new}.",
  "<Fan> are reminded that {artifact_new} is an artifact and cannot be traded, whatever the merchants say.",
  "Thanks to everyone who brought materials to {artifact_maker} during the mood. The {artifact_new_item} {artifact_new} is the result."]
AF_GOSSIP = ["Overheard at <shop>: '{artifact_maker} hasn't stopped smiling since {artifact_new}.' Nobody has seen {artifact_maker} stop smiling, so this is probably true.",
  "<Fan> have formed a queue outside <place> to see {artifact_new}. The queue has its own gossip now.",
  "Our sources say {artifact_maker} still visits {artifact_new} every morning, to say hello."]
FO_MAST_H = ["THE {masterwork_last}, A WEEK ON", "{masterwright_last}'S {masterwork_last} STILL DRAWS A CROWD", "AFTER THE MASTERWORK: <SHOP> GETS BACK TO WORK", "<FAN> CAN'T STOP TALKING ABOUT THE {masterwork_last}"]
FO_MAST_B = ["The masterwork {masterwork_last} made by {masterwright_last} is still the talk of <shop>. <Fan> visit it at <place> and come away inspired.",
  "Days after the masterwork {masterwork_last}, {masterwright_last} has gone back to ordinary work. The ordinary work is noticeably better.",
  "The {masterwork_last} has settled in at <place>. <Fan> report it is still <praise>, which is the point of a masterwork.",
  "{masterwright_last} has been asked to teach the other <makers> how the {masterwork_last} was <verb>. The class is full."]
FO_ART_H = ["{artifact_new}, ONE WEEK LATER", "LIFE WITH A LEGEND: {artifact_new}", "{artifact_maker} AND {artifact_new}: AN UPDATE", "THE QUEUE FOR {artifact_new} GROWS"]
FO_ART_B = ["A week after the mood, {artifact_new}, the legendary {artifact_new_item}, is still drawing visitors to <place>. {artifact_maker} has recovered.",
  "{artifact_new} has settled into {fort} life. <Fan> visit daily; the guards have learned their names.",
  "{artifact_maker} has gone back to ordinary work after making {artifact_new}. Ordinary work, they say, is restful.",
  "The legendary {artifact_new_item} {artifact_new} remains <praise>. Merchants have made offers; all have been politely refused."]

# ---------------- deaths, per cause ----------------
D_HEADS = ["{first} <HOW_UP>", "{fort} MOURNS A DWARF WHO <HOW_UP>", "<SHORT> CLAIMS {first}", "A {prof} LOST TO <SHORT>", "<SHORT>: THE FORT GRIEVES",
  "FAREWELL, {first}", "{fort} ASKS: COULD IT HAVE BEEN PREVENTED?", "A SAD DAY: <SHORT>", "{first} IS GONE", "REMEMBERING {first}"]
D_REPS = ["{who} <how> <scene>. The fort is quiet tonight, and the Herald asks every reader to <lesson>.",
  "Friends of {first} gathered at the coffin. All agreed {first} deserved better than to have <how> <scene>.",
  "The death of {who} has the fort talking about <worry>. The answer, say the elders, is <remedy>.",
  "{first}, a {prof}, <how>. A slab has been ordered so that {first} rests easy and stays that way.",
  "Officials have listed the cause as <sign>. The Herald lists it as a loss. {first} will be missed.",
  "The bookkeeper has crossed one more name from the roll. {first} <how>, and the ink ran a little.",
  "Elders remind {fort} to <lesson>. They said it gently, and then they said it again.",
  "{who}'s friends say the fort must look hard at <worry>. A meeting has been called. Ale will be served.",
  "No dwarf should die like this. {first} <how> <scene>. The fort will do better: <remedy>, starting now.",
  "{first} is survived by friends, workmates and a half-finished job that somebody will finish in their honour.",
  "The Herald will print a full obituary for {first}, a {prof}, when the grief allows. For now: they <how>, and they are mourned."]
D_KICKS = ["Please <lesson>.", "Funeral details to follow.", "Bury your dead, {fort}.", "A slab is on order.", "The fort will remember {first}.", "Look after one another this week.",
  "Condolences may be left at the slab.", "Next week: <remedy>."]
D_OBITS = ["{deadname}, {prof}, has {cause}. A steady worker and a good friend, they will be missed at the long table. The fort promises <remedy>.",
  "We remember {deadname}, a {prof} who has {cause}. Friends ask that every reader <lesson>.",
  "{deadname} has {cause}. A {prof} with a laugh you could hear across the dining hall, they leave a quieter fort behind.",
  "{deadname}, the {prof}, has {cause}. Their friends will raise a mug tonight, and talk about <worry>.",
  "Farewell to {deadname}, {prof}, who has {cause}. Rest well. We will do better."]
D_FO_H = ["A WEEK AFTER {lastdead}", "{fort} STILL MOURNS {lastdead}", "AFTER {lastdead}: WHAT WE LEARNED", "THE SLAB FOR {lastdead}"]
D_FO_B = ["{lastdead} {lastdead_cause_h} {lastdead_ago}. Since then the fort has been talking about <worry>, and work has begun on <remedy>.",
  "Friends still leave small things at the slab of {lastdead}, the {lastdead_prof}. The elders still ask everyone to <lesson>.",
  "The death of {lastdead} changed things. <Remedy> is being arranged, so that no other dwarf meets the same end.",
  "{lastdead}, the {lastdead_prof}, is buried and remembered. The fort is a little more careful than it was."]

# ---------------- moods ----------------
MO_HEADS = ["{first} GRIPPED BY A <UP> MOOD", "A <UP> MOOD DESCENDS ON {fort}", "{prof} IN A <UP> MOOD", "THE FORT WATCHES A <UP> MOOD", "<UP>! {first} WILL MAKE SOMETHING", "WHAT WILL THE <UP> DWARF MAKE?"]
MO_REPS = ["{who} has been taken by a <word> mood, with <look>. Friends report {first} <act>, and then went very quiet.",
  "A <word> mood is a rare thing. {first} has <look> and the whole fort is curious, and a little nervous.",
  "Witnesses say {first} <act>. That is how a <word> mood begins. Nobody knows how it will end, except with an artifact or not at all.",
  "The Herald advises readers to give the <word> {first} room, materials and, above all, patience.",
  "{who} looks up only to ask for things, with <look>: the mark of a <word> mood, say the elders."]
MO_KICKS = ["Bring what is asked for. Ask nothing.", "The Herald will report when the door opens.", "Leave {first} be.", "A <word> mood waits for no one."]
SH_HEADS = ["MOOD CLAIMS THE {shop}", "{first} TAKES OVER THE {shop}", "THE {shop} IS SPOKEN FOR", "SOMETHING STIRS IN THE {shop}"]
SH_REPS = ["{who} has claimed the {shop}. Haulers expect calls for <needs> before long, and are already looking.",
  "The {shop} belongs to a strange mood now. Those who know say it means <made>, and that <needs> should be kept within reach.",
  "With the {shop} claimed, its usual workers are drinking elsewhere. The fort's stockpiles of <needs> are being counted."]
SH_KICKS = ["Keep <needs> handy.", "The {shop} is closed to visitors.", "Expect <made>."]

# ---------------- strikes ----------------
ST_HEADS = ["MINERS STRIKE {mineral}", "<UP> IN THE WALLS: {mineral}", "{mineral}! <FAN> CHEER", "A VEIN OF {mineral}", "THE ROCK GIVES UP {mineral}", "STRIKE THE EARTH: {mineral}"]
ST_REPS = ["Miners have struck {mineral}. <Fan> were the first to hear and the first to cheer: it will be <use>.",
  "A vein of {mineral} has been opened. The <feel> of it caught a miner's lamp, and the cheer was heard three levels up.",
  "{mineral} has been found below {fort}. <Fan> have asked for every last piece; the miners have asked for a drink first.",
  "The bookkeeper has added {mineral} to the ledger of good news. It will be <use>, and <fan> are already planning.",
  "News from the mines: {mineral}, and plenty of it. The <feel> in the lamplight was, a miner says, 'a lovely sight.'"]
ST_KICKS = ["<Fan> are on their way.", "Mind the new tunnel.", "More digging tomorrow.", "Strike the earth!"]
MET_HEADS = ["<M> IN THE ORE!", "A VEIN OF <M>", "MINERS FIND <M>", "<M> FOR THE FORGES"]
MET_REPS = ["The new vein of {mineral} carries <m>. The smiths have stopped work to celebrate, which is, they say, part of the work.",
  "{mineral} means <m>, and <m> means the forges will be busy. The smelters are stoking the fires already."]


def main():
    files = {"tailored_kinds.json": {"kinds": {}}, "tailored_scenes.json": {"scenes": {}}, "tailored_fold.json": {"notices": [], "gossip": [], "trivia": [], "obits": [], "followon": {}}}
    K, SCN, F = files["tailored_kinds.json"]["kinds"], files["tailored_scenes.json"]["scenes"], files["tailored_fold.json"]
    add = lambda d, k, part, items: d.setdefault(k, {}).setdefault(part, []).extend(items)
    for cat, b in CAT.items():
        b = dict(b); b.setdefault("praise_b", b["praise"][1:] + b["praise"][:1]); b["thing_s"] = [t + "s" if not t.endswith("s") else t for t in b["thing"]]
        fit = [cat] + (["mat_metal"] if cat in ("weapon",) else [])   # swords are forged; a wooden training axe gets the generic lines
        add(K, "master", "heads", gen(M_HEADS, b, f"tg-m-{cat}-h", fit))
        add(K, "master", "reps", gen(M_REPS, b, f"tg-m-{cat}-r", fit))
        add(K, "master", "kickers", gen(M_KICKS, b, f"tg-m-{cat}-k", fit))
        add(K, "artifact", "heads", gen(A_HEADS, b, f"tg-a-{cat}-h", fit))
        add(K, "artifact", "reps", gen(A_REPS, b, f"tg-a-{cat}-r", fit))
        add(K, "artifact", "kickers", gen(A_KICKS, b, f"tg-a-{cat}-k", fit))
        sid = SCENE_OF[cat]
        add(SCN, sid, "caps", gen(SC_CAPS, b, f"tg-sc-{cat}-c", fit))
        add(SCN, sid, "heads", gen(SC_HEADS, b, f"tg-sc-{cat}-h", fit))
        add(SCN, sid, "says", gen(SC_SAYS, b, f"tg-sc-{cat}-s", fit))
        add(SCN, sid, "labels", gen(SC_LABELS, b, f"tg-sc-{cat}-l", fit))
        add(SCN, "art-" + sid, "caps", gen(ART_CAPS, b, f"tg-asc-{cat}-c", fit))
        F["notices"] += gen(N_NOTICES, b, f"tg-nt-{cat}", fit, ["recent_masterpiece"])
        F["gossip"] += gen(N_GOSSIP, b, f"tg-gs-{cat}", fit, ["recent_masterpiece"])
        F["trivia"] += gen(N_TRIVIA, b, f"tg-tv-{cat}", fit, ["recent_masterpiece"])
        F["notices"] += gen(AF_NOTICES, b, f"tg-ant-{cat}", fit, ["artifact_week"])
        F["gossip"] += gen(AF_GOSSIP, b, f"tg-ags-{cat}", fit, ["artifact_week"])
        add(F["followon"], "masterpiece_week", "heads", gen(FO_MAST_H, b, f"tg-fom-{cat}-h", fit))
        add(F["followon"], "masterpiece_week", "bodies", gen(FO_MAST_B, b, f"tg-fom-{cat}-b", fit))
        add(F["followon"], "artifact_week", "heads", gen(FO_ART_H, b, f"tg-foa-{cat}-h", fit))
        add(F["followon"], "artifact_week", "bodies", gen(FO_ART_B, b, f"tg-foa-{cat}-b", fit))
    for cause, b in DEATH.items():
        b = dict(b); b["how_up"] = b["how"].upper(); b["short"] = b["short"]
        b["lastdead_cause_h"] = b["how"]
        fit = ["die_" + cause]
        add(K, "death", "heads", gen(D_HEADS, b, f"tg-d-{cause}-h", fit))
        add(K, "death", "reps", gen(D_REPS, b, f"tg-d-{cause}-r", fit))
        add(K, "death", "kickers", gen(D_KICKS, b, f"tg-d-{cause}-k", fit))
        F["obits"] += gen(D_OBITS, b, f"tg-ob-{cause}", fit)
        fo_b = [x.replace("{lastdead_cause_h}", "<lastdead_cause_h>") for x in D_FO_B]
        add(F["followon"], "death_week", "heads", gen(D_FO_H, b, f"tg-fod-{cause}-h", fit))
        add(F["followon"], "death_week", "bodies", gen(fo_b, b, f"tg-fod-{cause}-b", fit))
    for mk, b in MOODS.items():
        fit = ["mood_" + mk]
        add(K, "mood", "heads", gen(MO_HEADS, b, f"tg-mo-{mk}-h", fit))
        add(K, "mood", "reps", gen(MO_REPS, b, f"tg-mo-{mk}-r", fit))
        add(K, "mood", "kickers", gen(MO_KICKS, b, f"tg-mo-{mk}-k", fit))
    for shop, b in SHOPS.items():
        fit = ["shop_" + shop]; slug = re.sub(r"\W+", "", shop.lower())
        add(K, "mood", "heads", gen([h.replace("{shop}", shop.upper()) for h in SH_HEADS], b, f"tg-sh-{slug}-h", fit))
        add(K, "mood", "reps", gen([h.replace("{shop}", shop) for h in SH_REPS], b, f"tg-sh-{slug}-r", fit))
        add(K, "mood", "kickers", gen([h.replace("{shop}", shop) for h in SH_KICKS], b, f"tg-sh-{slug}-k", fit))
    for mc, b in MINERALS.items():
        fit = [mc]
        add(K, "strike", "heads", gen(ST_HEADS, b, f"tg-st-{mc}-h", fit))
        add(K, "strike", "reps", gen(ST_REPS, b, f"tg-st-{mc}-r", fit))
        add(K, "strike", "kickers", gen(ST_KICKS, b, f"tg-st-{mc}-k", fit))
    for m, up in METALS.items():
        b = {"m": m, "M": up}
        add(K, "strike", "heads", gen(MET_HEADS, {"m": m}, f"tg-met-{m}-h", ["ore", "metal_" + m]))
        add(K, "strike", "reps", gen(MET_REPS, {"m": m}, f"tg-met-{m}-r", ["ore", "metal_" + m]))
    n = 0
    for fn, d in files.items():
        json.dump(d, open(os.path.join(HERE, fn), "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=1)
        c = json.dumps(d).count('"id"'); n += c
        print(fn, c)
    print("total", n)


if __name__ == "__main__":
    main()
