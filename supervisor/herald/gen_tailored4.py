# -*- coding: utf-8 -*-
"""Fourth wave of tailored Herald content (python herald/gen_tailored4.py from supervisor/): opinion pieces, letters,
help-wanted, vox pops, almanac/notices/gossip for each live condition (printed only while it holds), and more lines per
item category, exact noun, profession, death cause, mood, workshop, mineral, metal and beast. Writes library/tailored4_*.json."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tailored_banks import CAT, DEATH, MOODS, SHOPS, MINERALS, METALS
from gen_tailored import fill, gen
from gen_tailored2 import COND, BEASTS
from gen_tailored3 import NOUN, PROF

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")

# ---- conditions ----
ED = [("WHERE WE STAND ON <UP>", "This paper has said it before and will say it again: <fact>. That is not a crisis and not a triumph; it is a fact, and facts call for action. Our advice is to <adv>. Our observation is that <joke>."),
      ("A WORD ABOUT <SUBJ_UP>", "Readers keep asking about <subj>. Here is the answer: <fact>. The sensible course is to <adv>. The Herald will keep watching."),
      ("THE OVERSEER SHOULD KNOW", "We trust the Overseer has noticed that <fact>. If not, consider this the notice. A fort that can <adv> is a fort that lasts."),
      ("<UP>: OUR VIEW", "Some say it is nothing. Some say it is everything. The Herald says <fact>, and that every citizen should <adv>. Also, <joke>.")]
LT = ["I can't help noticing that <fact>. I propose we <adv>. Somebody has to say it.",
      "I read with interest that <fact>. In my day we would simply <adv>. Also, I have heard that <joke>. Is this true?",
      "I write about <subj>. <Fact>. That is all. I just wanted somebody to know.",
      "My neighbour insists <joke>. I insist only that <fact>. Please settle this."]
HW = ["WANTED: Willing hands. Because <fact>, the fort needs dwarves ready to <adv>. Apply to the Overseer.",
      "HELP WANTED: <fact>, so the fort needs hands. Pay: the usual. Perks: being right."]
VQ = ["What do you make of the news that <fact>?", "How do you feel about <subj> these days?"]
VA = [["I've noticed. Who hasn't?", "We should <adv>, if you ask me.", "I heard <joke>.", "I'm a miner. I only notice rocks."],
      ["Honestly? <Fact>.", "Things could be worse. Things are usually worse.", "I'm told we should <adv>.", "My cat has opinions. I don't."]]
AL = ["Almanac wisdom: <adv>, for <fact>.", "Note for the record book: <fact>.", "The elders remark that <joke>.", "For the days when <fact>: <adv>, and keep a mug nearby."]
NT = ["Bulletin: <fact>. Citizens will <adv>.", "Herald reminder: <fact>.", "Overseer's bulletin: please <adv>. Reason: <fact>.", "News from <subj>: <fact>."]
GS = ["Talk of the tavern: <joke>.", "Gossip from <subj>: <joke>. Is anyone surprised?", "Heard by the well: <fact>, and, apparently, <joke>.", "They're saying <joke>. They're also saying we should <adv>."]

# ---- per item category ----
M2_HEADS = ["<MAKER> REACHES THE TOP", "THE <THING_UP> OF THE SEASON", "MASTERWORK AT LAST: {item}", "{first} RAISES THE BAR AT <SHOP>", "THE DAY <SHOP> WON",
  "A MASTER'S {item}", "<PRAISE_UP>! THE NEW {item}", "THE <MAKER> WHO DID IT", "{item}: QUALITY ACHIEVED", "WHAT SKILL LOOKS LIKE: ONE {item}"]
M2_REPS = ["{first} spent the morning <tool_v>ing and the afternoon admiring. The result: a masterwork {item}, <praise> in every part.",
  "Even <fan> were surprised. The {item} that came out of <shop> today is masterwork quality, the best a <maker> can do.",
  "The {item} by {who} will be <use>. <Fan> have already argued about who gets to see it first.",
  "Skill builds slowly, then all at once. For {first}, all at once arrived today, in the shape of a masterwork {item}.",
  "The <tool> is down, the {item} is finished, and the verdict from <shop> is unanimous: masterwork.",
  "'<Praise>,' said one of the <makers> looking at the {item}. 'Very <praise>.' This is high praise in {fort}.",
  "A good <maker> makes good work. A great one makes the {item} that {first} made today.",
  "The masterwork {item} has been entered in the ledger with a small star beside it. The bookkeeper only draws stars for masterworks.",
  "{first} says the masterwork {item} was luck. Everyone at <shop> says it was skill. Everyone at <shop> is right.",
  "There will be other {item}s in {fort}, but this one will be the one the others are compared to.",
  "<Fan> lined up to see the {item}. The line went past <shop> and nearly to <place>.",
  "The {item} will go to <place>. It will be <use>, and it will be <praise> every time."]
M2_KICKS = ["A masterwork, by {first}.", "<Makers>, take note.", "Quality is its own reward. So is ale.", "Next stop: <place>.", "{first} has earned a nap.", "The <tool> rests."]
A2_REPS = ["{art} is a legendary {item}, made in a single strange mood by {who}. <Fan> came, saw, and could not stop talking.",
  "The strange mood is over, and {art} is the proof. The {item} is <praise>, and named, and the only one of its kind.",
  "{first} has made {art}. Nobody can make another. That is what makes a legend.", "{art} has gone straight into legend. <Fan> have been asking to see it all day.",
  "The fort's newest treasure is {art}, a legendary {item}. It will be kept at <place>, and guarded like one.",
  "Every fort hopes for an artifact. {fort} has {art}, a {item} that is <praise> beyond anything <shop> has seen.",
  "What does a legendary {item} look like? Like {art}. The Herald recommends a visit.",
  "The mood that gripped {first} ended in {art}. The fort breathes again, and admires."]
SC2_CAPS = ["{first} at <shop>, caught by our artist the moment the {item} was finished.", "The masterwork {item}: <praise>, finished, and about to be carried off to <place>.",
  "Our sketch artist's view of <shop>, the masterwork {item}, and a <maker> who has earned a sit-down.", "The {item}, shown to the room. The room approved.",
  "A sketch of {first} with the masterwork {item}, done quickly before <fan> took it away to admire.", "The new {item}, the <maker>, and the <tool>, in that order of pride.",
  "{who} and the masterwork {item}. Our artist drew the {item} first, out of respect.", "The scene at <shop> when the {item} was done. Somebody cheered; our artist drew the cheer."]
NT2 = ["Masterwork notice: {masterwork} by {masterwright}, now at <place>.", "The {masterwork} by {masterwright} is <praise>. Do not drop it.",
  "{masterwright} reminds visitors that the {masterwork} is for looking at.", "<Fan> may view the masterwork {masterwork} at <place>. Bring clean hands.",
  "{masterwright} would like to thank <shop> for the {masterwork}. <Shop> would like to thank {masterwright}.", "A star in the ledger: {masterwright}'s masterwork {masterwork}."]
GS2 = ["Is {masterwright} getting a big head over the {masterwork}? Our sources say: a little.", "<Fan> are said to have offered {masterwright} a week's wages for the {masterwork}. Refused.",
  "Over at <shop>, every <maker> is suddenly practising late. The {masterwork} by {masterwright} is to blame.", "{masterwright} has been seen polishing the {masterwork}. It does not need polishing.",
  "The {masterwork} came up at dinner again. {masterwright} pretended not to listen and listened very hard.", "Rumour: {masterwright} is planning another {masterwork}. {masterwright} denies all rumours."]

# ---- per exact noun ----
N2_REPS = ["The new {item} is a masterwork, and it will be <use>. <Joke_c>.", "Masterwork {item}: a rare sight in {fort}. Bound for <sit>.",
  "{first} has made the best <noun> in the fort, fit to be <use>.", "Picture the finest <noun> you can. Now picture the new {item}; it is better.",
  "Whoever gets the masterwork {item} will be lucky indeed; <joke>.", "Of every <noun> {first} has made, this {item} is the best."]
N2_HEADS = ["NEW <NOUN_UP>, MASTERWORK QUALITY", "THE <NOUN_UP> EVERYONE WANTS", "A <NOUN_UP> FIT TO BE <USE_UP>", "{first}'S MASTERWORK <NOUN_UP>"]

# ---- per profession (deaths) ----
P2_REPS = ["{first}, a <prof>, will be missed at <place>. Their <tool> hangs on the wall now.", "Every fort needs a good <prof>. {fort} had one in {first}, and is poorer for the loss.",
  "{who} <did>. Friends will remember them that way, and will remember them often.", "The work at <place> goes on, but more quietly. {first} was a <prof> to the end.",
  "Who will take up {first}'s <tool>? Nobody yet. The fort is giving it a little time.", "A <prof> is gone: {first}. The Herald thanks them for every day of work."]
P2_HEADS = ["FAREWELL TO OUR <PROF_UP>", "{first}, <PROF_UP>, REMEMBERED", "<PLACE_UP> MOURNS {first}"]

# ---- per death cause ----
D3_REPS = ["{first} <how> <scene>. The fort asks how, and answers: <remedy>.", "A {prof} lost to <sign>. {first} is remembered; the fort will <lesson>.",
  "The Herald has written many sad notices. This one, for {first}, who <how>, is among the hardest.", "{first} <how>. The worry now is <worry>; the answer is <remedy>.",
  "No more words are needed than these: {first} <how>. Please <lesson>.", "{who} <how> <scene>. The fort's elders will see to the slab."]
D3_HEADS = ["{first} <HOW_UP>: THE FORT ASKS WHY", "LOST: {first}, TO <SHORT>", "<SHORT> AGAIN? NEVER AGAIN", "THE PRICE OF <SHORT>"]
D3_CAPS = ["A memorial for {first}, who <how>.", "In memory of {who}, taken by <short_l>.", "The fort remembers {first}. Please <lesson>.", "{first} <how> <scene>. Our artist drew this with care."]

# ---- moods, shops, minerals, metals, beasts ----
MO3 = ["The <word> {first} sits in the workshop with <look>. No one may enter.", "When a dwarf goes <word>, the fort holds its breath. {first} has gone <word>.",
  "{first} <act>. The fort recognises a <word> mood when it sees one.", "Will the <word> mood end in a legend? The Herald waits, with the rest of {fort}.",
  "The <word> mood that has taken {first} is the talk of the fort. Elders call it rare; haulers call it busy.", "Messages from the <word> {first} are few and urgent. Haulers, be ready."]
MO3_H = ["THE <UP> MOOD: DAY ONE", "{first}'S <UP> MOOD", "WHAT THE <UP> DWARF WANTS", "A <UP> SILENCE IN THE WORKSHOP"]
SH3 = ["Witnesses say {first} walked into the {shop} and shut the door. Expect <made>; supply <needs>.", "The {shop} is off-limits for now. Inside: {first}, a strange mood and, soon, a great deal of <needs>.",
  "A strange mood has taken the {shop}. <Needs_c> may be called for at any hour."]
SH3_H = ["THE {shop} IS TAKEN", "{first} SEALS THE {shop}"]
ST3 = ["The miners hit {mineral}. <Fan> came running, and the miners let them.", "{mineral}: struck, cheered, and bound to be <use>.", "Down in the mines, the lamplight caught {mineral}. The <feel> was unmistakable.",
  "The new seam of {mineral} has been marked on the map. <Fan> will want to see it.", "A good strike is a good day. {mineral} makes it a very good day.", "{mineral} at last. The miners have earned their ale."]
ST3_H = ["{mineral} STRUCK!", "THE MINE PAYS OUT: {mineral}", "<FAN_UP> CHEER {mineral}", "STRIKE: {mineral}, AND PLENTY", "{mineral} BELOW {fort}"]
MET2 = ["The ore carries <m>. The smelters have lit an extra furnace in celebration.", "<M_c> from the new vein will keep the forges busy. The smiths approve.",
  "A miner turned over a lump of {mineral} and saw <m> in it. The smiths have been told.", "Smelt {mineral}, get <m>. The smelters have started on it already."]
MET2_H = ["<M> ORE STRUCK", "<M> FOR {fort}", "THE <M> VEIN", "SMITHS CHEER <M>"]
B3 = ["The <name> came from <from_>. The fort is ready, mostly. <Plan_c>.", "If you hear the <name>, do not go and look. Everyone else has already looked, and regrets it.",
  "Sightings of the <name> are coming in from every gate. All agree on <fear>.", "The <name> is here. The militia has been told. Everyone else, <plan>.",
  "The captain's orders regarding the <name>: <plan>. The Herald's advice: listen to the captain.", "Nobody in {fort} invited the <name>. It came anyway, from <from_>."]
B3_H = ["THE <UP> AT THE GATE", "<UP> SIGHTED", "{fort} BRACES FOR THE <UP>", "<UP>: STAY INSIDE"]


def main():
    out = {"tailored4_fold.json": {"editorials": [], "letters": [], "help_wanted": [], "voxpops": [], "almanac": [], "notices": [], "gossip": [], "followon": {}},
           "tailored4_kinds.json": {"kinds": {}, "scenes": {}}}
    F, K = out["tailored4_fold.json"], out["tailored4_kinds.json"]
    for c, b in COND.items():
        b = dict(b); b["subj_up"] = b["subj"].upper()
        for i, (h, body) in enumerate(ED):
            F["editorials"].append({"id": f"t4-ed-{c}-{i + 1}", "kick": "Opinion", "head": fill(h, b, i), "body": fill(body, b, i), "when": [c]})
        F["letters"] += [{"id": f"t4-lt-{c}-{i + 1}", "body": fill(f, b, i), "by": "{citizen}", "when": [c]} for i, f in enumerate(LT)]
        F["help_wanted"] += [{"id": f"t4-hw-{c}-{i + 1}", "text": fill(f, b, i), "when": [c]} for i, f in enumerate(HW)]
        F["voxpops"] += [{"id": f"t4-vp-{c}-{i + 1}", "q": fill(q, b, i), "answers": [fill(a, b, i) for a in VA[i]], "when": [c]} for i, q in enumerate(VQ)]
        F["almanac"] += [{"id": f"t4-al-{c}-{i + 1}", "text": fill(f, b, i), "when": [c]} for i, f in enumerate(AL)]
        F["notices"] += [{"id": f"t4-nt-{c}-{i + 1}", "text": fill(f, b, i), "when": [c]} for i, f in enumerate(NT)]
        F["gossip"] += [{"id": f"t4-gs-{c}-{i + 1}", "text": fill(f, b, i), "when": [c]} for i, f in enumerate(GS)]
    add = lambda d, k, part, items: d.setdefault(k, {}).setdefault(part, []).extend(items)
    SCENE_OF = __import__("gen_tailored").SCENE_OF
    for cat, b in CAT.items():
        b = dict(b); b["thing_up"] = [t.upper() for t in b["thing"]]; b["tool_v"] = {"cloth": "weav", "clothing": "sew", "weapon": "hammer", "armor": "hammer"}.get(cat, "work")
        fit = [cat] + (["mat_metal"] if cat == "weapon" else [])
        add(K["kinds"], "master", "heads", gen(M2_HEADS, b, f"t4-m-{cat}-h", fit))
        add(K["kinds"], "master", "reps", gen(M2_REPS, b, f"t4-m-{cat}-r", fit))
        add(K["kinds"], "master", "kickers", gen(M2_KICKS, b, f"t4-m-{cat}-k", fit))
        add(K["kinds"], "artifact", "reps", gen(A2_REPS, b, f"t4-a-{cat}-r", [cat]))
        add(K["scenes"], SCENE_OF[cat], "caps", gen(SC2_CAPS, b, f"t4-sc-{cat}-c", [cat]))
        F["notices"] += gen(NT2, b, f"t4-mn-{cat}", [cat], ["recent_masterpiece"])
        F["gossip"] += gen(GS2, b, f"t4-mg-{cat}", [cat], ["recent_masterpiece"])
    for noun, (cat, use, sit, joke) in NOUN.items():
        b = {"noun": noun, "use": use, "sit": sit, "joke": joke, "joke_c": joke}
        slug = re.sub(r"\W+", "", noun); fit = [cat, "n_" + noun]
        add(K["kinds"], "master", "reps", gen(N2_REPS, b, f"t4-n-{slug}-r", fit))
        add(K["kinds"], "master", "heads", gen(N2_HEADS, b, f"t4-n-{slug}-h", fit))
    for prof, (place, tool, did) in PROF.items():
        b = {"prof": prof, "place": place, "tool": tool, "did": did}
        slug = re.sub(r"\W+", "", prof); fit = ["prof_" + prof]
        add(K["kinds"], "death", "reps", gen(P2_REPS, b, f"t4-pd-{slug}-r", fit))
        add(K["kinds"], "death", "heads", gen(P2_HEADS, b, f"t4-pd-{slug}-h", fit))
    DEATH_SCENE = __import__("gen_tailored2").DEATH_SCENE
    for cause, b in DEATH.items():
        b = dict(b); b["how_up"] = b["how"].upper(); b["short_l"] = b["short"].lower(); fit = ["die_" + cause]
        add(K["kinds"], "death", "reps", gen(D3_REPS, b, f"t4-d-{cause}-r", fit))
        add(K["kinds"], "death", "heads", gen(D3_HEADS, b, f"t4-d-{cause}-h", fit))
        add(K["scenes"], DEATH_SCENE[cause], "caps", gen(D3_CAPS, b, f"t4-ds-{cause}-c", fit))
    for mk, b in MOODS.items():
        add(K["kinds"], "mood", "reps", gen(MO3, b, f"t4-mo-{mk}-r", ["mood_" + mk]))
        add(K["kinds"], "mood", "heads", gen(MO3_H, b, f"t4-mo-{mk}-h", ["mood_" + mk]))
    for shop, b in SHOPS.items():
        b = dict(b); b["needs_c"] = b["needs"]; slug = re.sub(r"\W+", "", shop.lower())
        add(K["kinds"], "mood", "reps", gen([x.replace("{shop}", shop) for x in SH3], b, f"t4-sh-{slug}-r", ["shop_" + shop]))
        add(K["kinds"], "mood", "heads", gen([x.replace("{shop}", shop.upper()) for x in SH3_H], b, f"t4-sh-{slug}-h", ["shop_" + shop]))
    for mc, b in MINERALS.items():
        add(K["kinds"], "strike", "reps", gen(ST3, b, f"t4-st-{mc}-r", [mc]))
        add(K["kinds"], "strike", "heads", gen(ST3_H, b, f"t4-st-{mc}-h", [mc]))
    for m, up in METALS.items():
        b = {"m": m, "m_c": m}
        add(K["kinds"], "strike", "reps", gen(MET2, b, f"t4-met-{m}-r", ["ore", "metal_" + m]))
        add(K["kinds"], "strike", "heads", gen(MET2_H, b, f"t4-met-{m}-h", ["ore", "metal_" + m]))
    for bk, b in BEASTS.items():
        b = dict(b); b["plan_c"] = b["plan"]
        add(K["kinds"], "beast", "reps", gen(B3, b, f"t4-b-{bk}-r", ["beast_" + bk]))
        add(K["kinds"], "beast", "heads", gen(B3_H, b, f"t4-b-{bk}-h", ["beast_" + bk]))
    for e in F["notices"] + F["gossip"]:
        if not e.get("fit"): e.pop("fit", None); e.pop("fit_auto", None)
    total = 0
    for fn, d in out.items():
        json.dump(d, open(os.path.join(HERE, fn), "w", encoding="utf-8", newline="\n"), ensure_ascii=False, indent=1)
        c = json.dumps(d).count('"id"'); total += c; print(fn, c)
    print("total", total)


if __name__ == "__main__":
    main()
