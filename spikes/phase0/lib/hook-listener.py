#!/usr/bin/env python3
"""A stand-in for sbd's hook endpoint, for Phase 0 test 3.

Usage: hook-listener.py <control dir>

Listens on 127.0.0.1 at a free port and writes the port to <control dir>/port.
Appends each POST to <control dir>/listener.jsonl as one JSON line with a
millisecond timestamp, the path, the headers, and the parsed body. Lines whose
event starts with "_" record what happened to a held request.

<control dir>/policy.json maps a hook event name, or "*" for any event, to
{"hold": s}. The listener reads it on each request. A held request waits until
<control dir>/release.json holds a JSON object or s seconds pass, then gets
that object, or an empty body after s seconds. While a request waits, the
listener checks every 50 ms whether Claude Code closed the connection, and
logs "_closed" if it did. It logs "_answered" for every held request it answers.
"""

import json
import os
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

control = sys.argv[1]
log_path = os.path.join(control, "listener.jsonl")
release_path = os.path.join(control, "release.json")
lock = threading.Lock()
count = 0


def now_ms():
    return int(time.time() * 1000)


def log(entry):
    with lock, open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def hold_for(event):
    with open(os.path.join(control, "policy.json")) as f:
        policy = json.load(f)
    return (policy.get(event) or policy.get("*") or {}).get("hold", 0)


# A writer that redirects into release.json leaves it empty for a moment, so
# the listener answers only once the file parses.
def release():
    try:
        with open(release_path, "rb") as f:
            reply = f.read()
        json.loads(reply)
        return reply
    except (FileNotFoundError, ValueError):
        return None


def closed(sock):
    readable, _, _ = select.select([sock], [], [], 0)
    if not readable:
        return False
    try:
        return sock.recv(1, socket.MSG_PEEK) == b""
    except OSError:
        return True


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        t = now_ms()
        with lock:
            count += 1
            n = count
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw.decode(errors="replace")
        event = body.get("hook_event_name") if isinstance(body, dict) else None
        log(
            {
                "t": t,
                "n": n,
                "event": event,
                "path": self.path,
                "headers": dict(self.headers),
                "body": body,
            }
        )
        hold = hold_for(event)
        reply = b""
        deadline = time.time() + hold
        while time.time() < deadline:
            released = release()
            if released is not None:
                reply = released
                break
            if closed(self.connection):
                log(
                    {
                        "t": now_ms(),
                        "n": n,
                        "event": "_closed",
                        "of": event,
                        "held_ms": now_ms() - t,
                    }
                )
                return
            time.sleep(0.05)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)
            outcome = "sent"
        except OSError as e:
            outcome = type(e).__name__
        if hold or outcome != "sent":
            log(
                {
                    "t": now_ms(),
                    "n": n,
                    "event": "_answered",
                    "of": event,
                    "reply": reply.decode(errors="replace"),
                    "outcome": outcome,
                }
            )

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(control, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
