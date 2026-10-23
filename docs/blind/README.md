# Blind's DF guide compilation: notes for df-ai

Source: Blind, "Dwarf Fortress - Complete Tutorial/Guide Compilation" (youtube.com/watch?v=WOgwysfvb3s).
I transcribed 25 chapters locally with Whisper, because YouTube was blocking caption requests.
- Raw transcripts: `*.txt` in this folder (timestamps are positions in the full video).
- Tagged notes: `notes_fundamentals.md` (farming, food, embark, labors, animals) and `notes_rooms_services.md` (taverns, temples, bedrooms, hospitals, wells, trade, military, justice).

Every note is tagged [BLUEPRINT] (room layout and stock goals, in plans/rooms) or [BEHAVIOUR] (df-ai C++).

## Already applied to tlg01

- The fort proper starts 2 z-levels down. z-1 is a bare stair shaft, so felling trees can't open holes in the hub ceiling.
- Taverns have only two table rows, which leaves an 11x6 dance floor. Each table gets one chair, and there are coffers for mugs.
- Temples get an altar (offering place).
- Stock goals: 10 splints, 10 crutches, 10 buckets (hospital, soap).

## Behaviour items for the df-ai code owner (not done; check each against current code)

Highest value first:
1. **Plump helmets: brew, never cook.** Cooking destroys the spawn and the fort runs out of seed. Blind calls this the first thing to do in any fort (0:14:21, 5:11:21). Also stop ale being used as a cooking ingredient (2:16:45).
2. **Seed stockpiles: 0 barrels** (seeds go in bags) (5:10:36).
3. **Plump helmets in all four seasons** on underground plots (5:12:29).
4. **Barrels before brewing.** Queue them a few at a time, because a repeating barrel job eats all the wood (0:26:00).
5. **Miners and woodcutters must be different dwarves**, or they swap tools and cancel jobs. Restrict fishing to selected dwarves and keep hunters few.
6. **Zone access:** taverns, temples, hospitals and libraries should be citizens + long-term residents (keeps visitors from drinking the stock, and keeps vampires and thieves out). Temples "no specific deity". Guild halls open to citizens so children train there.
7. **Required nobles:** a tavern keeper (serves drinks), a chief medical dwarf (or the hospital does nothing), a broker plus "broker requested at depot", a militia commander before squads, and a captain of the guard with an office.
8. **Trading with elves:** never offer wood or anything made with or decorated with wood.
9. **Animals:** grazers need a pasture or they starve. Keep auto-butcher, auto-tan and auto-clean-fish on. Turn off auto-collect webs once caverns open.
10. **Burials:** bury the dead promptly to avoid ghosts. Engrave memorial slabs only when the body is lost.
