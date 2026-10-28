"""Stand-in clinical data repository for the codec sample (Python standard library only).

  POST /messages         {"controlId", "messageType", "decoded"}: the codec's JSON form of a message -> 201
                         503 while switched down
  GET  /received         everything stored so far
  POST /control/down     answer 503 from now on
  POST /control/up       back to normal
  POST /control/reset    forget everything, back to normal

Usage: python app.py [--port 8305]
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
state = {}


def reset():
    state.update(up=True, messages=[])


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
                return self._send(200, {"messages": state["messages"]})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            if self.path == "/control/down":
                state["up"] = False
                return self._send(200, {"repository": "down"})
            if self.path == "/control/up":
                state["up"] = True
                return self._send(200, {"repository": "up"})
            if self.path == "/control/reset":
                reset()
                return self._send(200, {"reset": True})
            if self.path == "/messages":
                if not state["up"]:
                    return self._send(503, {"error": "repository is down for maintenance"})
                try:
                    item = json.loads(body)
                except ValueError:
                    return self._send(400, {"error": "body is not JSON"})
                state["messages"].append(item)
                return self._send(201, {"stored": item.get("controlId")})
        self._send(404, {"error": "not found"})

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8305)
    args = parser.parse_args()
    reset()
    print(f"Clinical data repository on http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
