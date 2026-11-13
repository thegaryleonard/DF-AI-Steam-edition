"""After aiscan-designs: export every dumped cluster as a quickfort blueprint (exact replay) and grab work orders."""
import json, subprocess, sys, os, glob, shutil
DF = r"C:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress"
OUT = os.environ.get("SAVESCAN_OUT", os.path.join(os.environ.get("TMPDIR") or os.environ.get("TEMP", "."), "savescan", "out"))
R = os.path.join(DF, 'hack', 'dfhack-run.exe')
import re
name = sys.argv[1].replace('\r', '').replace('\n', '').strip()
d = json.load(open(os.path.join(OUT, name + '.json'), encoding='utf-8'))
os.makedirs(os.path.join(OUT, 'bp'), exist_ok=True)
for c in d['clusters']:
    o, s = c['origin'], c['size']
    bp = 'scan_%s_c%d' % (name, c['id'])
    top = o['z'] + s['z'] - 1
    r = subprocess.run([R, 'blueprint', str(s['x']), str(s['y']), str(-s['z']), bp,
                        '--cursor', '%d,%d,%d' % (o['x'], o['y'], top)], cwd=DF, capture_output=True, text=True)
    print(bp, r.stdout.strip()[-200:], r.stderr.strip()[-200:])
for f in glob.glob(os.path.join(DF, 'dfhack-config', 'blueprints', 'scan_%s_*' % name)):
    shutil.move(f, os.path.join(OUT, 'bp', os.path.basename(f)))
r = subprocess.run([R, 'orders', 'export', 'scan_' + name], cwd=DF, capture_output=True, text=True)
src = os.path.join(DF, 'dfhack-config', 'orders', 'scan_%s.json' % name)
if os.path.exists(src):
    shutil.move(src, os.path.join(OUT, 'orders_%s.json' % name))
    print('orders exported')
else:
    print('orders export failed', r.stdout, r.stderr)
