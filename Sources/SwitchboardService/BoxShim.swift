import Foundation
import SwitchboardCore

/// What sbd writes on a host for the claudes there: the shim at `~/.sb/bin/sb-shim`, the hook settings at
/// `~/.sb/claude-settings.json`, and the `sb` wrapper at `~/.sb/bin/sb`.
enum BoxShim {
  /// The shim, a Python 3 script. `sb-shim hook` reads a hook payload on stdin, appends the event to
  /// `$SB_HOME/spool.jsonl` under a lock, and sends it to `$SB_HOME/sbd.sock`, the far end of the forward to
  /// sbd. It prints sbd's answer only for a hook that waits, which is the rule of `HostHook.waits`. It exits 0
  /// and prints nothing on any failure, because Claude Code shows a failed hook in the conversation.
  /// `sb-shim spool-drop <count> <sha256>` is the spool cut. It exits 0 only after it removed exactly the
  /// first `count` bytes of the spool. See `spool_drop` for what it checks first.
  /// `sb-shim cli <argv…>` sends the argv in one `cli` request to `$SB_HOME/sbd.sock`, writes the bytes of the
  /// answer's two streams, and exits with its status. It reads stdin only for `summary set`, the one command
  /// that reads stdin and runs through a host. It never spools. It exits 1 with the reason on stderr when it
  /// can't reach sbd or sbd fails the request.
  static let source = #"""
    #!/usr/bin/env python3
    # Written by Switchboard's sbd on each connect. Changes here are overwritten.
    import base64
    import fcntl
    import hashlib
    import json
    import os
    import re
    import socket
    import sys
    import time

    CONNECT_SECONDS = 2
    # sbd ends a cli run after 600 s and answers within a few seconds of that.
    CLI_ANSWER_SECONDS = 660


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


    def summary_set(argv):
        """Whether sb reads argv as `summary set`, the one command of a host that reads stdin."""
        if argv[:1] != ["summary"]:
            return False
        return [word for word in argv[1:] if not word.startswith("--")][:1] == ["set"]


    def read_answer(connection):
        """The bytes of one line, without the newline, or None when the connection ends first."""
        chunks = []
        while True:
            more = connection.recv(1 << 20)
            if not more:
                return None
            end = more.find(b"\n")
            if end >= 0:
                chunks.append(more[:end])
                return b"".join(chunks)
            chunks.append(more)


    def cli(argv):
        """Runs argv as sb on the Mac and returns the exit status."""
        # The shim sits at <home>/bin/sb-shim, as spool-drop finds it.
        home = os.environ.get("SB_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        args = {"argv": argv, "cwd": os.getcwd()}
        if os.environ.get("SB_SESSION_ID"):
            args["session"] = os.environ["SB_SESSION_ID"]
        # sb on the Mac reads CLAUDECODE as sb on this host would, so it goes as set, even when empty.
        if "CLAUDECODE" in os.environ:
            args["claudecode"] = os.environ["CLAUDECODE"]
        if summary_set(argv):
            args["stdin"] = base64.b64encode(sys.stdin.buffer.read()).decode("ascii")
        request = encode({"op": "cli", "args": args}) + b"\n"
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(CONNECT_SECONDS)
        try:
            connection.connect(os.path.join(home, "sbd.sock"))
        except OSError as error:
            sys.stderr.write("sb: can't reach Switchboard on the Mac: %s\n" % error)
            return 1
        connection.settimeout(CLI_ANSWER_SECONDS)
        connection.sendall(request)
        line = read_answer(connection)
        if line is None:
            sys.stderr.write("sb: Switchboard on the Mac closed the connection before it answered\n")
            return 1
        answer = json.loads(line.decode("utf-8"))
        if not isinstance(answer, dict) or answer.get("ok") is not True:
            error = answer.get("error") if isinstance(answer, dict) else None
            sys.stderr.write("sb: %s\n" % (error if isinstance(error, str) else "Switchboard on the Mac failed"))
            return 1
        result = answer.get("result")
        status = result.get("status") if isinstance(result, dict) else None
        if not isinstance(status, int) or isinstance(status, bool):
            sys.stderr.write("sb: Switchboard on the Mac answered no exit status\n")
            return 1
        stdout = base64.b64decode(result.get("stdout", ""), validate=True)
        stderr = base64.b64decode(result.get("stderr", ""), validate=True)
        sys.stdout.buffer.write(stdout)
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(stderr)
        sys.stderr.buffer.flush()
        return status & 0xFF


    def run_cli(argv):
        try:
            status = cli(argv)
        except BaseException as error:
            try:
                sys.stderr.write("sb: %s\n" % (error or type(error).__name__))
            except BaseException:
                pass
            status = 1
        try:
            sys.stderr.flush()
        except BaseException:
            pass
        os._exit(status)


    if __name__ == "__main__":
        if sys.argv[1:2] == ["cli"]:
            run_cli(sys.argv[2:])
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
    JSON.object(Service.hookSettings(command: "\(shellQuote(facts.python)) \(shellQuote(shimPath(for: facts))) hook"))
      .text
  }

  /// The text of the host's `~/.sb/bin/sb`, which runs `<python> <home>/.sb/bin/sb-shim cli` with every
  /// argument.
  static func wrapper(for facts: BoxFacts) -> String {
    """
    #!/bin/sh
    # Written by Switchboard's sbd on each connect. Changes here are overwritten.
    exec \(shellQuote(facts.python)) \(shellQuote(shimPath(for: facts))) cli "$@"

    """
  }

  static func shimPath(for facts: BoxFacts) -> String { "\(facts.folder)/bin/sb-shim" }

  /// The far end of the forward, which the shim connects to.
  static func socketPath(for facts: BoxFacts) -> String { "\(facts.folder)/sbd.sock" }
}
