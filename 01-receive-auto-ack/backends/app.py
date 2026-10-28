"""Stand-in patient registry for the auto-ACK sample (Python standard library only).

  POST /adt              JSON summary of an ADT message, from the workflow -> 201
  GET  /received         everything received so far, in order
  POST /control/reset    forget everything

Usage: python app.py [--port 8301]
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
received = []


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/received":
            with lock:
                return self._send(200, {"adt": received})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            if self.path == "/control/reset":
                received.clear()
                return self._send(200, {"reset": True})
            if self.path == "/adt":
                try:
                    item = json.loads(body)
                except ValueError:
                    return self._send(400, {"error": "body is not JSON"})
                received.append(item)
                return self._send(201, {"stored": item.get("controlId")})
        self._send(404, {"error": "not found"})

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8301)
    args = parser.parse_args()
    print(f"Patient registry on http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
