#!/usr/bin/env python3
"""A small MCP client for Phase 0 test 5.

Usage:
  mcp-probe.py <target> tools
  mcp-probe.py <target> call <tool>
  mcp-probe.py <target> parallel <clients> <tool>

<target> is stdio:<shell command>, sse:<url>, or http:<url>, where http is
the streamable HTTP transport. Calls pass no arguments. Each command prints
one JSON object:
  tools     server, connect_ms, and the sorted tool names. For stdio, also
            rss_kb, the RSS of the server's process tree after it listed them.
  call      server, connect_ms, and the call's ms, isError, and the start of
            its text.
  parallel  starts the clients at once. Each one connects, initializes, and
            makes the call. Prints how many succeeded and their ms.
"""

import http.client
import itertools
import json
import queue
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

TIMEOUT = 60
ids = itertools.count(1)


def now_ms():
    return int(time.time() * 1000)


class Stdio:
    def __init__(self, command):
        self.proc = subprocess.Popen(
            command,
            shell=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, message):
        self.send(message)
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout")
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("id") == message["id"]:
                return reply

    def tree_rss_kb(self):
        rows = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True
        ).stdout.split()
        procs = [tuple(map(int, rows[i : i + 3])) for i in range(0, len(rows), 3)]
        tree = {self.proc.pid}
        for _ in range(5):
            tree |= {pid for pid, ppid, _ in procs if ppid in tree}
        return sum(rss for pid, _, rss in procs if pid in tree)

    # postgres-mcp ignores SIGTERM, so this closes stdin and kills a server
    # that is still running 5 s later.
    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def sse_events(stream):
    """Yields (event, data) pairs from a text/event-stream response."""
    event, data = "message", []
    for raw in stream:
        line = raw.decode().rstrip("\r\n")
        if not line:
            if data:
                yield event, "\n".join(data)
            event, data = "message", []
        elif line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].lstrip())


class Sse:
    """The SSE transport. The server names a POST endpoint in its first
    event. It sends each reply as an event on the stream."""

    def __init__(self, url):
        parts = urllib.parse.urlsplit(url)
        self.conn = http.client.HTTPConnection(
            parts.hostname, parts.port, timeout=TIMEOUT
        )
        self.conn.request(
            "GET", parts.path or "/", headers={"Accept": "text/event-stream"}
        )
        self.replies = queue.Queue()
        events = sse_events(self.conn.getresponse())
        event, data = next(events)
        if event != "endpoint":
            raise RuntimeError(f"first event was {event}, not endpoint")
        self.endpoint = urllib.parse.urljoin(url, data)
        threading.Thread(target=self.read, args=(events,), daemon=True).start()

    def read(self, events):
        try:
            for event, data in events:
                if event == "message":
                    self.replies.put(json.loads(data))
        except Exception:
            pass

    def send(self, message):
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(message).encode(),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(request, timeout=TIMEOUT).read()

    def request(self, message):
        self.send(message)
        deadline = time.time() + TIMEOUT
        while True:
            reply = self.replies.get(timeout=max(0.1, deadline - time.time()))
            if reply.get("id") == message["id"]:
                return reply

    # Closing the response would wait for the server's next event, so this
    # shuts the socket down instead.
    def close(self):
        self.conn.sock.shutdown(socket.SHUT_RDWR)
        self.conn.close()


class Http:
    """The streamable HTTP transport. Each POST gets its reply as JSON or as
    an event stream."""

    def __init__(self, url):
        self.url, self.session = url, None

    def post(self, message):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(
            self.url, data=json.dumps(message).encode(), headers=headers
        )
        return urllib.request.urlopen(request, timeout=TIMEOUT)

    def send(self, message):
        self.post(message).read()

    def request(self, message):
        response = self.post(message)
        self.session = response.headers.get("Mcp-Session-Id") or self.session
        if response.headers.get("Content-Type", "").startswith("text/event-stream"):
            for _, data in sse_events(response):
                reply = json.loads(data)
                if reply.get("id") == message["id"]:
                    return reply
            raise RuntimeError("stream ended without a reply")
        return json.loads(response.read())

    def close(self):
        pass


def connect(target):
    kind, _, rest = target.partition(":")
    transport = {"stdio": Stdio, "sse": Sse, "http": Http}[kind](rest)
    result = rpc(
        transport,
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "sb-mcp-probe", "version": "0"},
        },
    )
    transport.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    transport.server = result.get("serverInfo", {})
    return transport


def rpc(transport, method, params):
    reply = transport.request(
        {"jsonrpc": "2.0", "id": next(ids), "method": method, "params": params}
    )
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def tool_names(transport):
    names, cursor = [], None
    while True:
        result = rpc(transport, "tools/list", {"cursor": cursor} if cursor else {})
        names += [tool["name"] for tool in result["tools"]]
        cursor = result.get("nextCursor")
        if not cursor:
            return sorted(names)


def call(transport, tool):
    t = now_ms()
    result = rpc(transport, "tools/call", {"name": tool, "arguments": {}})
    text = " ".join(c.get("text", "") for c in result.get("content", []))
    return {
        "ms": now_ms() - t,
        "isError": bool(result.get("isError")),
        "text": text[:200],
    }


def one_client(target, tool, results):
    t = now_ms()
    try:
        transport = connect(target)
        outcome = call(transport, tool)
        transport.close()
        results.append({"ok": not outcome["isError"], "ms": now_ms() - t})
    except Exception as e:
        results.append(
            {"ok": False, "ms": now_ms() - t, "error": f"{type(e).__name__}: {e}"[:200]}
        )


def main():
    target, command, *rest = sys.argv[1:]
    if command == "parallel":
        clients, tool = int(rest[0]), rest[1]
        results = []
        threads = [
            threading.Thread(target=one_client, args=(target, tool, results))
            for _ in range(clients)
        ]
        t = now_ms()
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        ms = sorted(r["ms"] for r in results)
        errors = sorted({r["error"] for r in results if "error" in r})
        print(
            json.dumps(
                {
                    "clients": clients,
                    "ok": sum(r["ok"] for r in results),
                    "wall_ms": now_ms() - t,
                    "ms_min": ms[0],
                    "ms_max": ms[-1],
                    "errors": errors,
                }
            )
        )
        return
    t = now_ms()
    transport = connect(target)
    out = {"server": transport.server, "connect_ms": now_ms() - t}
    if command == "tools":
        out["tools"] = tool_names(transport)
        if isinstance(transport, Stdio):
            out["rss_kb"] = transport.tree_rss_kb()
    elif command == "call":
        out.update(call(transport, rest[0]))
    else:
        raise SystemExit(f"unknown command {command}")
    print(json.dumps(out), flush=True)
    transport.close()


main()
