"""Stand-in EHR and lab for the workflow-ACK sample (Python standard library only).

EHR (HTTP)
  POST /patients         {"controlId", "messageType", "message"}: an ADT message
                         201 {"patientKey": "EHR-000001"}; 422 {"error": ...} when PID-3 is empty or the PV1-3 ward
                         doesn't exist; 503 while switched down; waits 15 s first while switched slow
  POST /results          {"controlId", "messageType", "message"}: an ORU message
                         201; 422 {"error": ...} when the patient (PID-3) is unknown
Lab (MLLP, --ack-port)
  Receives the application acknowledgements the Logic App sends back. It answers nothing: an ACK is not acknowledged.
Demo
  GET  /received         patients, results and application ACKs received so far
  POST /control/down     the EHR answers 503 from now on
  POST /control/slow     the EHR waits 15 seconds before it answers
  POST /control/up       back to normal
  POST /control/reset    forget everything, back to normal

Usage: python app.py [--port 8302] [--ack-port 2322]
"""

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "shared", "tools"))
import mllp  # noqa: E402

WARDS = {"WARD1", "WARD2", "WARD3", "CLINIC1", "CLINIC2"}
KNOWN_PATIENTS = {"MRN100001", "MRN100002", "MRN100003"}

lock = threading.Lock()
state = {}


def reset():
    state.update(mode="up", next_key=1, patients=[], results=[], acks=[])


def segment(message, name):
    return next((s for s in mllp.segments(message) if s.startswith(name + "|")), "")


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
                return self._send(200, {"patients": state["patients"], "results": state["results"], "applicationAcks": state["acks"]})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/control/"):
            with lock:
                what = self.path[len("/control/"):]
                if what == "reset":
                    reset()
                elif what in ("down", "slow", "up"):
                    state["mode"] = what
                else:
                    return self._send(404, {"error": "not found"})
                return self._send(200, {"ehr": state["mode"]})
        if self.path not in ("/patients", "/results"):
            return self._send(404, {"error": "not found"})
        if state["mode"] == "down":
            return self._send(503, {"error": "EHR is down for maintenance"})
        if state["mode"] == "slow":
            time.sleep(15)
        try:
            item = json.loads(body)
            message = item["message"]
        except (ValueError, KeyError, TypeError):
            return self._send(400, {"error": "expected JSON with a 'message'"})
        pid = segment(message, "PID")
        patient_id = mllp.field(pid, 3).split("^")[0]
        with lock:
            if self.path == "/patients":
                ward = mllp.field(segment(message, "PV1"), 3).split("^")[0]
                if not patient_id:
                    return self._send(422, {"error": "PID-3 (patient identifier) is empty"})
                if ward not in WARDS:
                    return self._send(422, {"error": f"Ward {ward} does not exist"})
                key = f"EHR-{state['next_key']:06d}"
                state["next_key"] += 1
                state["patients"].append({"patientKey": key, "patientId": patient_id, "ward": ward, "controlId": item.get("controlId")})
                return self._send(201, {"patientKey": key})
            if patient_id not in KNOWN_PATIENTS and patient_id not in {p["patientId"] for p in state["patients"]}:
                return self._send(422, {"error": f"Unknown patient {patient_id}"})
            state["results"].append({"patientId": patient_id, "controlId": item.get("controlId")})
            return self._send(201, {"filed": item.get("controlId")})

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


def on_application_ack(message, peer):
    found, errors = mllp.acks(message)
    with lock:
        state["acks"].append({
            "ackCode": found[0]["code"] if found else "",
            "acknowledgedControlId": found[0]["controlId"] if found else "",
            "text": found[0]["text"] if found else "",
            "messageType": mllp.msh(message).get("messageType", ""),
            "ack": message.replace("\r", "\n").strip(),
        })
    print(f"lab: application ACK {found}", flush=True)
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8302)
    parser.add_argument("--ack-port", type=int, default=2322)
    args = parser.parse_args()
    reset()
    mllp.MllpServer(args.ack_port, on_application_ack, name="lab").start()
    print(f"EHR on http://127.0.0.1:{args.port}, lab ACK receiver on MLLP port {args.ack_port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
