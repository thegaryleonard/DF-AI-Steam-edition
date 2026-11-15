# DNN (Dwarf News Network) copy library

DNN is a 24-hour dwarven cable-news channel about the fort, shown on the TV app and as an
OBS scene. Every spoken line is a CAPTION (no voices), so lines must read well in 1-2 lines
on screen. All prose lives in `supervisor/dnn/copy/*.json`; the page picks least-recently
used entries, so volume and variety matter. Never hard-code lines in dnn.js.

## Tone
- In-world: DNN is a dwarven network, the viewers are the fort's dwarves. Cable-news parody:
  BREAKING NEWS, "we're getting reports", "sources close to the ale stockpile", panels that
  argue about nothing, anchors who over-dramatise a masterpiece sock, field reporters
  standing in the rain. Dry, deadpan, affectionate. Sitcom energy, not cruelty.
- Dwarf Fortress-accurate flavour: ale and drink, strange moods, masterworks, carp, elves
  (hated tree-huggers), goblins, forgotten beasts, cats everywhere, magma, nobles and
  mandates, caravans, the depot, migrants, tantrums, the hospital, the tavern.
- World-agnostic: NEVER write a literal name of a dwarf, fort, civilisation, site or god.
  Real names come only through the slots below. No real-world people, brands, places.
- Never open a line with a slot that may be lowercase ({prof}, {thing}, {creature},
  {place_kind}, {weather}). Opening with {name}, {anchor}, {anchor2}, {reporter},
  {fort}, {citizen}, {citizen2}, {civ}, {caravan_civ} is fine.
- Lengths: `head` <= 48 chars (ALL CAPS banner), caption lines <= 160 chars,
  `ticker` <= 90 chars, `reaction` <= 120 chars, debate `topic` <= 40 chars.
- Every entry has a unique `id` with the file's prefix, e.g. `dnb-death-read-7`.

## Entry shape
`{"id": "...", "text": "...", "when": ["cond", ...]}` (`when` optional: ALL listed
conditions must hold). An entry whose slot has no value at air time is skipped.

## Slots (write them in braces)
- Everywhere: {fort} {world} {anchor} {anchor2} {reporter} {pop} {season} {month} {year}
  {citizen} {citizen2} {civ}
  ({anchor} = main anchor, {anchor2} = co-anchor, {reporter} = field reporter; all dwarves.
  {citizen}/{citizen2} = random citizens. {pop} = population number. {civ} = the fort's
  parent civilisation.)
- breaking / reaction only: {name} (the dwarf or creature in the story), {prof} (their
  profession, lowercase), {thing} (the item/artifact made, lowercase), {creature} (an
  animal or monster kind, lowercase), {count} (a number, e.g. migrants)
- field only: {place} (the room's proper name, e.g. a tavern's name), {place_kind}
  (tavern, temple...), {guest} (dwarf being interviewed), {guest_prof}, {guest_job}
  (what they are doing right now, e.g. "Store item in stockpile")
- markets only: {drinks} {meals} {meat} {plants} {gems} {bars} {wood} {stone} {cats}
  (all numbers)
- weather only: {weather} (rain, snow...)
- trade only: {caravan_civ}
- works only: {project}

## Conditions (for `when`)
drinks_low drinks_high food_low food_high meat_low cats_many pop_small pop_big
young_fort old_fort raining snowing clear spring summer autumn winter peace recent_death

## Sections (top-level keys; each file owns its own keys)
dnn_breaking.json
- `breaking`: {kind: {"heads": [entries], "reads": [entries]}} heads are the red banner,
  reads are what the anchor says.
- `reaction`: {kind: [entries]} the co-anchor's reaction after the read.
- kinds: death pet_death birth migrants caravan diplomat artifact masterpiece mood beast
  siege soldier civilian quota marriage noble generic

dnn_desk.json
- `open` show opens, `close` sign-offs, `toss` anchor hands over to {reporter} in the
  field, `toss_back` reporter hands back to {anchor}, `banter` anchor small talk (entries
  have "a" and "b" fields instead of "text": a = {anchor}'s line, b = {anchor2}'s reply),
  `bumper` "we'll be right back" cards, `promo` "coming up" teases,
  `segment` {markets|weather|sports|world|trade|works|crossfire|interview: [entries]}
  anchor intros to each segment.

dnn_field.json
- `field` {tavern|temple|library|hospital|guildhall|dining|barracks|pasture|depot|
  workshop|farm|dig|entrance|machine|generic: [entries]} reporter live from the room on
  camera ({place}, {place_kind}).
- `interview_q`: questions the reporter asks {guest}. `interview_a`
  {happy|stressed|neutral|child|soldier|busy: [entries]} {guest}'s answer (first person).
- `weather` {rain|snow|clear|other: [entries]} the weather desk.

dnn_markets.json
- `markets`: the Ale Index / stockpile market report (stock slots + conditions).
- `ads`: sponsor reads ("DNN is brought to you by...") for in-world products/services.
- `ticker`: short crawl lines, generic fort/world news and jokes.
- `sports`: sports desk (sparring, wrestling, dodging, the hauling league...).
- `trade`: trade desk lines ({caravan_civ} optional).
- `works`: big-project desk lines ({project}).

dnn_debate.json
- `debate`: entries `{"id", "topic", "lines": [4-6 strings]}`: a two-pundit shouting
  match, lines alternate pundit A, pundit B. Pundits are introduced by the page, so lines
  don't name them. Slots from "Everywhere" allowed.
- `world`: world desk lines about the wider world ({civ} and generic powers: elves,
  goblins, humans, the mountainhome).

Validate with `python supervisor/dnn/validate_copy.py`.
