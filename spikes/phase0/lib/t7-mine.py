"""Copies the output of each `trunk merge status` call in Claude Code transcripts into a t7-trunk.sh run folder.

Usage: t7-mine.py <projects folder> <run folder>

A Bash call's result holds the output of its whole command, so the script keeps only trunk's part: each block from a
`#<number> <title> (<author>)` header to the end of its table, and each error. It writes `<pr>-<n>.trunk.txt` with
`<pr>-<n>.meta.json`, whose start is the call's time, and it prints how many outputs of each kind it found. A command
that cut trunk's header off with tail or grep leaves a fragment. The script counts fragments and skips them.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime

projects, run = sys.argv[1], sys.argv[2]
ansi = re.compile(r"\x1b\[[0-9;]*m")
row = re.compile(r"^\s*\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s")
header = re.compile(r"^#(\d+) ")
errors = {"✖ User not logged in": "not logged in", "✖ Item for merge queue instance not found": "not found"}

files = subprocess.run(
    ["grep", "-rl", "--include=*.jsonl", "trunk merge status", projects], capture_output=True, text=True
).stdout.split()

calls = {}
for path in files:
    pending = {}
    with open(path, errors="replace") as f:
        for line in f:
            if "trunk merge status" not in line and "tool_result" not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            content = (entry.get("message") or {}).get("content")
            timestamp = entry.get("timestamp")
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use" and block.get("name") == "Bash":
                    command = (block.get("input") or {}).get("command", "")
                    if re.search(r"trunk merge status\s+\d+", command):
                        pending[block.get("id")] = (command, timestamp)
                elif block.get("type") == "tool_result" and block.get("tool_use_id") in pending:
                    command, timestamp = pending.pop(block["tool_use_id"])
                    out = block.get("content")
                    if isinstance(out, list):
                        out = "\n".join(x.get("text", "") for x in out if isinstance(x, dict))
                    # Transcripts that a fork or a resume copied hold the same call again.
                    if timestamp and out:
                        calls[(command, out)] = timestamp


def table_line(s):
    """Whether a line without colors is a timeline row or a row's wrapped description."""
    return bool(row.match(s)) or s.startswith(" " * 20)


def blocks(out):
    """Yields (kind, pr, text) for each part of the output that trunk printed."""
    lines = out.split("\n")
    plain = [ansi.sub("", line).rstrip("\r") for line in lines]
    i = 0
    while i < len(lines):
        kind = next((k for prefix, k in errors.items() if plain[i].strip().startswith(prefix)), None)
        if kind:
            end = i + 1
            while end < len(lines) and plain[end].startswith("  "):
                end += 1
            yield kind, None, "\n".join(lines[i:end]) + "\n"
            i = end
            continue
        m = header.match(plain[i].strip())
        if m and i + 1 < len(lines) and "Learn more at" in plain[i + 1]:
            end = i + 1
            while end < len(lines) and (
                plain[end].startswith(" Learn more") or not plain[end].strip() or table_line(plain[end])
            ):
                end += 1
            while end > i and not plain[end - 1].strip():
                end -= 1
            yield "found", m.group(1), "\n".join(lines[i:end]) + "\n"
            i = end
            continue
        if row.match(plain[i]):
            # Rows with no header before them: tail or grep cut the header off.
            while i < len(lines) and table_line(plain[i]):
                i += 1
            yield "fragment", None, None
            continue
        i += 1


os.makedirs(run, exist_ok=True)
counts = {}
taken = {}
for (command, out), timestamp in sorted(calls.items(), key=lambda c: c[1]):
    start = int(datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp() * 1000)
    for kind, pr, text in blocks(out):
        counts[kind] = counts.get(kind, 0) + 1
        if text is None:
            continue
        name = pr or kind.replace(" ", "-")
        taken[name] = n = taken.get(name, 0) + 1
        with open(f"{run}/{name}-{n}.trunk.txt", "w") as f:
            f.write(text)
        with open(f"{run}/{name}-{n}.meta.json", "w") as f:
            json.dump({"start": start}, f)

print(f"{len(calls)} calls in {len(files)} transcripts:", ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
