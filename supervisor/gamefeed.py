"""Game feed + one-page stream view.

Serves the Dwarf Fortress window as a live MJPEG feed and a 1920x1080 page
that shows the game next to the Sentinel (the Herald from overlay.py), so
the whole stream is one browser page / one OBS Browser Source.

    python3 supervisor/gamefeed.py [--port 8766] [--fps 10] [--herald http://localhost:8765/]

    http://localhost:8766/            the combined stream page
    http://localhost:8766/game.mjpg   the game window alone (MJPEG)
    http://localhost:8766/game.jpg    one frame

The window is captured with PrintWindow, so it works while other windows
cover the game (not while it is minimized).
"""
import argparse
import ctypes
import io
import threading
import time
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
ctypes.windll.shcore.SetProcessDpiAwareness(2)   # real pixels, not scaled

PW_RENDERFULLCONTENT = 2
SRCCOPY = 0x00CC0020


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


def find_window():
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        n = user32.GetWindowTextLengthW(hwnd)
        if n and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            cls = ctypes.create_unicode_buffer(64)
            user32.GetClassNameW(hwnd, cls, 64)
            if buf.value == "Dwarf Fortress" and cls.value == "SDL_app":
                found.append(hwnd)
        return True

    user32.EnumWindows(cb, 0)
    return found[0] if found else None


def grab(hwnd):
    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    w, h = rect.right, rect.bottom
    if w <= 0 or h <= 0:
        return None
    hdc = user32.GetDC(hwnd)
    mem = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(mem, bmp)
    ok = user32.PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT | 1)   # 1 = client area only
    bi = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bi), 0)
    gdi32.SelectObject(mem, old)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(hwnd, hdc)
    if not ok:
        return None
    return Image.frombuffer("RGB", (w, h), buf, "raw", "BGRX", 0, 1)


class Feed:
    """One capture thread shared by every viewer."""

    def __init__(self, fps):
        self.interval = 1.0 / fps
        self.frame = None          # latest JPEG bytes
        self.seq = 0
        self.cond = threading.Condition()
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        hwnd = None
        while True:
            t0 = time.time()
            try:
                if not hwnd or not user32.IsWindow(hwnd):
                    hwnd = find_window()
                img = grab(hwnd) if hwnd else None
                if img is not None:
                    out = io.BytesIO()
                    img.save(out, "JPEG", quality=80)
                    with self.cond:
                        self.frame = out.getvalue()
                        self.seq += 1
                        self.cond.notify_all()
            except Exception:
                hwnd = None
            time.sleep(max(0.0, self.interval - (time.time() - t0)))

    def wait(self, seq, timeout=5):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != seq, timeout)
            return self.seq, self.frame


STREAM_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Dwarf Fortress - live</title>
<style>
  html, body { margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: #1b1610; }
  #game { position: absolute; left: 0; top: 0; width: 1420px; height: 1080px; object-fit: contain; background: #000; }
  #paper { position: absolute; left: 1420px; top: 0; width: 500px; height: 1080px; border: 0; }
  /* the way to the Overseer's Desk: invisible until the mouse finds the corner,
     never shown inside OBS or off this PC (the desk only answers localhost) */
  #desk { position: absolute; left: 0; bottom: 0; padding: 10px 14px; font: bold 14px Georgia, serif;
          color: #f7f1e1; background: rgba(29, 26, 20, .85); text-decoration: none; opacity: 0; transition: opacity .2s; display: none; }
  #desk:hover { opacity: 1; }
</style></head>
<body>
  <img id="game" src="/game.mjpg" alt="">
  <iframe id="paper" src="__HERALD__"></iframe>
  <a id="desk" href="http://localhost:8767/">The Overseer's Desk &rarr;</a>
  <script>
    if (!window.obsstudio && ['localhost', '127.0.0.1'].includes(location.hostname)) document.getElementById('desk').style.display = 'block';
  </script>
</body></html>
"""


def make_handler(feed, herald):
    page = STREAM_PAGE.replace("__HERALD__", herald).encode()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/stream.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)
            elif path == "/game.jpg":
                _, frame = feed.wait(-1, 0)
                if not frame:
                    self.send_error(503, "no game window")
                    return
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(frame)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(frame)
            elif path == "/game.mjpg":
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                seq = -1
                try:
                    while True:
                        seq, frame = feed.wait(seq)
                        if not frame:
                            continue
                        self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(frame))
                        self.wfile.write(frame + b"\r\n")
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
            else:
                self.send_error(404)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--herald", default="http://localhost:8765/")
    a = ap.parse_args()
    feed = Feed(a.fps)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(feed, a.herald))
    print(f"stream page on http://localhost:{a.port}/", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
