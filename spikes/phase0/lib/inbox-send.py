#!/usr/bin/env python3
"""Writes one user message to a Claude Code session's inbox socket.

Usage: inbox-send.py <socket> <text>

The inbox reads JSON lines. Claude Code 2.1.310 requires an auth line before
the message only on Windows, so this sends the message line alone. The script
half-closes the connection after the message and reads until the session
closes it. It prints one JSON line: `t`, the epoch ms just before the connect,
the connect, write, and close times in ms from then, and any bytes that came
back. It exits 1 when it can't connect.
"""

import json
import socket
import sys
import time


def main():
    path, text = sys.argv[1:3]
    message = {"type": "user", "message": {"role": "user", "content": text}}
    out = {"t": int(time.time() * 1000)}
    t0 = time.monotonic()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(path)
    except OSError as e:
        out["error"] = f"connect: {e}"
        print(json.dumps(out))
        return 1
    out["connect_ms"] = round((time.monotonic() - t0) * 1000, 1)
    s.sendall((json.dumps(message) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    out["write_ms"] = round((time.monotonic() - t0) * 1000, 1)
    received = b""
    try:
        while chunk := s.recv(4096):
            received += chunk
    except OSError as e:
        out["read_error"] = str(e)
    out["closed_ms"] = round((time.monotonic() - t0) * 1000, 1)
    out["received"] = received.decode(errors="replace")
    s.close()
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
