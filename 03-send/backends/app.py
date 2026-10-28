"""Stand-in laboratory information system for the send sample (Python standard library only).

Lab (MLLP, --mllp-port)
  Takes ORM^O01 orders. Answers AA, or AE when OBR-4 names a test the lab doesn't do (it does GLU, K, NA, CBC).
  While switched silent it reads the message and answers nothing.
Demo (HTTP, --port)
  GET  /received          the orders received so far, with the ACK code returned
  POST /control/silent    read messages but never answer
  POST /control/normal    answer again
  POST /control/reset     forget everything, answer again

Usage: python app.py [--port 8303] [--mllp-port 2303]
"""

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "shared", "tools"))
import mllp  # noqa: E402

TESTS = {"GLU", "K", "NA", "CBC"}

lock = threading.Lock()
state = {}


def reset():
    state.update(silent=False, orders=[], connections=set())


def on_order(message, peer):
    obr = next((s for s in mllp.segments(message) if s.startswith("OBR|")), "")
    test = mllp.field(obr, 4).split("^")[0]
    header = mllp.msh(message)
    with lock:
        state["connections"].add(f"{peer[0]}:{peer[1]}")
        if state["silent"]:
            state["orders"].append({"controlId": header.get("controlId"), "test": test, "ackCode": None, "peer": f"{peer[0]}:{peer[1]}"})
            return None
        code, text, error = ("AA", "Order accepted", None) if test in TESTS else ("AE", f"Unknown test code {test}", "207^Application internal error^HL70357")
        state["orders"].append({"controlId": header.get("controlId"), "test": test, "ackCode": code, "peer": f"{peer[0]}:{peer[1]}"})
    return mllp.make_ack(message, code, text, sending_app="LIS", sending_facility="CEDAR_LAB", error=error)


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
                return self._send(200, {"orders": state["orders"], "connections": sorted(state["connections"])})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        with lock:
            if self.path == "/control/silent":
                state["silent"] = True
            elif self.path == "/control/normal":
                state["silent"] = False
            elif self.path == "/control/reset":
                reset()
            else:
                return self._send(404, {"error": "not found"})
            return self._send(200, {"silent": state["silent"]})

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8303)
    parser.add_argument("--mllp-port", type=int, default=2303)
    args = parser.parse_args()
    reset()
    mllp.MllpServer(args.mllp_port, on_order, name="lab").start()
    print(f"Lab on MLLP port {args.mllp_port}, control on http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
