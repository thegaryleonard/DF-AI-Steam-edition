#!/usr/bin/env python3
"""Offline checker + layout simulator for df-ai blueprints.

Mirrors the C++ loader (blueprint.cpp, blueprint_merge.cpp, blueprint_template.cpp)
and the room placement algorithm (plan_setup_blueprint.cpp: PlanSetup::build) closely
enough to catch broken JSON, bad indexes, unknown room/tag references, and plans that
can never satisfy their minimum room limits, without starting Dwarf Fortress.

Terrain model for the simulation: a flat embark, open air above SURFACE_Z, solid
stone below it, no water/caverns/trees. Real maps are harder; a plan that fails
here will certainly fail in game, a plan that passes here usually works.

Usage:
  python tools/bpcheck.py [--root DIR] [--plan NAME] [--sims N] [--seed S] [--map OUT.txt]
"""
import argparse, json, os, random, re, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------- enums
def load_enums(root):
    d = json.load(open(os.path.join(root, 'schemas', 'enums.json'), encoding='utf-8'))
    return {k: set(v['enum']) for k, v in d.items() if isinstance(v, dict) and 'enum' in v}

ROOM_ENUM_FIELDS = {
    'type': 'room_type', 'corridor_type': 'corridor_type', 'farm_type': 'farm_type',
    'stockpile_type': 'stockpile_type', 'nobleroom_type': 'nobleroom_type',
    'outpost_type': 'outpost_type', 'location_type': 'location_type',
    'cistern_type': 'cistern_type', 'workshop_type': 'workshop_type', 'furnace_type': 'furnace_type',
}
ROOM_BOOL = ['stock_specific1', 'stock_specific2', 'temporary', 'outdoor', 'single_biome',
             'require_walls', 'require_floor', 'require_stone', 'in_corridor',
             'remove_if_unused', 'build_when_accessible']
ROOM_INT = ['level', 'queue', 'has_users', 'require_grass']
ROOM_OTHER = ['raw_type', 'comment', 'min', 'max', 'exits', 'optional_walls', 'accesspath',
              'layout', 'noblesuite', 'workshop', 'stock_disable', 'placeholder']
FURN_FIELDS = {'type', 'construction', 'dig', 'x', 'y', 'z', 'target', 'has_users', 'ignore',
               'makeroom', 'internal', 'stairs_special', 'comment', 'placeholder'}

class BPError(Exception):
    pass

class Furn:
    def __init__(self):
        self.placeholder = None
        self.type = 'none'; self.construction = 'NONE'; self.dig = 'Default'
        self.pos = (0, 0, 0); self.target = None
        self.ignore = False; self.stairs_special = False

    def copy(self):
        f = Furn(); f.__dict__.update(self.__dict__); return f

    def apply(self, d, enums, allow_ph):
        d = dict(d)
        if 'placeholder' in d:
            if not allow_ph:
                raise BPError('placeholder not allowed here')
            self.placeholder = d.pop('placeholder')
        for k in list(d):
            if k not in FURN_FIELDS:
                raise BPError('unhandled furniture property ' + k)
        if 'type' in d:
            if d['type'] not in enums['layout_type']: raise BPError('bad furniture type ' + str(d['type']))
            self.type = d['type']
        if 'construction' in d:
            if d['construction'] not in enums['construction_type']: raise BPError('bad construction ' + str(d['construction']))
            self.construction = d['construction']
        if 'dig' in d:
            if d['dig'] not in enums['tile_dig_designation']: raise BPError('bad dig ' + str(d['dig']))
            self.dig = d['dig']
        x, y, z = self.pos
        x = d.get('x', x); y = d.get('y', y); z = d.get('z', z)
        for v in (x, y, z):
            if not isinstance(v, int): raise BPError('furniture coordinate must be int')
        self.pos = (x, y, z)
        if 'target' in d: self.target = d['target']
        if 'ignore' in d: self.ignore = bool(d['ignore'])
        if 'stairs_special' in d: self.stairs_special = bool(d['stairs_special'])

class Room:
    def __init__(self):
        self.placeholder = None
        self.type = 'corridor'; self.corridor_type = 'corridor'
        self.min = None; self.max = None
        self.exits = {}  # coord(rel to min) -> {tag: ctx}
        self.accesspath = []; self.layout = []
        self.workshop = None
        self.outdoor = False; self.require_walls = True; self.require_floor = True
        self.in_corridor = False; self.remove_if_unused = False
        self.noblesuite = -1
        self.attrs = {}

    def copy(self):
        r = Room(); r.__dict__.update(self.__dict__)
        r.exits = {k: dict(v) for k, v in self.exits.items()}
        r.accesspath = list(self.accesspath); r.layout = list(self.layout); r.attrs = dict(self.attrs)
        return r

    def apply(self, d, enums, allow_ph):
        d = dict(d)
        if 'placeholder' in d:
            if not allow_ph: raise BPError('placeholder not allowed here')
            self.placeholder = d.pop('placeholder')
        for k in d:
            if k not in ROOM_ENUM_FIELDS and k not in ROOM_BOOL and k not in ROOM_INT and k not in ROOM_OTHER:
                raise BPError('unhandled room property ' + k)
        for k, e in ROOM_ENUM_FIELDS.items():
            if k in d:
                if d[k] not in enums[e]: raise BPError('bad %s %r' % (k, d[k]))
                setattr(self, k, d[k]) if k in ('type', 'corridor_type') else None
                self.attrs[k] = d[k]
        if self.min is None:
            if 'min' not in d: raise BPError('missing min on room' if 'max' in d else 'missing min and max on room')
            if 'max' not in d: raise BPError('missing max on room')
            self.min = tuple(d['min']); self.max = tuple(d['max'])
            if len(self.min) != 3 or len(self.max) != 3: raise BPError('coord must have 3 ints')
            for a, b, n in zip(self.min, self.max, 'xyz'):
                if a > b: raise BPError('min.%s > max.%s' % (n, n))
            for ex in d.get('exits', []):
                if not (isinstance(ex, list) and 4 <= len(ex) <= 5 and isinstance(ex[0], str) and all(isinstance(v, int) for v in ex[1:4])):
                    raise BPError('exit has wrong type')
                self.exits.setdefault(tuple(ex[1:4]), {})[ex[0]] = ex[4] if len(ex) > 4 else {}
        for ow in d.get('optional_walls', []):
            self.exits.setdefault(tuple(ow), {})
        if 'accesspath' in d: self.accesspath = list(d['accesspath'])
        if 'layout' in d: self.layout = list(d['layout'])
        if 'noblesuite' in d: self.noblesuite = d['noblesuite']
        if 'workshop' in d: self.workshop = d['workshop']
        if 'stock_disable' in d:
            for s in d['stock_disable']:
                if s not in enums['stockpile_list']: raise BPError('bad stock_disable ' + s)
        for k in ('outdoor', 'require_walls', 'require_floor', 'in_corridor', 'remove_if_unused'):
            if k in d: setattr(self, k, bool(d[k]))
        for k in ROOM_BOOL + ROOM_INT + ['raw_type', 'comment']:
            if k in d: self.attrs[k] = d[k]

def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])

def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

class Blueprint:
    """room_blueprint: template + instance merged."""
    def __init__(self, typ, tmpl_name, tmpl, name, inst, enums):
        self.type, self.tmpl_name, self.name = typ, tmpl_name, name
        tf, tr = tmpl
        placeholders, inf, inr = inst
        min_ph = 0
        for o in tf + tr:
            if o.placeholder is not None: min_ph = max(min_ph, o.placeholder + 1)
        if min_ph > len(placeholders): raise BPError('not enough placeholders in instance')
        lay0, room0 = len(tf), len(tr)
        layout = []
        for ft in tf:
            f = ft.copy()
            if f.placeholder is not None:
                p = placeholders[f.placeholder]
                if p.get('skip'):
                    f = None
                else:
                    if f.target is not None: f.target -= lay0
                    f.apply(p, enums, False)
                    if f.target is not None: f.target += lay0
            layout.append(f)
        rooms = []
        for rt in tr:
            r = rt.copy()
            if r.placeholder is not None:
                p = placeholders[r.placeholder]
                if p.get('skip'):
                    r = None
                else:
                    r.accesspath = [a - room0 for a in r.accesspath]; r.layout = [l - lay0 for l in r.layout]
                    if r.workshop is not None: r.workshop -= room0
                    r.apply(p, enums, False)
                    r.accesspath = [a + room0 for a in r.accesspath]; r.layout = [l + lay0 for l in r.layout]
                    if r.workshop is not None: r.workshop += room0
            rooms.append(r)
        for fi in inf:
            f = fi.copy()
            if f.target is not None: f.target += lay0
            layout.append(f)
        for ri in inr:
            r = ri.copy()
            r.accesspath = [a + room0 for a in r.accesspath]; r.layout = [l + lay0 for l in r.layout]
            if r.workshop is not None: r.workshop += room0
            rooms.append(r)
        # check_indexes
        for f in layout:
            if f and f.target is not None and f.target >= len(layout): raise BPError('invalid target')
        for r in rooms:
            if not r: continue
            if any(a >= len(rooms) for a in r.accesspath): raise BPError('invalid accesspath')
            if any(l >= len(layout) for l in r.layout): raise BPError('invalid layout')
            if r.workshop is not None and r.workshop >= len(rooms): raise BPError('invalid workshop')
        # compaction of skipped entries
        lmove, li = [], 0
        for f in layout:
            lmove.append(li)
            if f:
                li += 1
                if f.target is not None and not layout[f.target]: f.target = None
        rmove, ri = [], 0
        for r in rooms:
            rmove.append(ri)
            if r:
                ri += 1
                r.accesspath = [a for a in r.accesspath if rooms[a]]
                r.layout = [l for l in r.layout if layout[l]]
                if r.workshop is not None and not rooms[r.workshop]: r.workshop = None
        layout2 = [f for f in layout if f]; rooms2 = [r for r in rooms if r]
        for f in layout2:
            if f.target is not None: f.target = lmove[f.target]
        for r in rooms2:
            r.accesspath = [rmove[a] for a in r.accesspath]; r.layout = [lmove[l] for l in r.layout]
            if r.workshop is not None: r.workshop = rmove[r.workshop]
        used = set()
        for r in rooms2:
            for l in r.layout:
                if l in used: raise BPError('multiple uses of a single furniture')
                used.add(l)
        # drop unused furniture (warn() reports it first, like the C++ does)
        self.unused_furniture = [i for i in range(len(layout2)) if i not in used]
        keep = [i for i in range(len(layout2)) if i in used]
        remap = {old: new for new, old in enumerate(keep)}
        self.layout_full = layout2
        self.rooms = rooms2
        self.layout = layout2  # warn() runs on the un-pruned list
        self.warning = self.warn()
        self.layout = [layout2[i] for i in keep]
        for f in self.layout:
            if f.target is not None: f.target = remap.get(f.target)
        for r in self.rooms:
            r.layout = [remap[l] for l in r.layout]
        self.build_cache()

    def warn(self):
        for idx, r in enumerate(self.rooms):
            for fi in r.layout:
                if r.type == 'cistern': continue
                f = self.layout[fi]; p = add(r.min, f.pos)
                if p[0] > r.max[0] + 1: return 'room %d, furniture %d: furniture outside of east wall' % (idx, fi)
                if p[1] > r.max[1] + 1: return 'room %d, furniture %d: furniture outside of south wall' % (idx, fi)
                if p[0] < r.min[0] - 1: return 'room %d, furniture %d: furniture outside of west wall' % (idx, fi)
                if p[1] < r.min[1] - 1: return 'room %d, furniture %d: furniture outside of north wall' % (idx, fi)
        if self.unused_furniture:
            return 'furniture %d: not included in any room layout' % self.unused_furniture[0]
        door_at, near = False, 0
        for r in self.rooms:
            if r.outdoor or all(r.min[i] <= 0 <= r.max[i] for i in range(3)):
                door_at = True; break
            for fi in r.layout:
                f = self.layout[fi]
                if f.construction == 'Wall' or f.dig == 'No': continue
                p = add(f.pos, r.min)
                if p == (0, 0, 0): door_at = True; break
                if (r.min[0] == 1 or r.max[0] == -1) and p[0] == 0 and -1 <= p[1] <= 1 and p[2] == 0: near += 1; continue
                if (r.min[1] == 1 or r.max[1] == -1) and -1 <= p[0] <= 1 and p[1] == 0 and p[2] == 0: near += 1; continue
            if door_at or near >= 2: break
        if not door_at and near < 2:
            return 'room has no door at entrance'
        return None

    def build_cache(self):
        self.corridor, self.interior, self.no_room, self.no_corridor = set(), set(), set(), set()
        self.max_noblesuite = -1
        for r in self.rooms:
            self.max_noblesuite = max(self.max_noblesuite, r.noblesuite)
            holes = set()
            is_corr = r.type == 'corridor' and r.corridor_type == 'corridor'
            for fi in r.layout:
                f = self.layout[fi]; p = add(r.min, f.pos)
                if f.dig == 'No' or f.construction == 'Wall':
                    holes.add(p)
                elif is_corr:
                    if f.type != 'door': self.interior.add(p)
                    self.no_room.add(p)
                elif r.in_corridor or not r.require_walls or r.outdoor:
                    self.interior.add(p); self.no_room.add(p)
                else:
                    if f.type == 'door':
                        self.no_room.add(p)
                    else:
                        self.interior.add(p)
                        for dx in (-1, 0, 1):
                            for dy in (-1, 0, 1):
                                q = add(p, (dx, dy, 0)); self.no_corridor.add(q); self.no_room.add(q)
                if f.dig == 'Channel':
                    if add(f.pos, (0, 0, -1)) not in r.exits:
                        self.interior.add(add(p, (0, 0, -1)))
                        for dx in (-1, 0, 1):
                            for dy in (-1, 0, 1): self.no_room.add(add(p, (dx, dy, -1)))
                elif f.dig == 'Ramp':
                    self.interior.add(add(p, (0, 0, 1)))
                    for dx in (-1, 0, 1):
                        for dy in (-1, 0, 1): self.no_room.add(add(p, (dx, dy, 1)))
            for x in range(r.min[0], r.max[0] + 1):
                for y in range(r.min[1], r.max[1] + 1):
                    for z in range(r.min[2], r.max[2] + 1):
                        t = (x, y, z)
                        if t in holes: continue
                        if is_corr and r.min[2] == r.max[2]:
                            if not r.in_corridor:
                                self.corridor.add(t); self.no_corridor.add(t)
                            else:
                                self.interior.add(t); self.no_room.add(t)
                        elif r.in_corridor or not r.require_walls or r.outdoor:
                            self.interior.add(t); self.no_room.add(t)
                            if not r.in_corridor: self.no_corridor.add(t)
                        else:
                            self.interior.add(t)
                            for dx in (-1, 0, 1):
                                for dy in (-1, 0, 1):
                                    if sub(t, r.min) == sub(t, r.min) and add(sub(t, r.min), (dx, dy, 0)) not in r.exits:
                                        q = add(t, (dx, dy, 0)); self.no_room.add(q); self.no_corridor.add(q)

def load_room_file(path, enums, is_template):
    d = json.load(open(path, encoding='utf-8'))
    if not isinstance(d, dict): raise BPError('must be a JSON object')
    allowed = {'$schema', 'f', 'r'} | (set() if is_template else {'p', 'blacklist'})
    for k in d:
        if k not in allowed: raise BPError('unhandled property ' + k)
    fs, rs = [], []
    for fd in d.get('f', []):
        f = Furn(); f.apply(fd, enums, is_template); fs.append(f)
    for rd in d.get('r', []):
        r = Room(); r.apply(rd, enums, is_template); rs.append(r)
    if is_template:
        if not rs: raise BPError('template needs at least one room')
        return fs, rs
    ph = d.get('p', [])
    for p in ph:
        if not isinstance(p, dict): raise BPError('placeholders must be objects')
    return ph, fs, rs, set(d.get('blacklist', []))

def load_all(root, enums, errors):
    templates, instances = defaultdict(dict), defaultdict(dict)
    for sub_, store, is_t in (('templates', templates, True), ('instances', instances, False)):
        base = os.path.join(root, 'rooms', sub_)
        for typ in sorted(os.listdir(base)):
            if '.' in typ: continue
            for fn in sorted(os.listdir(os.path.join(base, typ))):
                if not fn.endswith('.json'): continue
                p = os.path.join(base, typ, fn)
                try:
                    store[typ][fn[:-5]] = load_room_file(p, enums, is_t)
                except (BPError, json.JSONDecodeError) as e:
                    errors.append('%s: %s' % (os.path.relpath(p, root), e))
    bps = defaultdict(list)
    for typ in sorted(set(templates) | set(instances)):
        if not templates[typ]: errors.append('%s: no templates' % typ)
        if not instances[typ]: errors.append('%s: no instances' % typ)
        for tn, t in sorted(templates[typ].items()):
            for iname, inst in sorted(instances[typ].items()):
                if tn in inst[3]: continue
                try:
                    bp = Blueprint(typ, tn, t, iname, inst[:3], enums)
                except BPError as e:
                    errors.append('%s/%s + %s: %s' % (typ, tn, iname, e)); continue
                if bp.warning:
                    errors.append('%s/%s + %s: %s' % (typ, tn, iname, bp.warning))
                bps[typ].append(bp)
    return bps

PLAN_KEYS = {'$schema', 'max_retries', 'max_failures', 'military_limit', 'start', 'outdoor', 'tags',
             'count_as', 'limits', 'instance_limits', 'variables', 'padding_x', 'padding_y',
             'priorities', 'stock_goals'}

def load_plans(root, errors):
    plans = {}
    base = os.path.join(root, 'plans')
    for fn in sorted(os.listdir(base)):
        if not fn.endswith('.json'): continue
        p = os.path.join(base, fn)
        try:
            d = json.load(open(p, encoding='utf-8'))
        except json.JSONDecodeError as e:
            errors.append('plans/%s: %s' % (fn, e)); continue
        for k in d:
            if k not in PLAN_KEYS: errors.append('plans/%s: unhandled property %s' % (fn, k))
        if 'start' not in d: errors.append('plans/%s: missing start' % fn)
        plans[fn[:-5]] = d
    return plans

def check_plan_refs(name, plan, bps, errors):
    tags = plan.get('tags', {})
    known = set(bps) | set(tags)
    def chk(ref, where):
        if ref not in known: errors.append('plans/%s: %s references unknown room/tag %r' % (name, where, ref))
    chk(plan['start'], 'start')
    for t, members in tags.items():
        for m in members: chk(m, 'tag ' + t)
    for o in plan.get('outdoor', []): chk(o, 'outdoor')
    for k in plan.get('limits', {}): chk(k, 'limits')
    for typ, il in plan.get('instance_limits', {}).items():
        chk(typ, 'instance_limits')
        names = {b.name for b in bps.get(typ, [])}
        for iname in il:
            if iname not in names: errors.append('plans/%s: instance_limits %s/%s has no such instance' % (name, typ, iname))
    for k in plan.get('count_as', {}):
        if k.count('/') != 2: errors.append('plans/%s: count_as %s needs two slashes' % (name, k))
    # exits used by rooms this plan can place must resolve to a room type or a tag of this plan
    reachable = {plan['start']} | set(plan.get('outdoor', []))
    expand = lambda s: {m for t in s for m in ([t] + tags.get(t, []))}
    seen, frontier = set(), expand(reachable)
    while frontier:
        typ = frontier.pop()
        if typ in seen: continue
        seen.add(typ)
        for bp in bps.get(typ, []):
            for r in bp.rooms:
                for ex in r.exits.values():
                    for tag in ex:
                        if tag not in known and not tag.startswith('_'):
                            errors.append('plans/%s: %s/%s exit references unknown %r' % (name, bp.type, bp.tmpl_name, tag))
                        frontier |= expand({tag}) - seen
    unreachable = [k for k in plan.get('limits', {}) if plan['limits'][k][0] > 0 and k not in seen]
    unreachable += [k for k in plan.get('instance_limits', {}) if k not in seen and any(v[0] > 0 for v in plan['instance_limits'][k].values())]
    for k in unreachable:
        errors.append('plans/%s: %s has a minimum but no exit can ever lead to it' % (name, k))
    return seen

# ---------------------------------------------------------------- simulation
class Sim:
    def __init__(self, plan, bps, rng, size=(192, 192, 80), surface=60):
        self.plan, self.bps, self.rng = plan, bps, rng
        self.X, self.Y, self.Z = size; self.S = surface
        self.tags = {k: set(v) for k, v in plan.get('tags', {}).items()}
        self.limits = plan.get('limits', {}); self.ilimits = plan.get('instance_limits', {})
        self.max_failures = plan.get('max_failures', 100)
        self.placed = []  # (bp, pos)
        self.corridor, self.interior, self.no_room, self.no_corridor = {}, {}, {}, {}
        self.connect = {}  # coord -> (placed idx, {tag})
        self.counts = defaultdict(int); self.icounts = defaultdict(lambda: defaultdict(int))

    def valid(self, c):
        return 0 <= c[0] < self.X and 0 <= c[1] < self.Y and 0 <= c[2] < self.Z

    def solid(self, c):
        return c[2] < self.S

    def can_add(self, bp, pos):
        for c in bp.no_room:
            if not self.valid(add(c, pos)): return 'out of bounds'
        for r in bp.rooms:
            mn, mx = add(r.min, pos), add(r.max, pos)
            if not self.valid(add(mn, (-2, -2, -1))) or not self.valid(add(mx, (2, 2, 1))): return 'out of bounds'
            if r.outdoor:
                for z in range(mn[2], mx[2] + 1):
                    if z < self.S: return 'underground'
                    if r.require_floor and z != self.S: return 'not on the ground'
            else:
                for fi in r.layout:
                    f = bp.layout[fi]
                    if f.dig not in ('No', 'Default', 'UpStair', 'Ramp'):
                        if not self.solid(add(add(mn, f.pos), (0, 0, -1))): return 'above cavern/air'
                for z in range(mn[2], mx[2] + 1):
                    if not self.solid((0, 0, z)): return 'above ground'
        return None

    def add(self, bp, pos, parent=None):
        sh = lambda s: {add(c, pos) for c in s}
        corr, inter, nor, noc = sh(bp.corridor), sh(bp.interior), sh(bp.no_room), sh(bp.no_corridor)
        for c in corr:
            if c in self.no_corridor: return 'corridor hits no_corridor'
        for c in inter:
            if c in self.no_room: return 'interior hits no_room'
        for c in noc:
            if c in self.corridor: return 'no_corridor hits corridor'
        for c in nor:
            if c in self.interior: return 'no_room hits interior'
        idx = len(self.placed)
        self.placed.append((bp, pos, parent))
        for r in bp.rooms:
            for e, tags in r.exits.items():
                c = add(add(r.min, pos), e)
                if c not in self.no_room and tags:
                    self.connect[c] = (idx, set(tags))
        label = '%s/%s/%s' % (bp.type, bp.tmpl_name, bp.name)
        for c in corr: self.corridor[c] = label
        for c in inter: self.interior[c] = label
        for c in nor:
            self.no_room[c] = label; self.connect.pop(c, None)
        for c in noc: self.no_corridor[c] = label
        return None

    def count(self, bp):
        ca = self.plan.get('count_as', {}).get('%s/%s/%s' % (bp.type, bp.tmpl_name, bp.name))
        if ca:
            for k, v in ca.items():
                if '/' in k:
                    a, b = k.split('/', 1); self.icounts[a][b] += v
                else:
                    self.counts[k] += v
        self.counts[bp.type] += 1; self.icounts[bp.type][bp.name] += 1

    def available(self, base_tags, check):
        tags = set()
        for t in base_tags:
            tags.add(t); tags |= self.tags.get(t, set())
        out = []
        for typ, lst in self.bps.items():
            if typ not in tags: continue
            tl = self.limits.get(typ)
            if tl and self.counts[typ] >= tl[1]: continue
            il = self.ilimits.get(typ)
            if tl is None and il is None: continue
            il = il or {}
            for bp in lst:
                lim = il.get(bp.name)
                if tl is None and lim is None: continue
                if lim and self.icounts[typ][bp.name] >= lim[1]: continue
                if check(bp): out.append(bp)
        return out

    def surface(self, x, y):
        return (x, y, self.S)

    def try_start(self, bp):
        px, py = self.plan.get('padding_x', [0, 0]), self.plan.get('padding_y', [0, 0])
        mnx, mxx, mny, mxy = px[0], px[1], py[0], py[1]
        for c in bp.no_room:
            mnx, mxx, mny, mxy = min(mnx, c[0]), max(mxx, c[0]), min(mny, c[1]), max(mxy, c[1])
        x = self.rng.randint(2 - mnx, self.X - 3 - mxx); y = self.rng.randint(2 - mny, self.Y - 3 - mxy)
        return self.try_at(bp, self.surface(x, y))

    def try_outdoor(self, bp):
        mnx = mxx = mny = mxy = 0
        for c in bp.no_room:
            mnx, mxx, mny, mxy = min(mnx, c[0]), max(mxx, c[0]), min(mny, c[1]), max(mxy, c[1])
        x = self.rng.randint(2 - mnx, self.X - 3 - mxx); y = self.rng.randint(2 - mny, self.Y - 3 - mxy)
        return self.try_at(bp, self.surface(x, y))

    def try_at(self, bp, pos, parent=None):
        if self.can_add(bp, pos): return False
        if self.add(bp, pos, parent): return False
        self.count(bp); return True

    def try_connect(self, bp):
        tags = {bp.type} | {t for t, m in self.tags.items() if bp.type in m}
        conns = [(c, v[0]) for c, v in self.connect.items() if v[1] & tags]
        c, parent = self.rng.choice(conns)
        return self.try_at(bp, c, parent)

    def place(self, find, try_add):
        while True:
            avail = find()
            if not avail: break
            self.rng.shuffle(avail)
            stop, failures = False, 0
            while not stop:
                for bp in avail:
                    if not try_add(bp):
                        failures += 1
                        if failures >= self.max_failures: stop = True; break
                    else:
                        stop = True; break
            if failures >= self.max_failures: break

    def unmet(self):
        out = []
        for k, (lo, hi) in self.limits.items():
            if self.counts.get(k, 0) < lo: out.append('%s: have %d want %d-%d' % (k, self.counts.get(k, 0), lo, hi))
        for typ, il in self.ilimits.items():
            for n, (lo, hi) in il.items():
                if self.icounts[typ].get(n, 0) < lo: out.append('%s/%s: have %d want %d-%d' % (typ, n, self.icounts[typ].get(n, 0), lo, hi))
        return out

    def build(self):
        has_out = lambda bp: any(r.outdoor for r in bp.rooms)
        self.place(lambda: self.available({self.plan['start']}, has_out), self.try_start)
        if not self.placed: return ['no start room placed']
        self.place(lambda: self.available(set(self.plan.get('outdoor', [])), has_out), self.try_outdoor)
        def find_conn():
            t = set()
            for c, v in self.connect.items(): t |= v[1]
            return self.available(t, lambda bp: True)
        self.place(find_conn, self.try_connect)
        return self.unmet()

    def render(self, out):
        """ASCII map of every z-level that has rooms. Letters per room type."""
        sym = {'corridor': '.', 'stockpile': 's', 'workshop': 'W', 'furnace': 'F', 'bedroom': 'b',
               'nobleroom': 'N', 'location': 'L', 'infirmary': '+', 'jail': 'J', 'barracks': 'B',
               'cemetery': 'c', 'farmplot': 'f', 'dininghall': 'D', 'tradedepot': 'T',
               'garbagedump': 'g', 'outpost': 'o', 'pitcage': 'p', 'releasecage': 'r', 'pasture': 'P',
               'cistern': '~', 'windmill': 'm', 'pond': 'w'}
        tiles = {}
        for bp, pos, _ in self.placed:
            for r in bp.rooms:
                ch = sym.get(r.type, '?')
                if r.type == 'location': ch = {'tavern': 'T', 'temple': 'X', 'library': 'Y', 'guildhall': 'G'}.get(r.attrs.get('location_type'), 'L')
                if r.type == 'corridor' and r.attrs.get('comment') == 'staircase': ch = '%'
                mn, mx = add(r.min, pos), add(r.max, pos)
                for x in range(mn[0], mx[0] + 1):
                    for y in range(mn[1], mx[1] + 1):
                        for z in range(mn[2], mx[2] + 1):
                            tiles.setdefault((x, y, z), ch)
                for fi in r.layout:
                    f = bp.layout[fi]; p = add(add(r.min, f.pos), pos)
                    if f.type == 'door' and p not in tiles: tiles[p] = '|'
        if not tiles: return
        zs = sorted({t[2] for t in tiles}, reverse=True)
        xs = [t[0] for t in tiles]; ys = [t[1] for t in tiles]
        for z in zs:
            out.write('z = %d (%+d from surface)\n' % (z, z - self.S))
            for y in range(min(ys), max(ys) + 1):
                out.write(''.join(tiles.get((x, y, z), ' ') for x in range(min(xs), max(xs) + 1)).rstrip() + '\n')
            out.write('\n')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=ROOT)
    ap.add_argument('--plan', default=None)
    ap.add_argument('--sims', type=int, default=20)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--map', default=None, help='write an ASCII map of the first successful sim')
    a = ap.parse_args()
    enums = load_enums(a.root)
    errors = []
    bps = load_all(a.root, enums, errors)
    plans = load_plans(a.root, errors)
    for n, p in plans.items():
        if 'start' in p: check_plan_refs(n, p, bps, errors)
    print('room types: %d, blueprints: %d, plans: %s' % (len(bps), sum(len(v) for v in bps.values()), ', '.join(plans)))
    for e in errors: print('ERROR', e)
    rc = 1 if errors else 0
    for n, p in plans.items():
        if a.plan and n != a.plan: continue
        ok, fails, wrote = 0, defaultdict(int), False
        retries = p.get('max_retries', 25)
        for i in range(a.sims):
            rng = random.Random(a.seed * 1000 + i)
            unmet = None
            for attempt in range(retries):
                s = Sim(p, bps, rng)
                unmet = s.build()
                if not unmet: break
            if not unmet:
                ok += 1
                if a.map and not wrote:
                    with open(a.map, 'w', encoding='utf-8') as f:
                        f.write('plan %s, sim %d, %d rooms placed\n' % (n, i, len(s.placed)))
                        for k in sorted(s.counts): f.write('  %s: %d\n' % (k, s.counts[k]))
                        f.write('\n'); s.render(f)
                    wrote = True
            else:
                for u in unmet: fails[u.split(':')[0]] += 1
        print('plan %s: %d/%d simulated embarks met all minimums (max_retries=%d)' % (n, ok, a.sims, retries))
        for k, v in sorted(fails.items(), key=lambda kv: -kv[1])[:15]:
            print('   unmet in %d sims: %s' % (v, k))
        if ok == 0: rc = 1
    sys.exit(rc)

if __name__ == '__main__':
    main()
