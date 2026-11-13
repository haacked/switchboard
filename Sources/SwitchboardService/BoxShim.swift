import Foundation
import SwitchboardCore

/// What sbd writes on a host for the hooks of the claudes there: the shim at `~/.sb/bin/sb-shim` and the hook
/// settings at `~/.sb/claude-settings.json`.
enum BoxShim {
  /// The shim, a Python 3 script. `sb-shim hook` reads a hook payload on stdin, appends the event to
  /// `$SB_HOME/spool.jsonl` under a lock, and sends it to `$SB_HOME/sbd.sock`, the far end of the forward to
  /// sbd. It prints sbd's answer only for a hook that waits, which is the rule of `HostHook.waits`. It exits 0
  /// and prints nothing on any failure, because Claude Code shows a failed hook in the conversation.
  /// `sb-shim spool-drop <count> <sha256>` is the spool cut. It exits 0 only after it removed exactly the
  /// first `count` bytes of the spool. See `spool_drop` for what it checks first.
  static let source = #"""
    #!/usr/bin/env python3
    # Written by Switchboard's sbd on each connect. Changes here are overwritten.
    import fcntl
    import hashlib
    import json
    import os
    import re
    import socket
    import sys
    import time

    CONNECT_SECONDS = 2


    def waits(payload):
        kind = payload.get("hook_event_name")
        return kind == "PermissionRequest" or (kind == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion")


    def encode(value):
        # A NaN or a lone surrogate raises, so a line that sbd could not read never reaches the spool.
        return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")


    def refuse_constant(name):
        raise ValueError(name)


    def event_id():
        return "%020d-%d-%04x" % (time.time_ns(), os.getpid(), int.from_bytes(os.urandom(2), "big"))


    def spool(home, session, payload):
        """Appends the event's line under the lock and returns the event's id."""
        lock = os.open(os.path.join(home, "spool.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # The id is made under the lock, so the lines of the spool are in the order of their clocks.
            event = event_id()
            line = encode({"v": 1, "id": event, "session": session, "payload": payload}) + b"\n"
            fd = os.open(os.path.join(home, "spool.jsonl"), os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
            try:
                while line:
                    line = line[os.write(fd, line):]
            finally:
                os.close(fd)
            return event
        finally:
            os.close(lock)


    def read_line(connection):
        data = b""
        while not data.endswith(b"\n"):
            more = connection.recv(65536)
            if not more:
                return None
            data += more
        return data


    def hook():
        # Claude Code writes the payload whether or not the hook reads it, so the hook reads it first.
        text = sys.stdin.buffer.read()
        session = os.environ.get("SB_SESSION_ID")
        home = os.environ.get("SB_HOME")
        if not session or not home:
            return
        payload = json.loads(text.decode("utf-8"), parse_constant=refuse_constant)
        if not isinstance(payload, dict):
            return
        try:
            event = spool(home, session, payload)
        except OSError:
            # A spool that can't be written keeps no copy for the next reconnect. The event still goes to sbd.
            event = event_id()
        request = encode({"op": "hook", "args": {"session": session, "payload": payload, "id": event}}) + b"\n"
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_SECONDS)
        connection.connect(os.path.join(home, "sbd.sock"))
        connection.sendall(request)
        if not waits(payload):
            return
        # The answer comes when the card is answered. Claude Code's own timeout ends the hook.
        connection.settimeout(None)
        line = read_line(connection)
        if line is None:
            return
        answer = json.loads(line.decode("utf-8"))
        result = answer.get("result") if isinstance(answer, dict) and answer.get("ok") is True else None
        if isinstance(result, dict) and result:
            sys.stdout.write(json.dumps(result))
            sys.stdout.flush()


    EVENT_ID = re.compile(r"[0-9]{20}-[0-9]{1,10}-[0-9a-f]{4}")


    def spool_line(raw):
        """Whether the bytes of one line, without the newline, are a spool line."""
        try:
            fields = json.loads(raw.decode("utf-8"))
        except ValueError:
            return False
        if not isinstance(fields, dict) or isinstance(fields.get("v"), bool) or fields.get("v") != 1:
            return False
        event = fields.get("id")
        if not isinstance(event, str) or not EVENT_ID.fullmatch(event) or int(event[:20]) >= 2 ** 64:
            return False
        return isinstance(fields.get("session"), str) and isinstance(fields.get("payload"), dict)


    def spool_drop(arguments):
        """Removes the first <count> bytes of the spool and returns True, or removes nothing and returns False.

        It removes them only when the spool's folder is a folder and not a link, and when, under the spool lock,
        the file starts with <count> bytes whose SHA-256 is <digest> and those bytes are whole spool lines. The
        file is replaced in one rename, so a drop that ends early leaves the file from before or the file without
        the bytes.
        """
        if len(arguments) != 2:
            return False
        count, digest = arguments
        if not re.fullmatch(r"[0-9]{1,18}", count) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            return False
        count = int(count)
        home = os.environ.get("SB_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        # A link at the folder would move the rewrite and the rename into the folder that it leads to.
        if os.path.islink(home) or not os.path.isdir(home):
            return False
        path = os.path.join(home, "spool.jsonl")
        if not os.path.isfile(path):
            return False
        lock = os.open(os.path.join(home, "spool.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with open(path, "rb") as source:
                head = source.read(count)
                if len(head) != count or hashlib.sha256(head).hexdigest() != digest:
                    return False
                if count == 0:
                    return True
                if not head.endswith(b"\n") or not all(spool_line(raw) for raw in head[:-1].split(b"\n")):
                    return False
                rest = path + ".drop"
                # A drop that ended early can leave this file. A link at this name must not be written through.
                try:
                    os.unlink(rest)
                except FileNotFoundError:
                    pass
                fd = os.open(rest, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                try:
                    while True:
                        block = source.read(1 << 20)
                        if not block:
                            break
                        while block:
                            block = block[os.write(fd, block):]
                    os.fsync(fd)
                finally:
                    os.close(fd)
            # A hook opens the spool by its name after it takes the lock, so the next hook appends to this file.
            os.replace(rest, path)
            return True
        finally:
            os.close(lock)


    if __name__ == "__main__":
        drops = sys.argv[1:2] == ["spool-drop"]
        status = 1 if drops else 0
        try:
            if sys.argv[1:] == ["hook"]:
                hook()
            elif drops and spool_drop(sys.argv[2:]):
                status = 0
        except BaseException:
            pass
        os._exit(status)

    """#

  /// The text of the host's `claude-settings.json`: the events and timeouts of this Mac's settings, with each
  /// hook run as `<python> <home>/.sb/bin/sb-shim hook`.
  static func settings(for facts: BoxFacts) -> String {
    Service.hookSettings(command: "\(shellQuote(facts.python)) \(shellQuote(shimPath(for: facts))) hook")
  }

  static func shimPath(for facts: BoxFacts) -> String { "\(facts.folder)/bin/sb-shim" }

  /// The far end of the forward, which the shim connects to.
  static func socketPath(for facts: BoxFacts) -> String { "\(facts.folder)/sbd.sock" }
}
