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

CUP = __import__("re").compile(r"\x1b\[(\d*);(\d*)H")

def replay(data, rows=ROWS, cols=COLS):
    """The sequences this client emits, applied to a grid.

    Decoded ONCE, as UTF-8, before walking. The first version decoded byte by
    byte, so every multi-byte character became three replacement marks and the
    whole frame looked corrupt -- a harness bug that reads exactly like a
    rendering bug, which is the worst kind to have in a check.

    Not a terminal emulator -- #17 ratified against building one, and this is
    not in the product. It is the only way to assert on what a person SEES,
    because a screen that writes just the changed run never puts "> hello" on
    the wire as those seven bytes."""
    text = data.decode("utf-8", "replace")
    grid = [[" "] * cols for _ in range(rows)]
    row = col = 0
    i = 0
    while i < len(text):
        if text.startswith("\x1b[", i):
            m = CUP.match(text, i)
            if m:
                row = max(0, int(m.group(1) or 1) - 1)
                col = max(0, int(m.group(2) or 1) - 1)
                i = m.end()
                continue
            end = i + 2
            while end < len(text) and text[end] not in "HJKmhlu":
                end += 1
            i = end + 1
            continue
        ch = text[i]
        if ch in "\n\r":
            i += 1
        else:
            if 0 <= row < rows and 0 <= col < cols:
                grid[row][col] = ch
                col += 1
            i += 1
    return ["".join(r).rstrip() for r in grid]

def screen_has(text):
    return any(text in line for line in replay(out))

def input_line():
    """The input row only.

    A whole-screen search is wrong for this question: a sent prompt is ECHOED
    into the output pane, so `> hello` is on screen precisely BECAUSE Enter
    worked. The first draft of this check read that echo as the input line and
    reported a failure that was the feature."""
    # The input sits INSIDE a three-row box, with the status line below it:
    # ... / box top / input / box bottom / status. Reading rows[-2] found the
    # box's bottom border and reported that nothing had been typed.
    rows = replay(out)
    return rows[-3] if len(rows) >= 3 else ""

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

# ENTER SENDS, and does not type a character. Reported from a real session:
# raw mode leaves ICRNL set, so Enter arrives as 10, which decoded as Ctrl-J
# and typed a `j`. Both bytes are exercised because which one arrives depends
# on flags this program does not own.
os.write(fd, b"\r")
pump(2.0)
if "hello" in input_line():
    print("\n".join(replay(out)))
    sys.exit("Enter did not send: the input line still holds the text")
if "j" in input_line():
    sys.exit(f"Enter typed a character instead of sending: {input_line()!r}")
if not screen_has("> hello"):
    sys.exit("the sent prompt was not echoed into the output")
print("Enter sends, clears the input line, and echoes into the output")

os.write(fd, b"second")
pump(2.0)
if "second" not in input_line():
    sys.exit("typing did not reach the input line")
os.write(fd, b"\n")
pump(2.0)
if "second" in input_line():
    sys.exit("line feed was not treated as Enter")
print("line feed is Enter too")

# TAB CYCLES, more than once. Pressing it once passed the bug that made it
# stop after one move, so this presses it repeatedly and reads the marker.
def marked():
    # The row carrying the current-session marker. Matching on a "/" in the
    # label was the first version and broke the moment the sidebar started
    # showing project names instead of paths -- the check failed while the
    # feature worked.
    # Body rows only. The input line also begins with ">", so a whole-screen
    # search found the prompt and reported the same answer every time --
    # a check that could not fail, which is worse than one that does.
    for line in replay(out)[:-4]:
        # Strip the pane border too, not only whitespace: the marker row now
        # reads "|>   vivarium", and a matcher that only stripped spaces saw a
        # border character and reported the feature broken.
        stripped = line.strip().lstrip("\u2502\u2500|").strip()
        if stripped.startswith(">") and len(stripped) > 1:
            return stripped
    return None

seen = []
for _ in range(4):
    os.write(fd, b"\t")
    pump(1.5)
    seen.append(marked())
distinct = [s for i, s in enumerate(seen) if s and (i == 0 or s != seen[i-1])]
if len(set(x for x in seen if x)) < 2:
    print("\n".join(replay(out)[:12]))
    sys.exit(f"Tab never moved past one session: {seen}")
print(f"Tab cycles: {len(set(x for x in seen if x))} distinct sessions across 4 presses")

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
print()
print("=" * 78)
for line in replay(out)[:20]:
    print(line)
print("=" * 78)
print("ok")
PY
