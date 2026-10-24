"""Read-only LAN mirror of the broadsheet (overlay.py on 127.0.0.1:8765).

Usage: python -u lan_proxy.py [port]   (default 8780)
Anyone on the home network opens http://<this PC's LAN IP>:8780/ . GET requests
are forwarded to the local overlay; POSTs (the paper's "already printed" memory)
are answered with 204 and NOT forwarded, so extra readers don't change what the
stream's copy prints.
"""
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8765"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8780


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with urllib.request.urlopen(UPSTREAM + self.path, timeout=30) as r:
                body = r.read()
                self.send_response(r.status)
                self.send_header("Content-Type", r.headers.get("Content-Type", "application/octet-stream"))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
        except Exception:
            self.send_response(502)
            self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
