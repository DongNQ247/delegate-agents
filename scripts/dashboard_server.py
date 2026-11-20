"""Serve only the files dashboard.html fetches, only to localhost Host headers.
usage: python3 dashboard_server.py <port> <dir>"""
import http.server, os, re, sys, urllib.parse

ALLOWED = re.compile(r"(dashboard\.html|status\.jsonl|quota\.json|[A-Za-z0-9_-][A-Za-z0-9._-]*\.events\.jsonl)")
TYPES = {".html": "text/html; charset=utf-8", ".json": "application/json"}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if host not in ("localhost", "127.0.0.1"):  # blocks DNS rebinding
            return self.send_error(403)
        name = urllib.parse.urlsplit(self.path).path.lstrip("/")
        if not ALLOWED.fullmatch(name):
            return self.send_error(404)
        try:
            with open(os.path.join(sys.argv[2], name), "rb") as f:
                body = f.read()
        except OSError:
            return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(name)[1], "text/plain; charset=utf-8"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
