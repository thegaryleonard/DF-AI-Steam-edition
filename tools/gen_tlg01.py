#!/usr/bin/env python3
"""Generate the "tlg01" df-ai blueprint plan: a fort laid out the way Twisted Logic
Gaming builds them (Strike The Earth: Panama Canal, DF Steam).

What makes it TLG-style (see rooms/TLG01.md for sources):
  * a 5x5 central stair core with stairs in an X (four corners + centre) to cut
    traffic collisions, repeated on every level as a "hub": 3-wide halls in a
    cross and a 5x5 room in each corner,
  * odd room sizes, nothing below 3x3: 3x3 bedrooms (bed, cabinet, coffer, statue
    by the door), 5x5 starter dormitory, 7x7 hospital, 11x11 halls,
  * every 3x3 workshop sits in its own room with a door (lock in a failed mood)
    with its input stockpile on both sides, two of the same kind side by side,
  * a tomb hall: centre aisle with coffins down both walls,
  * a first-year build order that follows his: food pile, carpenter, mason,
    farm, still + drink pile, dormitory, depot, craftsdwarf, mechanic + traps...

Room types that TLG does not do differently (depot, well/cistern, mineshaft,
execution pit, pastures, plain corridors, jail, barracks, ...) are copied from
generic01 with the prefix renamed so the plan is self-contained.

Run from the repo root:  python tools/gen_tlg01.py && python tools/bpcheck.py --plan tlg01
"""
import json, os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = 'tlg01_'
SCHEMA_T = 'https://ben.lubar.me/df-ai-schemas/room-template.json'
SCHEMA_I = 'https://ben.lubar.me/df-ai-schemas/room-instance.json'

# ------------------------------------------------------------------ authoring model
# Everything is authored facing NORTH: the entrance (door in the parent's wall) is
# at the origin and the room extends towards -y. rot() turns it to E/S/W.
ROT = {
    'north': lambda x, y: (x, y),
    'east': lambda x, y: (-y, x),
    'south': lambda x, y: (-x, -y),
    'west': lambda x, y: (y, -x),
}

class R:
    def __init__(self, name, x0, y0, x1, y1, z=0, z1=None, **props):
        self.name = name
        self.a = (x0, y0, z); self.b = (x1, y1, z if z1 is None else z1)
        self.props = props
        self.furn = []      # (x, y, z, props)
        self.exits = []     # (tag, x, y, z)
        self.access = []    # room names
        self.workshop = None
        self.placeholder = None

    def f(self, x, y, z=None, **props):
        self.furn.append((x, y, self.a[2] if z is None else z, props)); return self

    def exit(self, tag, x, y, z=None):
        self.exits.append((tag, x, y, self.a[2] if z is None else z)); return self

class T:
    def __init__(self):
        self.rooms = []

    def room(self, *a, **k):
        r = R(*a, **k); self.rooms.append(r); return r

    def get(self, name):
        return next(r for r in self.rooms if r.name == name)

    def emit(self, d='north'):
        rot = ROT[d]
        f_out, r_out = [], []
        names = [r.name for r in self.rooms]
        for r in self.rooms:
            (ax, ay), (bx, by) = rot(r.a[0], r.a[1]), rot(r.b[0], r.b[1])
            mn = (min(ax, bx), min(ay, by), r.a[2]); mx = (max(ax, bx), max(ay, by), r.b[2])
            layout = []
            for (x, y, z, props) in r.furn:
                px, py = rot(x, y)
                fj = dict(props)
                fj.update(x=px - mn[0], y=py - mn[1], z=z - mn[2])
                layout.append(len(f_out)); f_out.append(fj)
            rj = {}
            rj.update(r.props)
            rj['min'] = list(mn); rj['max'] = list(mx)
            if layout: rj['layout'] = layout
            if r.access: rj['accesspath'] = [names.index(n) for n in r.access]
            if r.workshop is not None: rj['workshop'] = names.index(r.workshop)
            if r.placeholder is not None: rj['placeholder'] = r.placeholder
            if r.exits:
                ex = []
                for (tag, x, y, z) in r.exits:
                    px, py = rot(x, y)
                    ex.append([tag, px - mn[0], py - mn[1], z - mn[2]])
                rj['exits'] = ex
            r_out.append(rj)
        out = {'$schema': SCHEMA_T}
        if f_out: out['f'] = f_out
        out['r'] = r_out
        return out

def stair(x, y, z):
    return dict(dig='UpDownStair', construction='UpDownStair', stairs_special=True)

X_STAIRS = [(-2, -2), (2, -2), (-2, 2), (2, 2), (0, 0)]

# ------------------------------------------------------------------ hub level
def hub_level(t, z, tag, corner_rooms=None, hall_exits=True, down=False, prefix='', remove=True):
    """5x5 X-stair core + four 3x7 halls. corner_rooms: dict corner -> callback(t, z, hall)."""
    core = t.room(prefix + 'core', -2, -2, 2, 2, z, type='corridor', corridor_type='corridor',
                  comment='staircase', **({'remove_if_unused': True} if remove else {}))
    for (x, y) in X_STAIRS:
        core.f(x, y, z, **stair(x, y, z))
    if down:
        core.exit(P + 'stair', 0, 0, z - 1)
    halls = {
        'n': t.room(prefix + 'hall_n', -1, -9, 1, -3, z, type='corridor', corridor_type='corridor'),
        's': t.room(prefix + 'hall_s', -1, 3, 1, 9, z, type='corridor', corridor_type='corridor'),
        'w': t.room(prefix + 'hall_w', -9, -1, -3, 1, z, type='corridor', corridor_type='corridor'),
        'e': t.room(prefix + 'hall_e', 3, -1, 9, 1, z, type='corridor', corridor_type='corridor'),
    }
    for k, h in halls.items():
        h.access = [core.name]
        if remove: h.props['remove_if_unused'] = True
    if hall_exits:
        halls['n'].exit(P + 'corridor_any', 0, -10, z)
        halls['s'].exit(P + 'corridor_any', 0, 10, z)
        halls['w'].exit(P + 'corridor_any', -10, 0, z)
        halls['e'].exit(P + 'corridor_any', 10, 0, z)
    corner_rooms = corner_rooms or {}
    # corner slots: 5x5 room, door in the hall wall at (+-2, +-6) (N/S halls)
    for corner, (hall, door, rect) in {
        'ne': ('n', (2, -6), (3, -8, 7, -4)),
        'nw': ('n', (-2, -6), (-7, -8, -3, -4)),
        'se': ('s', (2, 6), (3, 4, 7, 8)),
        'sw': ('s', (-2, 6), (-7, 4, -3, 8)),
    }.items():
        cb = corner_rooms.get(corner)
        if cb == 'exit':
            # leave the slot open for any TLG hub room, attached from the hall
            halls[hall].exit(tag, door[0], door[1], z)
            # and the matching slot from the E/W hall
            alt = {'ne': ('e', (6, -2)), 'nw': ('w', (-6, -2)), 'se': ('e', (6, 2)), 'sw': ('w', (-6, 2))}[corner]
            halls[alt[0]].exit(tag, alt[1][0], alt[1][1], z)
        elif cb:
            cb(t, z, halls[hall], door, rect, prefix + corner)
    return core, halls

def corner_stockpile(stype, level=1, **extra):
    def cb(t, z, hall, door, rect, name):
        r = t.room(name, rect[0], rect[1], rect[2], rect[3], z, type='stockpile', stockpile_type=stype, level=level, **extra)
        r.f(door[0], door[1], z, type='door')
        r.access = [hall.name]
    return cb

def corner_wrapped_workshop(wprops, sprops, level=1):
    """3x3 workshop in the middle of the 5x5 corner, stockpile ring around it."""
    def cb(t, z, hall, door, rect, name):
        x0, y0, x1, y1 = rect
        w = t.room(name, x0 + 1, y0 + 1, x1 - 1, y1 - 1, z, level=level, **wprops)
        w.access = [hall.name]
        # door side strip first so the door belongs to it
        side = 'w' if door[0] < x0 else 'e'
        strips = {
            'w': (x0, y0, x0, y1), 'e': (x1, y0, x1, y1),
            'n': (x0 + 1, y0, x1 - 1, y0), 's': (x0 + 1, y1, x1 - 1, y1),
        }
        order = [side] + [k for k in 'wens' if k != side]
        first = None
        for k in order:
            sx0, sy0, sx1, sy1 = strips[k]
            s = t.room(name + '_pile_' + k, sx0, sy0, sx1, sy1, z, type='stockpile', **sprops)
            s.workshop = w.name
            if first is None:
                s.f(door[0], door[1], z, type='door'); s.access = [hall.name]; first = s
            else:
                s.access = [first.name]
    return cb

def corner_office(suite):
    """Small 3x3 office right off the hall (TLG: manager and broker side by side)."""
    def cb(t, z, hall, door, rect, name):
        x0, y0, x1, y1 = rect
        sx = 1 if door[0] > 0 else -1
        xa, xb = sorted((door[0] + sx, door[0] + 3 * sx))
        r = t.room(name, xa, door[1] - 1, xb, door[1] + 1, z, type='nobleroom', nobleroom_type='office', noblesuite=suite)
        r.f(door[0], door[1], z, type='door')
        r.f(door[0] + 2 * sx, door[1], z, type='chair', makeroom=True)
        r.f(door[0] + 3 * sx, door[1], z, type='table')
        r.f(door[0] + 3 * sx, door[1] - 1, z, type='cabinet', ignore=True)
        r.access = [hall.name]
    return cb

def corner_dormitory(beds):
    def cb(t, z, hall, door, rect, name):
        x0, y0, x1, y1 = rect
        spots = [(x, y) for y in (y0, y0 + 2, y1) for x in (x0, x0 + 2, x1)]
        spots = [s for s in spots if not (abs(s[0] - door[0]) <= 1 and s[1] == door[1])][:beds]
        first = None
        for i, (bx, by) in enumerate(spots):
            r = t.room('%s_bed%d' % (name, i), x0, y0, x1, y1, z, type='bedroom')
            r.f(bx, by, z, type='bed', makeroom=True)
            if first is None:
                r.f(door[0], door[1], z, type='door'); r.access = [hall.name]; first = r
            else:
                r.access = [first.name]
    return cb

# ------------------------------------------------------------------ start
def start():
    t = T()
    ent = t.room('entrance', -3, -3, 3, 3, 0, type='corridor', corridor_type='corridor', outdoor=True, comment='fort entrance')
    for (x, y) in X_STAIRS:
        ent.f(x, y, 0, dig='DownStair', construction='DownStair')
    for x in range(-3, 4):
        for y in range(-3, 4):
            if max(abs(x), abs(y)) == 3:
                ent.f(x, y, 0, type='cage_trap', ignore=True)
    still = {'type': 'workshop', 'workshop_type': 'Still'}
    plant_pile = {'stockpile_type': 'food', 'stock_specific1': True, 'stock_disable': [
        'FoodMeat', 'FoodFish', 'FoodUnpreparedFish', 'FoodEgg', 'FoodDrinkPlant', 'FoodDrinkAnimal',
        'FoodCheesePlant', 'FoodCheeseAnimal', 'FoodSeeds', 'FoodMilledPlant', 'FoodBoneMeal', 'FoodFat',
        'FoodPaste', 'FoodPressedMaterial', 'FoodExtractPlant', 'FoodExtractAnimal', 'FoodMiscLiquid']}
    drinks_only = [s for s in ['FoodMeat', 'FoodFish', 'FoodUnpreparedFish', 'FoodEgg', 'FoodPlants',
                               'FoodCheesePlant', 'FoodCheeseAnimal', 'FoodSeeds', 'FoodLeaves', 'FoodMilledPlant',
                               'FoodBoneMeal', 'FoodFat', 'FoodPaste', 'FoodPressedMaterial', 'FoodExtractPlant',
                               'FoodExtractAnimal', 'FoodMiscLiquid']]
    # z-1: bare stair shaft, so the fort proper is 2+ levels under the surface
    # (Blind: felling trees above a 1-deep fort opens holes in the ceiling)
    shaft = t.room('shaft', -2, -2, 2, 2, -1, type='corridor', corridor_type='corridor', comment='staircase')
    for (x, y) in X_STAIRS:
        shaft.f(x, y, -1, **stair(x, y, -1))
    shaft.access = ['entrance']
    # level 1 (z-2): food pile, carpenter, mason, starter dormitory
    c1, h1 = hub_level(t, -2, P + 'hub_room', prefix='l1_', remove=False, corner_rooms={
        'nw': corner_stockpile('food'),
        'ne': corner_wrapped_workshop({'type': 'workshop', 'workshop_type': 'Carpenters'}, {'stockpile_type': 'wood'}),
        'se': corner_wrapped_workshop({'type': 'workshop', 'workshop_type': 'Masons'},
                                      {'stockpile_type': 'stone', 'stock_disable': ['StoneOres', 'StoneEconomic', 'StoneClay']}),
        'sw': corner_dormitory(8),
    })
    c1.access = ['shaft']
    # level 2 (z-3): manager + broker offices side by side, still + drinks room
    c2, h2 = hub_level(t, -3, P + 'hub_room', prefix='l2_', remove=False, corner_rooms={
        'nw': corner_office(0),
        'ne': corner_office(1),
        'sw': corner_wrapped_workshop(still, plant_pile),
        'se': corner_stockpile('food', comment='drinks', stock_disable=drinks_only),
    })
    c2.access = [c1.name]
    # level 3 (z-4): open hub, stair continues down
    c3, h3 = hub_level(t, -4, P + 'hub_room', prefix='l3_', remove=False, down=True,
                       corner_rooms={k: 'exit' for k in ('ne', 'nw', 'se', 'sw')})
    c3.access = [c2.name]
    return t

def hub():
    t = T()
    hub_level(t, 0, P + 'hub_room', down=True, corner_rooms={k: 'exit' for k in ('ne', 'nw', 'se', 'sw')})
    return t

# ------------------------------------------------------------------ workshops
def workshop_pair():
    """Two TLG workshop rooms in a row, each [pile|3x3 shop|pile] behind its own door."""
    t = T()
    w1 = t.room('w1', -1, -3, 1, -1, level=1); w1.placeholder = 0
    w1.f(0, 0, type='door', ignore=True)
    pa = t.room('p1w', -2, -3, -2, -1, type='stockpile'); pa.placeholder = 1; pa.workshop = 'w1'; pa.access = ['w1']
    pb = t.room('p1e', 2, -3, 2, -1, type='stockpile'); pb.placeholder = 1; pb.workshop = 'w1'; pb.access = ['w1']
    w2 = t.room('w2', -1, -7, 1, -5, level=2); w2.placeholder = 0
    qa = t.room('p2w', -2, -7, -2, -5, type='stockpile'); qa.placeholder = 1; qa.workshop = 'w2'
    qb = t.room('p2e', 2, -7, 2, -5, type='stockpile'); qb.placeholder = 1; qb.workshop = 'w2'; qb.access = ['w2']
    w2.f(0, -4, type='door', ignore=True); w2.access = ['w1']; qa.access = ['w2']
    return t

def workshop_single():
    t = T()
    w1 = t.room('w1', -1, -3, 1, -1, level=1); w1.placeholder = 0
    w1.f(0, 0, type='door', ignore=True)
    for n, x in (('p1w', -2), ('p1e', 2)):
        p = t.room(n, x, -3, x, -1, type='stockpile'); p.placeholder = 1; p.workshop = 'w1'; p.access = ['w1']
    return t

# ------------------------------------------------------------------ living
def bedroom():
    """3x3 bedroom: bed, cabinet, coffer, a statue by the door."""
    t = T()
    r = t.room('bed', -1, -3, 1, -1, type='bedroom')
    r.f(-1, -3, type='bed', makeroom=True)
    r.f(1, -3, type='cabinet', ignore=True)
    r.f(1, -1, type='chest', ignore=True)
    r.f(-1, -1, type='statue', ignore=True)
    r.f(0, 0, type='door')
    return t

def bedrooms():
    """Bedroom block: 3-wide hall, 3x3 rooms on both sides, one wall between rooms."""
    t = T()
    c = t.room('hall', -1, -11, 1, -1, type='corridor', corridor_type='corridor', remove_if_unused=True)
    c.f(-1, 0, type='door'); c.f(1, 0, type='door')
    for y in (-2, -6, -10):
        c.exit(P + 'bedroom', -2, y); c.exit(P + 'bedroom', 2, y)
    c.exit(P + 'bedrooms', 0, -12); c.exit(P + 'corridor', 0, -12)
    return t

def infirmary():
    """7x7 mass-casualty hospital (TLG: beds for a quarter of the fort)."""
    t = T()
    r = t.room('hospital', -3, -7, 3, -1, type='infirmary')
    r.f(0, 0, type='door')
    for (x, y) in [(-3, -7), (-3, -5), (-3, -3), (3, -7), (3, -5), (3, -3), (-1, -7), (1, -7)]:
        r.f(x, y, type='bed')
    for (x, y) in [(-2, -5), (2, -5), (0, -7)]:
        r.f(x, y, type='table')
    r.f(-1, -3, type='traction_bench'); r.f(1, -3, type='traction_bench')
    for (x, y) in [(-3, -1), (3, -1), (2, -1)]:
        r.f(x, y, type='chest')
    return t

def cemetery():
    """Tomb hall: 3-wide centre aisle, coffins down both walls, more halls chain on."""
    t = T()
    r = t.room('tombs', -2, -9, 2, -1, type='cemetery')
    r.f(0, 0, type='door')
    for y in range(-9, -1):
        r.f(-2, y, type='coffin', has_users=1, ignore=True)
        r.f(2, y, type='coffin', has_users=1, ignore=True)
    r.exit(P + 'cemetery', 0, -10)
    return t

def location():
    """11x11 hall. Placeholders match generic01_location instances:
    0 = location, 1 = tables/chairs, 2 = stockpile strip, 3 = wall furniture (bookcases)."""
    t = T()
    r = t.room('hall', -5, -11, 5, -1, type='location'); r.placeholder = 0
    r.f(-1, 0, type='door'); r.f(1, 0, type='door')
    # Blind: a tavern needs ~6x6 open floor for dancing and exactly one chair
    # per table, so only the back half gets table rows
    for (x, y) in ((-5, -10), (5, -10)):
        r.f(x, y, type='chest', placeholder=1)
    for y in (-9, -7):
        # chair table table chair | aisle | chair table table chair
        for x, kind in ((-5, 'chair'), (-4, 'table'), (-3, 'table'), (-2, 'chair'),
                        (2, 'chair'), (3, 'table'), (4, 'table'), (5, 'chair')):
            r.f(x, y, type=kind, placeholder=1)
    for x in range(-5, 6):
        r.f(x, -11, placeholder=3)
    r.f(0, -6, placeholder=4)  # altar (offering place) for temples
    s = t.room('pile', -4, -10, 4, -10); s.placeholder = 2; s.workshop = 'hall'
    return t

# ------------------------------------------------------------------ write files
def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(obj, f, indent='\t')
        f.write('\n')

COPY = ['apiary', 'barracks', 'cage_trap', 'corridor', 'corridor_stair', 'depot', 'jail', 'mineshaft',
        'mineshaft_segment', 'nobleroom', 'outdoor_farm', 'outpost_entrance', 'pasture', 'execution_pit',
        'stockpile', 'underground_farm_extension', 'underground_farm_start', 'well', 'workshop_1x1',
        'workshop_5x5']

def main():
    rooms = os.path.join(ROOT, 'rooms')
    for sub in ('templates', 'instances'):
        for d in os.listdir(os.path.join(rooms, sub)):
            if d.startswith(P):
                shutil.rmtree(os.path.join(rooms, sub, d))
    # copied room types
    for typ in COPY:
        for sub in ('templates', 'instances'):
            src = os.path.join(rooms, sub, 'generic01_' + typ)
            for fn in os.listdir(src):
                txt = open(os.path.join(src, fn), encoding='utf-8').read().replace('generic01_', P)
                dst = os.path.join(rooms, sub, P + typ, fn)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, 'w', encoding='utf-8', newline='\n').write(txt)
    T_DIR = lambda typ, name: os.path.join(rooms, 'templates', P + typ, name + '.json')
    I_DIR = lambda typ, name: os.path.join(rooms, 'instances', P + typ, name + '.json')
    gen = lambda: {'$schema': SCHEMA_I, 'p': []}
    write_json(T_DIR('start', 'hub'), start().emit()); write_json(I_DIR('start', 'generic'), gen())
    write_json(T_DIR('hub', 'x_stair'), hub().emit()); write_json(I_DIR('hub', 'generic'), gen())
    for d in ROT:
        write_json(T_DIR('workshop_3x3', d + '_pair'), workshop_pair().emit(d))
        write_json(T_DIR('bedroom', d), bedroom().emit(d))
        write_json(T_DIR('bedrooms', d), bedrooms().emit(d))
        write_json(T_DIR('infirmary', d), infirmary().emit(d))
        write_json(T_DIR('cemetery', d), cemetery().emit(d))
        write_json(T_DIR('location', d), location().emit(d))
    for n in ('bedroom', 'bedrooms', 'infirmary', 'cemetery'):
        write_json(I_DIR(n, 'generic'), gen())
    # workshop / location instances: same placeholder contract as generic01
    for typ in ('workshop_3x3', 'location'):
        src = os.path.join(rooms, 'instances', 'generic01_' + typ)
        for fn in os.listdir(src):
            obj = json.load(open(os.path.join(src, fn), encoding='utf-8'))
            if typ == 'location':
                obj['p'].append({'type': 'offering_place'} if obj['p'][0].get('location_type') == 'temple' else {'skip': True})
            if typ == 'location' and obj['p'][0].get('location_type') == 'tavern':
                obj['p'][2]['comment'] = 'tavern - booze stockpile'
            write_json(I_DIR(typ, fn[:-5]), obj)
    write_json(os.path.join(ROOT, 'plans', 'tlg01.json'), make_plan())
    print('generated tlg01 rooms and plans/tlg01.json')

# ------------------------------------------------------------------ plan
def make_plan():
    g = json.load(open(os.path.join(ROOT, 'plans', 'generic01.json'), encoding='utf-8'))
    ren = lambda v: json.loads(json.dumps(v).replace('generic01_', P))
    plan = {
        '$schema': 'https://ben.lubar.me/df-ai-schemas/plan.json',
        'start': P + 'start',
        'padding_x': [-20, 20],
        'padding_y': [-20, 20],
        'max_failures': 300,
        # TLG keeps a smaller, trained militia rather than half the fort under arms
        'military_limit': [20, 50],
    }
    plan['tags'] = {
        P + 'in_corridor': [P + 'workshop_1x1'],
        P + 'corridor_any': [P + 'corridor', P + 'corridor_stair'],
        P + 'stair': [P + 'hub'],
        # the 5x5 corner slots of every hub level: industry and services stay
        # close to the stairs ("closer to the hub = faster work")
        P + 'hub_room': [P + 'workshop_3x3', P + 'infirmary', P + 'jail', P + 'cemetery',
                         P + 'underground_farm_start'],
        P + 'generic': [P + 'bedrooms', P + 'cemetery', P + 'corridor', P + 'execution_pit', P + 'infirmary', P + 'jail',
                        P + 'location', P + 'nobleroom', P + 'underground_farm_start',
                        P + 'workshop_3x3', P + 'workshop_5x5'],
        P + 'wide': [P + 'barracks', P + 'stockpile', P + 'well'],
    }
    plan['outdoor'] = [P + n for n in ('apiary', 'cage_trap', 'depot', 'mineshaft', 'outdoor_farm',
                                       'outpost_entrance', 'pasture')]
    plan['count_as'] = {P + 'start/hub/generic': {P + 'bedroom': 8}}
    plan['limits'] = {
        P + 'apiary': [1, 1],
        P + 'cage_trap': [10, 40],
        P + 'barracks': [2, 6],
        P + 'bedroom': [60, 160],     # one 3x3 room per dwarf plus spares for births
        P + 'bedrooms': [10, 30],
        P + 'cemetery': [2, 8],       # 16 coffins per tomb hall
        P + 'corridor': [5, 250],
        P + 'corridor_stair': [0, 30],
        P + 'depot': [1, 1],
        P + 'hub': [2, 12],
        P + 'infirmary': [1, 3],
        P + 'jail': [1, 2],
        P + 'mineshaft': [1, 1],
        P + 'mineshaft_segment': [1, 3],
        P + 'nobleroom': [4, 8],
        P + 'outpost_entrance': [1, 1],
        P + 'pasture': [0, 6],
        P + 'execution_pit': [1, 1],   # underground (see gen_execution_pit.py)
        P + 'start': [1, 1],
        P + 'well': [1, 1],
    }
    il = ren(g['instance_limits'])
    il[P + 'location'] = {'guildhall': [1, 4], 'library': [1, 2], 'tavern': [1, 2], 'temple': [1, 3]}
    # TLG keeps dwarves indoors: few surface plots, underground plump helmets instead
    il[P + 'outdoor_farm'] = {'food': [0, 4], 'cloth': [0, 6]}
    il[P + 'underground_farm_start'] = {'food': [4, 8], 'cloth': [3, 6]}
    il[P + 'underground_farm_extension'] = {'food': [6, 30], 'cloth': [6, 30]}
    # every workshop blueprint is a pair of the same shop, so these are pairs
    ws = il[P + 'workshop_3x3']
    pairs = {'workshop_masons': [2, 3], 'workshop_craftsdwarfs': [2, 2], 'workshop_carpenters': [1, 2],
             'workshop_still': [1, 2], 'workshop_mechanics': [1, 1], 'workshop_kitchen': [1, 2],
             'workshop_butchers': [1, 2], 'workshop_tanners': [1, 2], 'workshop_farmers': [1, 2],
             'workshop_clothiers': [1, 2], 'workshop_loom': [1, 2], 'workshop_metalsmithsforge': [1, 1],
             'furnace_smelter': [1, 1], 'furnace_wood': [1, 1]}
    for k in ws:
        ws[k] = pairs.get(k, [1, 1])
    plan['instance_limits'] = il

    pr = ren(g['priorities'])
    by = {p['name']: p for p in pr}
    def take(name):
        return by.pop(name)
    order = ['Food Stockpile', "Carpenter's Workshop", "Mason's Workshop", 'Starter Farm (Food)', 'Still']
    out = [take(n) for n in order]
    out[4] = dict(out[4], **{'action': 'dig_immediate'})
    out.append({'continue': True, 'name': 'Drinks Room', 'action': 'dig_immediate',
                'match': {'type': 'stockpile', 'comment': 'drinks'}})
    out.append(take('Starter Farm (Cloth)'))
    for n in ['Garbage Dump', 'Trade Depot', "Craftsdwarf's Workshop", "Mechanic's Workshop",
              'Entrance Static Defenses', 'Kitchen', 'Second Food Stockpile', 'Well', 'Infirmary',
              'Butcher', 'Tannery', 'Additional Mason\'s Workshop', 'Mining Outpost', 'Wood Furnace',
              'Start Mining Ores', 'Smelter', "Metalsmith's Forge", 'Cemetery', 'Temple',
              "Farmer's Workshop", 'Loom', "Clothier's Workshop", 'Leatherworker\'s Workshop', 'Jail']:
        out.append(take(n))
    # keep the remaining generic01 steps in their original order
    out += [p for p in pr if p['name'] in by]
    plan['priorities'] = out
    plan['stock_goals'] = {
        # TLG work orders: never let drink run low, keep empty barrels/bins around
        'drink': {'needed': 100, 'per_cent': 300},
        'barrel': {'needed': 6},
        'bin': {'needed': 6},
        'bag': {'needed': 6},
        'coffin': {'needed': 4},
        'splint': {'needed': 10},
        'crutch': {'needed': 10},
        'soap': {'needed': 5},
        'bucket': {'needed': 10},
    }
    return plan

if __name__ == '__main__':
    main()
