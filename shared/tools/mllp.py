"""A small MLLP sender and receiver for the samples (Python standard library only).

As a command, it is the sending HL7 system (an ADT source, a lab analyser):

    python mllp.py send --port 2301 --file ../../01-receive-auto-ack/messages/adt-a01.hl7
    python mllp.py send --port 2301 --message "MSH|^~\\&|PAS|MAPLE|...\\rPID|1"
    python mllp.py send --port 2304 --tls --cafile ../../04-tls/certs/logicapp.pem --file msg.hl7
    python mllp.py send --port 2301 --file a.hl7 b.hl7 --json      # one JSON result per message, for scripts

Each file holds one message or one HL7 batch (FHS/BHS ... BTS/FTS). Line feeds and CRLF in the file become the CR
segment terminator HL7 uses. All messages go over one connection, one after the other, each waiting for its ACK.

As a module, the samples' stand-in systems use MllpServer to play the receiving HL7 system (a lab, an EHR).
"""

import argparse
import json
import socket
import ssl
import sys
import threading
import time

START_BLOCK = b"\x0b"
END_BLOCK = b"\x1c"
TRAILER = b"\x0d"


def normalize(text):
    """HL7 segments end with CR. Accept LF and CRLF in files, and drop trailing blank lines."""
    text = text.replace("\r\n", "\r").replace("\n", "\r")
    return text.strip("\r") + "\r"


def frame(text, encoding="utf-8"):
    return START_BLOCK + text.encode(encoding) + END_BLOCK + TRAILER


def read_frame(sock, buffer):
    """Reads one MLLP frame. Returns (message bytes or None when the peer closed, remaining buffer)."""
    while True:
        start = buffer.find(START_BLOCK)
        if start >= 0:
            end = buffer.find(END_BLOCK + TRAILER, start)
            if end >= 0:
                return buffer[start + 1:end], buffer[end + 2:]
        chunk = sock.recv(65536)
        if not chunk:
            return None, buffer
        buffer += chunk


def segments(text):
    return [s for s in text.replace("\n", "\r").split("\r") if s]


def field(segment, index):
    """Field <index> of a segment (MSH-1 is the separator, so MSH fields are shifted by one)."""
    parts = segment.split("|")
    if segment.startswith("MSH"):
        index -= 1
    return parts[index] if 0 <= index < len(parts) else ""


def msh(text):
    """The first MSH segment's fields as a dict, or {} when there is none."""
    for s in segments(text):
        if s.startswith("MSH"):
            return {
                "sendingApplication": field(s, 3), "sendingFacility": field(s, 4),
                "receivingApplication": field(s, 5), "receivingFacility": field(s, 6),
                "messageType": field(s, 9), "controlId": field(s, 10), "processingId": field(s, 11),
                "version": field(s, 12), "acceptAckType": field(s, 15), "applicationAckType": field(s, 16),
            }
    return {}


def acks(text):
    """Every MSA segment of an ACK (a batch ACK has one per message)."""
    found = []
    errors = [s for s in segments(text) if s.startswith("ERR")]
    for s in segments(text):
        if s.startswith("MSA"):
            found.append({"code": field(s, 1), "controlId": field(s, 2), "text": field(s, 3)})
    return found, errors


# ----------------------------------------------------------------------------------------------------------------
# Sending

def connect(host, port, timeout, tls=False, cafile=None, server_name=None, tls_version="1.2", certfile=None, keyfile=None):
    raw = socket.create_connection((host, port), timeout=timeout)
    raw.settimeout(timeout)
    if not tls:
        return raw
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=cafile)
    version = ssl.TLSVersion.TLSv1_3 if tls_version == "1.3" else ssl.TLSVersion.TLSv1_2
    context.minimum_version = version
    context.maximum_version = version
    if certfile:
        context.load_cert_chain(certfile, keyfile)
    return context.wrap_socket(raw, server_hostname=server_name or host)


def send_all(messages, host, port, timeout=30, **tls):
    """Sends (name, text) pairs over one connection; returns one result dict per message."""
    results = []
    sock = None
    buffer = b""
    try:
        sock = connect(host, port, timeout, **tls)
    except (OSError, ssl.SSLError) as error:
        return [{"name": name, "error": f"connect failed: {error}"} for name, _ in messages]
    try:
        for name, text in messages:
            text = normalize(text)
            header = msh(text)
            result = {"name": name, "controlId": header.get("controlId", ""), "messageType": header.get("messageType", "")}
            began = time.perf_counter()
            try:
                sock.sendall(frame(text))
                data, buffer = read_frame(sock, buffer)
            except socket.timeout:
                result["error"] = f"no acknowledgement within {timeout} s"
                results.append(result)
                break
            except (OSError, ssl.SSLError) as error:
                result["error"] = f"connection failed: {error}"
                results.append(result)
                break
            result["elapsedMs"] = round((time.perf_counter() - began) * 1000)
            if data is None:
                result["error"] = "the receiver closed the connection without an acknowledgement"
                results.append(result)
                break
            ack = data.decode("utf-8", errors="replace")
            found, errors = acks(ack)
            result["ack"] = ack.replace("\r", "\n").strip()
            result["ackCode"] = found[0]["code"] if found else ""
            result["ackText"] = found[0]["text"] if found else ""
            result["acknowledgedControlId"] = found[0]["controlId"] if found else ""
            result["acks"] = found
            result["errors"] = errors
            if isinstance(sock, ssl.SSLSocket):
                result["tls"] = sock.version()
            results.append(result)
    finally:
        try:
            sock.close()
        except OSError:
            pass
    for name, _ in messages[len(results):]:
        results.append({"name": name, "error": "not sent: an earlier message failed"})
    return results


def command_send(args):
    messages = []
    for path in args.file or []:
        with open(path, encoding="utf-8") as handle:
            messages.append((path.replace("\\", "/").split("/")[-1], handle.read()))
    for text in args.message or []:
        messages.append(("message", text.replace("\\r", "\r").replace("\\n", "\n")))
    if not messages:
        sys.exit("Nothing to send: give --file or --message.")
    results = send_all(messages, args.host, args.port, args.timeout, tls=args.tls, cafile=args.cafile,
                       server_name=args.server_name, tls_version=args.tls_version)
    if args.json:
        print(json.dumps(results))
    else:
        for r in results:
            if "error" in r:
                print(f"{r['name']}: {r['error']}")
                continue
            print(f"{r['name']}: {r['ackCode']} for '{r['acknowledgedControlId']}' in {r['elapsedMs']} ms" +
                  (f" over {r['tls']}" if r.get("tls") else ""))
            for line in r["ack"].split("\n"):
                print(f"    {line}")
    return 0 if all(r.get("ackCode") in ("AA", "CA") for r in results) else 1


# ----------------------------------------------------------------------------------------------------------------
# Receiving

def make_ack(message, code="AA", text="", sending_app="", sending_facility="", error=None):
    """An original-mode ACK for a message: sender and receiver swapped, MSA-2 = MSH-10, ERR for a negative ACK."""
    header = msh(message)
    stamp = time.strftime("%Y%m%d%H%M%S")
    trigger = (header.get("messageType", "").split("^") + ["", ""])[1]
    lines = [
        "|".join(["MSH", "^~\\&", sending_app or header.get("receivingApplication", ""),
                  sending_facility or header.get("receivingFacility", ""), header.get("sendingApplication", ""),
                  header.get("sendingFacility", ""), stamp, "", f"ACK^{trigger}^ACK", "ACK" + stamp,
                  header.get("processingId", "P") or "P", header.get("version", "2.5.1") or "2.5.1"]),
        "|".join(["MSA", code, header.get("controlId", ""), text]),
    ]
    if error:
        lines.append(f"ERR|||{error}|E")
    return "\r".join(lines) + "\r"


class MllpServer:
    """A threaded MLLP listener. handler(message_text, peer) returns the ACK text, or None to answer nothing."""

    def __init__(self, port, handler, host="127.0.0.1", ssl_context=None, name="MLLP"):
        self.port, self.handler, self.ssl_context, self.name = port, handler, ssl_context, name
        self.sock = socket.create_server((host, port))

    def start(self):
        threading.Thread(target=self._accept, daemon=True).start()
        return self

    def _accept(self):
        while True:
            conn, peer = self.sock.accept()
            threading.Thread(target=self._serve, args=(conn, peer), daemon=True).start()

    def _serve(self, conn, peer):
        buffer = b""
        try:
            if self.ssl_context:
                conn = self.ssl_context.wrap_socket(conn, server_side=True)
            while True:
                data, buffer = read_frame(conn, buffer)
                if data is None:
                    return
                ack = self.handler(data.decode("utf-8", errors="replace"), peer)
                if ack is not None:
                    conn.sendall(frame(normalize(ack)))
        except (OSError, ssl.SSLError) as error:
            print(f"{self.name} {peer[0]}:{peer[1]}: {error}", flush=True)
        finally:
            try:
                conn.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description="Send HL7 messages over MLLP and print the acknowledgements.")
    sub = parser.add_subparsers(dest="command", required=True)
    send = sub.add_parser("send", help="send messages and wait for each ACK")
    send.add_argument("--host", default="127.0.0.1")
    send.add_argument("--port", type=int, required=True)
    send.add_argument("--file", nargs="+", help="files with one message or batch each")
    send.add_argument("--message", action="append", help="a message on the command line (\\r between segments)")
    send.add_argument("--timeout", type=float, default=30, help="seconds to wait for each ACK (default 30)")
    send.add_argument("--tls", action="store_true", help="MLLP over TLS")
    send.add_argument("--cafile", help="PEM certificate(s) to trust, such as a self-signed server certificate")
    send.add_argument("--server-name", help="name expected in the server certificate (default: --host)")
    send.add_argument("--tls-version", choices=["1.2", "1.3"], default="1.2")
    send.add_argument("--json", action="store_true", help="print the results as JSON")
    args = parser.parse_args()
    sys.exit(command_send(args))


if __name__ == "__main__":
    main()
