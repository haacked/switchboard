"""Runs a command once a machine-wide build slot is free.

    bin/lib/build-slot [--] command [arguments...]
    bin/lib/build-slot --check

At most SB_BUILD_SLOTS commands (default 3) hold a slot at once. The others
wait in the order they arrived. A waiting process prints "waiting for a build
slot (N ahead)" on stderr whenever N changes. N counts the commands that must
finish before this one starts.

Each command has a ticket file in SB_BUILD_SLOTS_DIR (default
~/Library/Caches/Switchboard/build-slots). The ticket's name is a sequence
number that never repeats, so a stale SB_BUILD_SLOT_HELD from an earlier run
never names a newer holder's ticket. The helper holds an flock on its ticket
until the command ends. A ticket is live while its flock is held. The kernel
drops the flock when the helper dies, even from SIGKILL, so a dead helper's
slot frees on the next scan. A command runs when fewer than SB_BUILD_SLOTS live tickets have
a lower number.

The helper starts the command as a child and does not pass it the ticket's
file descriptor. A daemon that the command starts, such as a tmux server, then
cannot keep the slot. The helper forwards SIGINT, SIGTERM, and SIGHUP to the
child and exits with the child's status. If the helper itself is SIGKILLed,
its slot frees while the child may keep running.

The child gets SB_BUILD_SLOT_HELD set to the ticket's path. When that ticket
is live, a nested call runs its command at once without a second slot.
`--check` exits 0 when the caller may build without taking a slot: when
SB_BUILD_SLOT_HELD names a live ticket, or when the queue is off. It exits 1
otherwise. A script that re-runs itself under the helper when the check fails
then never loops.

SB_BUILD_SLOTS=0 turns the queue off. SB_BUILD_SLOT_POLL sets the seconds
between scans of the queue (default 1).
"""

import contextlib
import errno
import fcntl
import json
import math
import os
import re
import signal
import subprocess
import sys
import time

TICKET = re.compile(r"^(\d{12})\.ticket$")
TEMP = re.compile(r"^tmp\.\d+\.\d+$")
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class Interrupted(Exception):
    """A signal arrived before the command started. args[0] is the signal."""


def fail(message):
    print(f"build-slot: {message}", file=sys.stderr)
    sys.exit(2)


def setting(name, default, parse, valid, description):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        value = parse(raw)
    except ValueError:
        value = None
    if value is None or not valid(value):
        fail(f"{name} must be {description}, not {raw!r}")
    return value


def held_by_another(fd):
    """Whether another open file holds the flock that fd tries to take."""
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    return False


def held_live():
    """Whether SB_BUILD_SLOT_HELD names a ticket that a live process holds."""
    path = os.environ.get("SB_BUILD_SLOT_HELD", "")
    if not path or not TICKET.match(os.path.basename(path)):
        return False
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        return held_by_another(fd)
    finally:
        os.close(fd)


def exempt(slots):
    """Whether a command may run without taking a slot."""
    return slots == 0 or held_live()


def tickets(folder):
    """The (number, name) of every ticket in the folder, lowest first."""
    found = []
    for name in os.listdir(folder):
        match = TICKET.match(name)
        if match:
            found.append((int(match.group(1)), name))
    return sorted(found)


def unlink_quietly(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


class Queue:
    def __init__(self, folder):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)
        self.mutex = os.open(self.path("mutex"), os.O_RDWR | os.O_CREAT, 0o644)

    def path(self, name):
        return os.path.join(self.folder, name)

    @contextlib.contextmanager
    def locked(self):
        fcntl.flock(self.mutex, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(self.mutex, fcntl.LOCK_UN)

    def enqueue(self, argv):
        """Creates and locks a ticket. Returns its number, path, and fd."""
        with self.locked():
            # Only the mutex holder creates tmp files, and it renames them
            # before it lets go. A tmp file seen here belongs to a dead helper.
            for name in os.listdir(self.folder):
                path = self.path(name)
                if TEMP.match(name) and os.path.isfile(path) and not os.path.islink(path):
                    unlink_quietly(path)
            highest = max((number for number, _ in tickets(self.folder)), default=0)
            seq = max(self.read_counter(), highest) + 1
            self.write_counter(seq)
            tmp = self.path(f"tmp.{os.getpid()}.{seq}")
            fd = os.open(tmp, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o644)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            record = {
                "pid": os.getpid(),
                "seq": seq,
                "session": os.environ.get("SB_SESSION_ID") or None,
                "cwd": os.getcwd(),
                "argv": argv,
                "started": time.time(),
            }
            os.write(fd, (json.dumps(record) + "\n").encode())
            # The ticket gets its final name only after it is locked, so no
            # scan sees a live ticket without its lock.
            path = self.path(f"{seq:012d}.ticket")
            os.rename(tmp, path)
            return seq, path, fd

    def read_counter(self):
        try:
            with open(self.path("counter")) as f:
                return int(f.read().strip() or 0)
        except (FileNotFoundError, ValueError):
            return 0

    def write_counter(self, seq):
        new = self.path("counter.new")
        with open(new, "w") as f:
            f.write(f"{seq}\n")
        os.rename(new, self.path("counter"))

    def live_below(self, seq):
        """Counts live tickets numbered below seq and removes dead ones."""
        live = 0
        with self.locked():
            for number, name in tickets(self.folder):
                if number >= seq:
                    break
                path = self.path(name)
                try:
                    fd = os.open(path, os.O_RDONLY)
                except FileNotFoundError:
                    continue
                try:
                    if held_by_another(fd):
                        live += 1
                    elif same_file(fd, path):
                        # Nobody holds the ticket, so its helper died. Its
                        # owner can also have just removed it and let go.
                        unlink_quietly(path)
                finally:
                    os.close(fd)
        return live


def same_file(fd, path):
    try:
        on_disk = os.stat(path)
    except FileNotFoundError:
        return False
    mine = os.fstat(fd)
    return (on_disk.st_dev, on_disk.st_ino) == (mine.st_dev, mine.st_ino)


def duration(seconds):
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    return f"{seconds // 60}m {seconds % 60:02d}s"


def wait_for_slot(queue, seq, slots, poll):
    started = time.monotonic()
    shown = None
    while True:
        live = queue.live_below(seq)
        if live < slots:
            break
        ahead = live - (slots - 1)
        if ahead != shown:
            print(f"build-slot: waiting for a build slot ({ahead} ahead)", file=sys.stderr, flush=True)
            shown = ahead
        time.sleep(poll)
    if shown is not None:
        waited = duration(time.monotonic() - started)
        print(f"build-slot: got a build slot after {waited}", file=sys.stderr, flush=True)


def exit_status(returncode):
    return 128 - returncode if returncode < 0 else returncode


class Child:
    """The command's process, once started. A signal before then interrupts the wait."""

    def __init__(self):
        self.process = None

    def on_signal(self, signum, _frame):
        if self.process is None:
            raise Interrupted(signum)
        self.process.send_signal(signum)

    def run(self, command, ticket):
        env = dict(os.environ, SB_BUILD_SLOT_HELD=ticket)
        try:
            self.process = subprocess.Popen(command, env=env, close_fds=True)
        except OSError as error:
            print(f"build-slot: {command[0]}: {error.strerror}", file=sys.stderr)
            return 127 if error.errno == errno.ENOENT else 126
        return exit_status(self.process.wait())


def main(argv):
    slots = setting("SB_BUILD_SLOTS", 3, int, lambda v: v >= 0, "a whole number 0 or above")
    if argv == ["--check"]:
        return 0 if exempt(slots) else 1
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        print("usage: build-slot [--] command [arguments...] | build-slot --check", file=sys.stderr)
        return 2
    poll = setting("SB_BUILD_SLOT_POLL", 1.0, float, lambda v: 0 < v and math.isfinite(v), "a number of seconds above 0")
    if exempt(slots):
        try:
            os.execvp(argv[0], argv)
        except OSError as error:
            print(f"build-slot: {argv[0]}: {error.strerror}", file=sys.stderr)
            return 127 if error.errno == errno.ENOENT else 126

    child = Child()
    for signum in SIGNALS:
        signal.signal(signum, child.on_signal)
    folder = os.environ.get("SB_BUILD_SLOTS_DIR") or os.path.expanduser(
        "~/Library/Caches/Switchboard/build-slots"
    )
    queue = Queue(folder)
    ticket = fd = None
    try:
        seq, ticket, fd = queue.enqueue(argv)
        wait_for_slot(queue, seq, slots, poll)
        return child.run(argv, ticket)
    except Interrupted as interrupted:
        return 128 + interrupted.args[0]
    finally:
        if ticket is not None:
            unlink_quietly(ticket)
        if fd is not None:
            os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
