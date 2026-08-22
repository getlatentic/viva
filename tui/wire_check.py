"""Drive vivarium-tui against a scripted daemon.

WHY A FAKE ONE. The real daemon answers with whatever a model happens to say,
so a check written against it can only assert vaguely and cannot produce a
subagent, a failing task or a dropped sequence number on demand. It also costs
money. This speaks the same line-delimited JSON and says exactly what the check
needs said -- which is the point of the boundary: if the client needs the
engine to be real, they are not actually separate.

It is not a mock of the client's own code. Every byte here goes over a real
unix socket into the real binary, and what is asserted is the frame that comes
back out of a real pty.
"""
import codecs
import subprocess
import fcntl
import json
import os
import pty
import re
import select
import socket
import struct
import sys
import tempfile
import termios
import threading
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(ROOT, "target", "debug", "vivarium-tui")


def build():
    """Build before driving, so the check cannot pass or fail on a stale binary.

    It already did: a fix was made, the unit tests were rebuilt and passed, and
    this check kept failing against the binary from before it."""
    result = subprocess.run(["cargo", "build"], cwd=ROOT, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode())
        sys.exit("cargo build failed")


build()
sys.path.insert(0, ROOT)
from conformance import Terminal  # the same model, so one thing to keep honest

SESSIONS = [
    {"id": "s1", "label": "/w/alpha", "state": "working", "cwd": "/w/alpha", "model": "flash"},
    {"id": "s2", "label": "/w/beta", "state": "idle", "cwd": "/w/beta", "model": "flash"},
]

# What the session already said, replayed on attach. The seam matters: a client
# that shows the answers and not the questions is the bug this transcript is
# shaped to catch.
REPLAY = [
    ("user.message", {"text": "what is in this folder"}),
    ("model.delta", {"text": "a README and a Cargo.toml\n"}),
    ("user.message", {"text": "now run the suite"}),
    ("model.delta", {"text": "starting\n"}),
]

# What happens after: a subagent, its child, live output, and an ending.
LIVE = [
    ("task.started", {"task": "t1", "text": "run the suite"}),
    ("task.started", {"task": "t2", "text": "compile the crate", "parent": "t1"}),
    ("tool.output", {"text": "compiling vivarium-tui\n"}),
    ("tool.output", {"text": "running 18 tests\n"}),
    ("task.completed", {"task": "t2"}),
    ("model.delta", {"text": "18 passed\n"}),
    ("turn.completed", {}),
]


def serve(path, ready):
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


def talk(client):
    seq = [0]

    def line(payload):
        client.sendall((json.dumps(payload) + "\n").encode())

    def event(name, data, session="s1"):
        seq[0] += 1
        line({"event": name, "session": session, "seq": seq[0], "time": 0, "data": data})

    line({"type": "ready", "pid": 1, "sessions": SESSIONS})
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
            kind = request.get("type")
            rid = request.get("id")
            if kind == "session.attach":
                for name, data in REPLAY:
                    event(name, data, request.get("session", "s1"))
                line({"type": "response", "id": rid, "command": kind,
                      "success": True, "session": SESSIONS[0]})
                for name, data in LIVE:
                    time.sleep(0.05)
                    event(name, data, request.get("session", "s1"))
            elif kind == "session.list":
                line({"type": "response", "id": rid, "command": kind,
                      "success": True, "sessions": SESSIONS})
            elif kind == "session.start":
                new = {"id": "s3", "label": "/w/gamma", "state": "idle",
                       "cwd": "/w/gamma", "model": "flash"}
                SESSIONS.append(new)
                line({"type": "response", "id": rid, "command": kind,
                      "success": True, "session": new})
            elif kind == "prompt":
                line({"type": "response", "id": rid, "command": kind, "success": True})
                event("user.message", {"text": request.get("text", "")})
            else:
                line({"type": "response", "id": rid, "command": kind, "success": True})


FAILURES = []


def fail(message):
    FAILURES.append(message)
    print(f"  FAIL  {message}")


def ok(message):
    print(f"  ok    {message}")


def main():
    directory = tempfile.mkdtemp()
    path = os.path.join(directory, "wire.sock")
    ready = threading.Event()
    threading.Thread(target=serve, args=(path, ready), daemon=True).start()
    ready.wait(5)

    rows, cols = 34, 120
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["VIVARIUM_SOCKET"] = path
        os.chdir(directory)
        os.execve(BINARY, [BINARY], os.environ)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    term = Terminal(rows, cols)
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def pump(seconds):
        stop = time.time() + seconds
        while time.time() < stop:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            term.feed(decoder.decode(chunk))

    pump(6.0)
    frame = term.text()

    for needle, what in (
        ("what is in this folder", "the first question"),
        ("a README", "the first answer"),
        ("now run the suite", "the second question"),
        ("18 passed", "the live answer"),
    ):
        if needle not in frame:
            print(frame)
            fail(f"{what} is not on screen")
            break
    else:
        ok("the replay and the live stream arrive as one transcript")

    # The question is marked and the answer is not.
    question = next((l for l in term.lines() if "what is in this folder" in l), "")
    answer = next((l for l in term.lines() if "a README" in l), "")
    if "›" not in question:
        fail(f"the question carries no marker: {question!r}")
    elif "›" in answer:
        fail(f"the answer was marked as a question: {answer!r}")
    else:
        ok("a question is told from an answer on the screen")

    # The subagent, its child, and what the work printed.
    if "run the suite" not in frame or "compile the crate" not in frame:
        fail("the task pane does not show the subagents")
    elif "running 18 tests" not in frame:
        fail("what the background command printed is not shown")
    else:
        ok("subagents and their live output reach the task pane")

    # The child is shown under its parent, not beside it.
    # Compared by the COLUMN the text starts at, not by stripping the row's
    # leading characters: a row spans every pane, so what gets stripped is the
    # transcript's border and the number means nothing.
    lines = term.lines()
    parent_at = next((l.index("run the suite") for l in lines
                      if "run the suite" in l and "*" in l), None)
    child_line = next((l for l in lines if "compile the crate" in l), None)
    child_at = child_line.index("compile the crate") if child_line else None
    if parent_at is None or child_at is None:
        fail("could not find both tasks to compare their depth")
    elif child_at <= parent_at:
        fail(f"the child task is not shown under its parent (column {child_at} vs {parent_at})")
    else:
        ok("a subagent that spawned a subagent shows as one")

    # A finished task is told from a running one.
    child_line = child_line or ""
    if "+" not in child_line:
        fail(f"a completed task is not marked as completed: {child_line!r}")
    else:
        ok("a finished task looks different from a running one")

    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except Exception:
        pass

    print()
    if FAILURES:
        print(f"{len(FAILURES)} wire failure(s)")
        sys.exit(1)
    print("wire: the client renders what the protocol sends")


main()
