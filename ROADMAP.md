# Roadmap

Goals df-ai should take on by itself once a fort is big enough. Nothing here
is built yet.

## Large-population goals (100+ citizens)

### Pump stack to fill the cistern from water below it

The cistern fills by gravity: its inlet tunnels to water at or above the
reserve (`plan_cistern_tap`). When the only water is below it (common: lakes
and caverns under the halls), the fort first gets a well shaft
(`dfai-wellshaft`), which waters the fort but not the cistern, the hospital
wells or anything else fed from the reserve.

Once the fort is large, raise water to the reserve instead:

- a stack of screw pumps, one per level, from the water up to the reserve's
  inlet, in a sealed shaft (same rules as the inlet tunnel: rock all round,
  never into an aquifer);
- powered by windmills or a water wheel; share the mist generator's
  windmills where they are close, otherwise its own on the surface above;
- the inlet floodgate stays the on/off switch, so monitor_cistern's
  fill/empty cycle keeps working unchanged;
- the pump intake is fenced off from the lake by a grate so nothing swims up;
- stop pumping when the reserve is full (gear assembly on a lever, or just
  the inlet gate).

- Gate turrets: done (dfai-gateturret, one per gate). Next: more gates per wall ring, and a roof or parapet over the wall-top engines.
