"""Stand-ins for the TLS sample (Python standard library only).

Recorder (HTTP, --port)
  POST /received-messages   what the receiving workflow got (control ID, TLS protocol) -> 201
Lab (MLLP over TLS, --mllp-port)
  Takes orders over TLS 1.2 or 1.3 and answers AA. It presents --cert/--key, or --impostor-cert/--impostor-key
  while switched to the impostor certificate.
Demo
  GET  /received            what the workflow recorded, and the orders the lab got (with the TLS version)
  POST /control/impostor    the lab presents the impostor certificate from now on
  POST /control/genuine     the lab presents its own certificate again
  POST /control/reset       forget everything, genuine certificate

Usage: python app.py --port 8304 --mllp-port 2314 --cert lab.pem --key lab.key --impostor-cert impostor.pem --impostor-key impostor.key
"""

import argparse
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "shared", "tools"))
import mllp  # noqa: E402

lock = threading.Lock()
state = {}
contexts = {}
lab = None


def server_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


def reset():
    state.update(messages=[], orders=[], certificate="genuine")
    if lab:
        lab.ssl_context = contexts["genuine"]


def on_order(message, peer):
    header = mllp.msh(message)
    with lock:
        state["orders"].append({"controlId": header.get("controlId"), "certificate": state["certificate"]})
    return mllp.make_ack(message, "AA", "Order accepted", sending_app="LIS", sending_facility="CEDAR_LAB")


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
                return self._send(200, {"messages": state["messages"], "orders": state["orders"]})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            if self.path == "/received-messages":
                try:
                    state["messages"].append(json.loads(body))
                except ValueError:
                    return self._send(400, {"error": "body is not JSON"})
                return self._send(201, {"stored": True})
            if self.path in ("/control/impostor", "/control/genuine"):
                state["certificate"] = self.path.rsplit("/", 1)[1]
                lab.ssl_context = contexts[state["certificate"]]
                return self._send(200, {"certificate": state["certificate"]})
            if self.path == "/control/reset":
                reset()
                return self._send(200, {"reset": True})
        self._send(404, {"error": "not found"})

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8304)
    parser.add_argument("--mllp-port", type=int, default=2314)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--impostor-cert", required=True)
    parser.add_argument("--impostor-key", required=True)
    args = parser.parse_args()
    contexts["genuine"] = server_context(args.cert, args.key)
    contexts["impostor"] = server_context(args.impostor_cert, args.impostor_key)
    lab = mllp.MllpServer(args.mllp_port, on_order, ssl_context=contexts["genuine"], name="lab").start()
    reset()
    print(f"Recorder on http://127.0.0.1:{args.port}, lab on MLLP over TLS port {args.mllp_port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
