"""Dwarf pictures for the broadsheet's On Camera card (stdlib only).

portrait_png(unit_id) asks the game for the unit's sprite (dfai-portrait.lua),
crops it to the figure, scales it up with hard pixel edges and returns PNG
bytes, or None when DF hasn't drawn that unit yet. Results are cached briefly.
"""
import os
import struct
import tempfile
import threading
import time
import zlib

import dfai_supervisor as sup

CACHE_S = 60
TARGET = 192          # about this many pixels on the long side
_cache = {}
_lock = threading.Lock()


def _png(w, h, rows):
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = b"".join(b"\x00" + r for r in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def _card(w, h, data):
    """Crop to the non-transparent pixels, pad square, scale up by an integer."""
    xs, ys = [], []
    for y in range(h):
        row = data[y * w * 4:(y + 1) * w * 4]
        for x in range(w):
            if row[x * 4 + 3]:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    cw, ch = x1 - x0, y1 - y0
    side = max(cw, ch) + 2
    k = max(1, -(-TARGET // side))   # round up: crisp 2x for the 96 px portrait
    ox, oy = (side - cw) // 2, side - ch - 1       # centred, standing on the bottom
    blank = b"\x00\x00\x00\x00"
    rows = []
    for sy in range(side):
        y = sy - oy + y0
        if y0 <= y < y1:
            src = data[y * w * 4:(y + 1) * w * 4]
            line = bytearray()
            for sx in range(side):
                x = sx - ox + x0
                px = src[x * 4:x * 4 + 4] if x0 <= x < x1 else blank
                line += px * k
        else:
            line = bytearray(blank * side * k)
        rows.extend([bytes(line)] * k)
    return _png(side * k, side * k, rows)


def portrait_png(unit_id):
    unit_id = int(unit_id)
    now = time.time()
    with _lock:
        hit = _cache.get(unit_id)
        if hit and now - hit[0] < CACHE_S:
            return hit[1]
    fd, path = tempfile.mkstemp(suffix=".rgba")
    os.close(fd)
    png = None
    try:
        out = sup.dfhack("dfai-portrait", str(unit_id), path.replace("\\", "/")) or ""
        if "OK " in out:
            with open(path, "rb") as f:
                hdr = f.readline().split()
                w, h = int(hdr[1]), int(hdr[2])
                data = f.read(w * h * 4)
            png = _card(w, h, data)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    with _lock:
        _cache[unit_id] = (now, png)
        for k in [k for k, v in _cache.items() if now - v[0] > 10 * CACHE_S]:
            del _cache[k]
    return png


if __name__ == "__main__":
    import sys
    png = portrait_png(sys.argv[1])
    print("none" if png is None else f"{len(png)} bytes")
    if png and len(sys.argv) > 2:
        open(sys.argv[2], "wb").write(png)
