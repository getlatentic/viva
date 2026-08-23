"""Replay a real daemon journal through the real client and read the frame.

WHY THIS EXISTS ALONGSIDE THE SCRIPTED DAEMON. `wire_check.py` says exactly
what a check needs said, which is what makes it able to produce a subagent or
a dropped sequence number on demand -- and also what lets it agree with the
client about a wire neither of them has ever seen. Two of its assertions were
written against a field the daemon does not send, and they passed.

A journal is not negotiable. It is what the daemon wrote down while a person
was using it, so replaying one is the only check here that can disagree with
both sides at once.

    python3 journal_replay.py ~/.vivarium/journal/s6-*.jsonl
"""
import codecs
import fcntl
import glob
import json
import os
import pty
import re
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(ROOT, "target", "debug", "vivarium-tui")

if subprocess.run(["cargo", "build"], cwd=ROOT).returncode != 0:
    sys.exit("build failed")
sys.path.insert(0, ROOT)
from conformance import Terminal

FAILURES = []


def fail(message):
    FAILURES.append(message)
    print(f"  FAIL  {message}")


def ok(message):
    print(f"  ok    {message}")


def load(path):
    """The recorded events, minus the ones the daemon replays as bookkeeping."""
    rows = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def serve(path, events, ready):
    label = events[0]["data"].get("label", "/w") if events else "/w"
    sessions = [{"id": "s1", "label": label, "state": "idle",
                 "cwd": label, "model": "flash"}]

    def talk(client):
        def line(payload):
            client.sendall((json.dumps(payload) + "\n").encode())

        line({"type": "ready", "pid": 1, "sessions": sessions})
        buffer = b""
        while True:
            try:
                chunk = client.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                try:
                    request = json.loads(raw)
                except ValueError:
                    continue
                kind, rid = request.get("type"), request.get("id")
                if kind == "session.attach":
                    for index, recorded in enumerate(events, start=1):
                        line({"event": recorded["event"], "session": "s1",
                              "seq": index, "time": 0, "data": recorded["data"]})
                    line({"type": "response", "id": rid, "command": kind,
                          "success": True, "session": sessions[0]})
                elif kind == "session.list":
                    line({"type": "response", "id": rid, "command": kind,
                          "success": True, "sessions": sessions})
                else:
                    line({"type": "response", "id": rid, "command": kind, "success": True})

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(4)
    ready.set()
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=talk, args=(client,), daemon=True).start()


def draw(events, rows=110, cols=120):
    directory = tempfile.mkdtemp()
    path = os.path.join(directory, "replay.sock")
    ready = threading.Event()
    threading.Thread(target=serve, args=(path, events, ready), daemon=True).start()
    ready.wait(5)

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["VIVARIUM_SOCKET"] = path
        os.chdir(directory)
        os.execve(BINARY, [BINARY], os.environ)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    term = Terminal(rows, cols)
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    stop = time.time() + 5.0
    while time.time() < stop:
        readable, _, _ = select.select([fd], [], [], 0.1)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        term.feed(decoder.decode(chunk))
    os.close(fd)
    return term


def plain(text):
    """The text with its markup taken off, as the client draws it.

    The journal holds what the model WROTE, and the client draws it rendered:
    a tail ending in `error` is four characters longer in the record than on
    the screen. Comparing one against the other passed until a reply happened
    to end on a backticked word."""
    return re.sub(r"[*`_]", "", text)


def flatten(lines):
    """The frame as one run of words, so a check is not defeated by wrapping.

    Box rules and pane borders come out, and every run of whitespace becomes a
    single space. A sentence broken across three rows then reads as itself."""
    text = " ".join(lines)
    for rule in "\u2502\u2500\u250c\u2510\u2514\u2518\u251c\u2524\u252c\u2534\u253c":
        text = text.replace(rule, " ")
    return " ".join(text.split())


def latest_turn(events):
    """The events since the last turn began.

    By `turn.started`, not by the question: a journal written before the daemon
    published `user.message` has no question in it at all, and scoping by one
    swallowed a whole session as though it were a single turn.

    A long session does not fit on a screen and is not meant to -- what
    scrolled off is gone, correctly -- so only the newest turn can be asserted
    about, and even that only as far down as the screen reaches."""
    marks = [index for index, event in enumerate(events)
             if event["event"] == "turn.started"]
    return events[marks[-1]:] if marks else events


def check(path):
    events = load(path)
    print(f"{os.path.basename(path)}: {len(events)} recorded events")
    term = draw(events)
    lines = [line.rstrip() for line in term.lines()]
    frame = "\n".join(lines)
    flat = flatten(lines)
    newest = latest_turn(events)

    # 1. No reply is drawn twice. SCROLL-INDEPENDENT, so it holds for every
    #    turn in the journal and not only the visible one: a model rarely ends
    #    its last sentence with a newline, so the closing paragraph is the
    #    unfinished line, and holding it in two places drew it again.
    tails = [plain(flatten([event["data"].get("text", "")]))[-60:]
             for event in events if event["event"] == "turn.completed"
             and len(event["data"].get("text", "").strip()) > 60]
    twice = [tail for tail in tails if flat.count(tail) > 1]
    if twice:
        print(frame)
        fail(f"a reply is drawn {flat.count(twice[0])} times: {twice[0][:50]!r}")
    else:
        ok(f"none of {len(tails)} replies is drawn twice")

    # 2. The newest turn is fully in front of the person following it: its
    #    reply, and the result of every tool it called. The result rides on
    #    `tool.completed` under `output`, and reading only the streaming event
    #    left a transcript of calls with nothing under any of them.
    ending = [plain(flatten([event["data"].get("text", "")]))[-60:]
              for event in newest if event["event"] == "turn.completed"
              and len(event["data"].get("text", "").strip()) > 60]
    if ending and ending[-1] not in flat:
        print(frame)
        fail(f"the newest reply is not on screen: {ending[-1][:50]!r}")
    elif ending:
        ok("the newest reply is on screen, once")

    firsts = [plain(flatten([event["data"]["output"].strip().splitlines()[0]]))
              for event in newest
              if event["event"] in ("tool.completed", "tool.failed")
              and event["data"].get("output", "").strip()]
    if not firsts:
        ok("the newest turn called no tool that returned a result")
    else:
        # A turn taller than the screen loses its OLDEST lines, so the results
        # on screen must be a SUFFIX of the results sent. A gap in the middle
        # is a dropped result wearing a scroll's clothes.
        present = [first in flat for first in firsts]
        if not present[-1]:
            print(frame)
            fail(f"the newest result never reached the screen: {firsts[-1][:50]!r}")
        elif False in present[present.index(True):]:
            print(frame)
            fail("a result is missing from the middle of the turn, not the top")
        else:
            kept = sum(present)
            note = "" if kept == len(firsts) else f" ({len(firsts) - kept} scrolled off the top)"
            ok(f"{kept} of {len(firsts)} results from the newest turn are on screen{note}")

    # 3. A call with an empty argument reads as the bare tool name. `ls` with a
    #    path of "" means the working directory; taking that as the thing to
    #    show left the call reading `ls ` with a separator and nothing after.
    #
    #    Located by STRUCTURE, not by scanning the frame: a pane pads every row
    #    out to its width, so trailing padding and a dangling separator look
    #    identical to anything matching on substrings.
    bare = set()
    for event in newest:
        if event["event"] != "tool.started":
            continue
        call = event["data"].get("call", {})
        arguments = call.get("arguments") or {}
        if call.get("name") and not any(str(v).strip() for v in arguments.values()):
            bare.add(call["name"])
    # A call is the title of a rule: `─ ✔ ls ─────`. The title is what sits
    # between the mark and the rule that follows it.
    spoken = set()
    for row in lines:
        found = re.search(r"[\u2714\u2718\u00b7] (.*?)(?:\s+\u2500|\s*$)", row)
        if found:
            spoken.add(found.group(1).strip())
    if not bare:
        ok("the newest turn has no call with an empty argument")
    for name in sorted(bare):
        if name in spoken:
            ok(f"`{name}` with no argument reads as its own name")
        else:
            fail(f"`{name}` is drawn as something other than its own name")


def main():
    paths = sys.argv[1:] or sorted(
        glob.glob(os.path.expanduser("~/.vivarium/journal/*.jsonl")),
        key=os.path.getmtime, reverse=True)[:1]
    if not paths:
        sys.exit("no journal given and none found under ~/.vivarium/journal")
    for path in paths:
        check(path)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} failed")
        sys.exit(1)
    print("journal replay clean")


if __name__ == "__main__":
    main()
