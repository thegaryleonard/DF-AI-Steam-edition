#!/usr/bin/env python3
"""Generate the underground execution pit (room type generic01_execution_pit).

It replaces the old outdoor "pitting tower" (a one-tile stair spire ten levels
up, a cage platform on top, and an open-air garbage pit with a walk-in ramp at
its bottom: refuse falling on dwarves who walked in killed ten of them). The
pit does the same two jobs - caged hostiles are dropped to their death, refuse
goes down a hole - but it is cut into rock off an ordinary corridor, and its
bottom can never be walked to.

Authored facing north (door in the parent corridor's wall at the origin):

    z0 (fort level)            z-1 .. z-10           z-11 (bottom)
        Q Q Q   y=-1                .                    .
        c H c   y=-2                P1                   F
        c S c   y=-3                S (up/down stair)    S (up stair)
        c D c   y=-4                P2                   F
          +     y= 0  door

  Q  'pitting queue' cage stockpile; every tile is next to the hatch
  H  pitcage zone + forbidden hatch over shaft P1 (the drop: 11 levels)
  D  garbage dump zone over shaft P2 (refuse thrown down the hole)
  S  access stair the miners use to dig P1/P2 as plain floors on every level
  c  'pit landing' corridor (dug at z0; H, S and D start as its floor)

Digging (df-ai C++, corridor_type pitshaft, Plan::try_digpitshaft):
  1. the shaft room is dug like any room: S becomes a stair column, P1/P2
     become floors on every level, mined sideways from S;
  2. then every P1/P2 floor except the bottom is channeled (from S); the rock
     below is already dug, so no ramps appear;
  3. then the top of S is channeled and a floor is constructed over it: the
     whole shaft is cut off from the fort;
  4. only then may H and D be channeled (pit_channel_blocked), the hatch built
     and the two zones made.

Run from the repo root:  python tools/gen_execution_pit.py && python tools/gen_tlg01.py
"""
import os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_tlg01 import T, ROT, SCHEMA_I, write_json  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TYPE = 'generic01_execution_pit'
DEPTH = 11  # bottom floor is 11 levels under the hatch


def pit():
    t = T()
    q = t.room('queue', -1, -1, 1, -1, 0, type='stockpile', stockpile_type='animals', comment='pitting queue',
               level=0, stock_specific1=True, stock_specific2=True)
    q.f(0, 0, 0, type='door')
    land = t.room('landing', -1, -4, 1, -2, 0, type='corridor', corridor_type='corridor', comment='pit landing')
    land.f(0, -3, 0, dig='DownStair')
    land.access = ['queue']
    cage = t.room('cage', 0, -2, 0, -2, 0, type='pitcage', comment='execution pit')
    cage.f(0, -2, 0, type='hatch', dig='Channel')
    dump = t.room('dump', 0, -4, 0, -4, 0, type='garbagedump', comment='refuse chute')
    dump.f(0, -4, 0, dig='Channel')
    shaft = t.room('shaft', 0, -4, 0, -2, -DEPTH, -1, type='corridor', corridor_type='pitshaft', comment='pit shaft')
    for z in range(-1, -DEPTH, -1):
        shaft.f(0, -3, z, dig='UpDownStair')
    shaft.f(0, -3, -DEPTH, dig='UpStair')
    shaft.access = ['landing']
    cage.access = ['landing', 'shaft']
    dump.access = ['landing', 'shaft']
    return t


def main():
    rooms = os.path.join(ROOT, 'rooms')
    for sub in ('templates', 'instances'):
        for old in ('generic01_pitting_tower', TYPE):
            d = os.path.join(rooms, sub, old)
            if os.path.isdir(d):
                shutil.rmtree(d)
    t = pit()
    for d in ROT:
        write_json(os.path.join(rooms, 'templates', TYPE, d + '.json'), t.emit(d))
    write_json(os.path.join(rooms, 'instances', TYPE, 'generic.json'), {'$schema': SCHEMA_I, 'p': []})
    print('generated', TYPE)


if __name__ == '__main__':
    main()
