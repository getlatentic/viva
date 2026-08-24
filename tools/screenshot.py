"""The client, drawing a known session, for the picture in the README.

A screenshot of somebody's real work is not ours to publish, and a screenshot
of an empty client shows nothing worth looking at. So this serves one scripted
session from a fake daemon and hands the terminal to the real binary. What
appears on screen is the client's own output, and the session it draws is the
same one every time -- so a picture taken after a layout change is comparable
with the one before it.

    cargo build --release --manifest-path tui/Cargo.toml
    python3 tools/screenshot.py        # then photograph the window

It sizes the window to 124x32 and exits when the client does.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.join(os.path.dirname(ROOT), "tui", "target", "release", "viva-tui")

# The transcript the picture shows: a question, work with its results, a
# worker, and an answer. Written here rather than captured from a real session,
# because a picture of somebody's actual work is not ours to publish.
TRANSCRIPT = [
    ("session.started", {"label": "/Users/you/work/atlas"}),
    ("user.message", {"text": "why is the picker losing its filter"}),
    ("model.delta", {"text": "Let me look at how the query is held.\n"}),
    ("tool.started", {"call": {"id": "c1", "name": "grep",
                               "arguments": {"pattern": "picker.query"}}}),
    ("tool.completed", {"call": {"id": "c1"},
                        "output": "src/input.rs:71  model.picker.query.clear();\n"
                                  "src/main.rs:284  model.picker.query.push(c);\n"
                                  "src/ui.rs:377    &model.picker.query"}),
    ("tool.started", {"call": {"id": "d1", "name": "delegate",
                               "arguments": {"task": "check whether any other key path clears it"}}}),
    ("tool.started", {"call": {"id": "c2", "name": "read",
                               "arguments": {"path": "src/input.rs"}}, "lane": "lane-1"}),
    ("tool.completed", {"call": {"id": "c2"}, "lane": "lane-1",
                        "output": "fn picker_key(key: &KeyEvent, model: &mut Model) -> Action {\n"
                                  "    match key.code {\n"
                                  "        KeyCode::Esc => { model.focus = Focus::Input; }"}),
    ("tool.completed", {"call": {"id": "d1"},
                        "output": "Only `Esc` clears it, and it also closes the picker."}),
    ("model.delta", {"text":
        "The filter is cleared in **one** place, `input.rs:71`, and that runs when the\n"
        "picker opens rather than when it closes.\n\n"
        "| where | what it does |\n|---|---|\n"
        "| `input.rs:71` | clears on open |\n| `main.rs:284` | appends a keystroke |\n\n"
        "So reopening the picker throws away what you typed last time.\n"}),
    ("turn.completed", {"text": "So reopening the picker throws away what you typed last time."}),
]

SESSIONS = [{"id": "20260824-0914-A1B2", "label": "/Users/you/work/atlas", "state": "working",
             "cwd": None, "model": "deepseek-4-flash", "effort": "high",
             "opening": "why is the picker losing its filter", "tokens": 18400, "limit": 128000}]
RECORDED = [
    {"id": "20260824-0820-7C41", "cwd": None, "time": 3996480000, "messages": 34,
     "opening": "why is the picker losing its filter"},
    {"id": "20260823-1712-9B0E", "cwd": None, "time": 3996400000, "messages": 12,
     "opening": "add a --json flag to the report"},
    {"id": "20260823-0904-2DD8", "cwd": None, "time": 3996300000, "messages": 61,
     "opening": "port the wire format to protobuf"},
]


class _Gone(Exception):
    """The client has closed its end. Nothing here is worth saying about it."""


def serve(path, ready, cwd):
    for entry in SESSIONS:
        entry["cwd"] = cwd
    for entry in RECORDED:
        entry["cwd"] = cwd

    def talk(client):
        def line(payload):
            # A CLOSED PIPE IS THE CLIENT LEAVING, not a fault. Raised from a
            # thread, it printed a traceback over the very frame this exists
            # to photograph.
            try:
                client.sendall((json.dumps(payload) + "\n").encode())
            except OSError:
                raise _Gone()
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
                kind, rid = request.get("type"), request.get("id")
                if kind == "session.attach":
                    for index, (name, data) in enumerate(TRANSCRIPT, start=1):
                        line({"event": name, "session": SESSIONS[0]["id"],
                              "seq": index, "time": 0, "data": data})
                    line({"type": "response", "id": rid, "command": kind,
                          "success": True, "session": SESSIONS[0]})
                elif kind == "session.list":
                    line({"type": "response", "id": rid, "command": kind,
                          "success": True, "sessions": SESSIONS})
                elif kind == "session.recorded":
                    line({"type": "response", "id": rid, "command": kind,
                          "success": True, "recorded": RECORDED})
                else:
                    line({"type": "response", "id": rid, "command": kind, "success": True})

    def quietly(client):
        try:
            talk(client)
        except (_Gone, OSError):
            pass

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(4)
    ready.set()
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=quietly, args=(client,), daemon=True).start()


def main():
    """Serve the scripted session, then hand this terminal to the client.

    The daemon runs on a thread of this process and the client runs as a child
    holding the real tty, so what appears is the client drawing on a terminal
    somebody can photograph -- rather than a rendering of what it might draw.
    """
    if not os.path.exists(CLIENT):
        sys.exit(f"no client at {CLIENT} -- cargo build --release --manifest-path tui/Cargo.toml")
    directory = os.path.realpath(tempfile.mkdtemp(prefix="viva-shot-"))
    path = os.path.join(directory, "shot.sock")
    ready = threading.Event()
    threading.Thread(target=serve, args=(path, ready, directory), daemon=True).start()
    ready.wait(5)
    # A shape that suits a README: wide enough for the sessions column and the
    # page, short enough to read at the width GitHub renders an image.
    sys.stdout.write("\033[8;32;124t")
    sys.stdout.flush()
    time.sleep(0.4)
    environment = dict(os.environ, VIVA_SOCKET=path, TERM="xterm-256color")
    subprocess.call([CLIENT], cwd=directory, env=environment)


if __name__ == "__main__":
    main()
