#!/usr/bin/env python3
"""Move a running fort's outdoor pitting tower underground (edit df-ai-plan.dat).

Blueprints only apply to new embarks; a running fort keeps its plan in
save/<world>/df-ai-plan.dat. This rewrites the old outdoor pitting-tower rooms
(garbagedump, 'garbage pit', 'garbage pit (underground)', 'pitting tower',
'pitting queue', pitcage) in place as the underground execution pit from
tools/gen_execution_pit.py, attached at a door tile you pick (survey it first:
solid rock 11+ levels down, no planned rooms; see references/blueprints.md).

Room indices are kept (old rooms are rewritten, not deleted), so accesspaths,
tasks and furniture of every other room stay valid. The old walk-in ramp's
furniture becomes dig 'No' so df-ai never re-digs it after it is walled up.

Only run it while df-ai is UNLOADED (unload persists the plan; load reads it):
    dfhack-run unload df-ai
    python tools/migrate_execution_pit.py <plan.dat> <x> <y> <z> <north|east|south|west>
    dfhack-run load df-ai && dfhack-run enable df-ai
In-game, also delete the old zones/buildings (pitcage zone, dump zone, hive)
and wall up the old ramp; the script prints their ids.
"""
import json, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_execution_pit import pit  # noqa: E402

ROLE_OF_TEMPLATE_ROOM = ['queue', 'landing', 'cage', 'dump', 'shaft']


def find_old(rooms):
    old = {}
    for i, r in enumerate(rooms):
        c = r.get('comment', '')
        if r['type'] == 'pitcage' and r.get('outdoor'):
            old['cage'] = i
        elif r['type'] == 'garbagedump' and r.get('outdoor'):
            old['dump'] = i
        elif r['type'] == 'stockpile' and c == 'pitting queue':
            old['queue'] = i
        elif r['type'] == 'corridor' and c == 'pitting tower':
            old['landing'] = i
        elif r['type'] == 'corridor' and c == 'garbage pit':
            old['shaft'] = i
        elif r['type'] == 'corridor' and c == 'garbage pit (underground)':
            old['ramp'] = i
    return old


def main():
    path, x, y, z, d = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    plan = json.load(open(path, encoding='utf-8'))
    rooms, furn = plan['r'], plan['f']
    old = find_old(rooms)
    missing = [k for k in ROLE_OF_TEMPLATE_ROOM if k not in old]
    if missing:
        sys.exit('old pitting tower rooms not found: %s (found %s)' % (missing, old))
    shutil.copy(path, path + '.before-execution-pit')

    print('old buildings/zones to remove in-game:')
    for k in ('cage', 'dump', 'queue', 'landing', 'shaft'):
        r = rooms[old[k]]
        ids = [r['bld_id']] + [furn[f]['bld_id'] for f in r.get('layout', [])]
        ids = [b for b in ids if b != -1]
        if ids:
            print('  %s (room %d): %s' % (k, old[k], ids))

    tmpl = pit().emit(d)
    proto = dict(furn[0])
    for role, tr in zip(ROLE_OF_TEMPLATE_ROOM, tmpl['r']):
        i = old[role]
        r = rooms[i]
        mn = [tr['min'][0] + x, tr['min'][1] + y, tr['min'][2] + z]
        mx = [tr['max'][0] + x, tr['max'][1] + y, tr['max'][2] + z]
        layout = []
        for fi in tr.get('layout', []):
            tf = tmpl['f'][fi]
            f = dict(proto)
            f.update(type=tf.get('type', 'none'), construction=tf.get('construction', 'NONE'),
                     dig=tf.get('dig', 'Default'), x=tf['x'], y=tf['y'], z=tf['z'], bld_id=-1,
                     has_users=0, ignore=False, internal=False, makeroom=False, users=[])
            f.pop('target', None)
            f.pop('comment', None)
            layout.append(len(furn))
            furn.append(f)
        r.update(min=mn, max=mx, layout=layout, status='plan', bld_id=-1, outdoor=False,
                 furnished=False, channeled=False, queue_dig=False, users=[],
                 comment=tr.get('comment', ''),
                 accesspath=[old[ROLE_OF_TEMPLATE_ROOM[a]] for a in tr.get('accesspath', [])])
        for k in ('corridor_type', 'stockpile_type', 'level', 'stock_specific1', 'stock_specific2'):
            if k in tr:
                r[k] = tr[k]
        print('room %d -> %s %s..%s' % (i, r['comment'], mn, mx))

    # the old walk-in pit under the surface dump: never dig its ramp again
    if 'ramp' in old:
        r = rooms[old['ramp']]
        for fi in r.get('layout', []):
            if furn[fi]['dig'] == 'Ramp':
                furn[fi]['dig'] = 'No'
                furn[fi]['construction'] = 'NONE'
        r['accesspath'] = []
        r['comment'] = 'garbage pit (underground, sealed)'

    moved = set(old.values())
    plan['t'] = [t for t in plan['t'] if t.get('r') not in moved]
    plan['t'].append({'t': 'want_dig', 'r': old['cage']})
    plan['t'].append({'t': 'want_dig', 'r': old['dump']})
    json.dump(plan, open(path, 'w', encoding='utf-8'))
    print('wrote', path, '(backup: .before-execution-pit)')


if __name__ == '__main__':
    main()
