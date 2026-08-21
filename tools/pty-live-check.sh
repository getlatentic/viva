#!/bin/sh
# Does `vivarium live` actually draw a frame?
#
# It compiles, and compiling proves nothing: `vivarium check` reports an
# undefined function as a style warning, so a client that calls something that
# does not exist builds clean and dies on the first keypress. The only evidence
# is a real terminal, a real daemon, and a frame read back off the wire.
#
# So: a pty of a known size, drive it, and assert on what it emitted --
# the alternate screen entered, the title drawn, typing echoed into the input
# line, and the terminal handed back on the way out.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$root" <<'PY'
import os, pty, fcntl, termios, struct, sys, select, time, subprocess

root = sys.argv[1]
ROWS, COLS = 30, 100
vivarium = os.path.join(root, "bin", "vivarium")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execv(vivarium, [vivarium, "live"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

out = b""
def pump(seconds):
    global out
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return
        if not chunk:
            return
        out += chunk

CUP = __import__("re").compile(rb"\x1b\[(\d*);(\d*)H")

def replay(data, rows=ROWS, cols=COLS):
    """The two sequences this client emits, applied to a grid.

    Not a terminal emulator -- #17 ratified against building one, and this is
    not in the product. It is the only way to assert on what a person SEES,
    because a screen that writes just the changed run never puts "> hello" on
    the wire as those seven bytes. That is the feature, and it defeats any
    assertion made against raw output."""
    grid = [[" "] * cols for _ in range(rows)]
    row = col = 0
    i = 0
    while i < len(data):
        if data[i:i+2] == b"\x1b[":
            m = CUP.match(data, i)
            if m:
                row = max(0, int(m.group(1) or 1) - 1)
                col = max(0, int(m.group(2) or 1) - 1)
                i = m.end()
                continue
            end = i + 2
            while end < len(data) and data[end:end+1] not in b"HJKmhlu":
                end += 1
            i = end + 1
            continue
        byte = data[i:i+1]
        if byte in (b"\n", b"\r"):
            i += 1
            continue
        if 0 <= row < rows and 0 <= col < cols:
            grid[row][col] = byte.decode("utf-8", "replace")
            col += 1
        i += 1
    return ["".join(r).rstrip() for r in grid]

def screen_has(text):
    return any(text in line for line in replay(out))

def wait_for_screen(text, seconds, label):
    deadline = time.time() + seconds
    while time.time() < deadline:
        pump(0.4)
        if screen_has(text):
            return True
    print("\n".join(replay(out)))
    sys.exit(f"timed out waiting for {label}")

def wait_for(marker, seconds, label):
    deadline = time.time() + seconds
    while time.time() < deadline:
        pump(0.5)
        if marker in out:
            return True
    print(out.decode(errors="replace")[-3000:])
    sys.exit(f"timed out waiting for {label}")

# The first run compiles the world; give it room.
wait_for(b"\x1b[?1049h", 300, "the alternate screen")
wait_for(b"vivarium", 60, "the title bar")
print("entered the alternate screen and drew a title")

os.write(fd, b"hello")
wait_for_screen("> hello", 30, "typing to reach the input line")
print("typing appears on the input line")

frame = replay(out)
for wanted, label in (("sessions", "the session pane"), ("tasks", "the task pane")):
    if not any(wanted in line for line in frame):
        print("\n".join(frame))
        sys.exit(f"{label} is missing -- #45 wants them visible together")
print("sessions, output and tasks are on one screen")

before = len(out)
pump(2.0)
idle = len(out) - before
print(f"idle for two seconds wrote {idle} bytes")
if idle > 2000:
    sys.exit(f"an idle client is repainting: {idle} bytes with nothing happening")

# Backspace the line away, then Ctrl-C: idle, so it leaves.
os.write(fd, b"\x7f" * 5)
pump(1.5)
if screen_has("> hello"):
    print("\n".join(replay(out)))
    sys.exit("backspace did not erase the input line")
print("backspace erases what was typed")
os.write(fd, b"\x03")
pump(5.0)

if b"\x1b[?1049l" not in out:
    sys.exit("it did not leave the alternate screen -- the scrollback is gone")
if b"\x1b[?25h" not in out:
    sys.exit("it did not show the cursor again")
print("left the alternate screen and restored the cursor")

try:
    os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    pass
print("ok")
PY
