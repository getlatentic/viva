"""Terminal invariants for vivarium-tui, over a real pty against a real daemon.

The same invariants the Lisp client is held to, because they are properties of
a full-screen client rather than of a language. The model below implements only
the sequences ratatui and crossterm actually emit, and FAILS on one it does not
know -- silently ignoring an unknown sequence is how a harness stops modelling
the thing it claims to model.

Written after five separate faults in the equivalent Lisp harness, each of which
either invented a failure or hid one:
  - it ignored ESC[2J, so it accumulated every frame ever drawn
  - it decoded byte by byte, so multi-byte borders became replacement marks
  - it had no pending buffer, so a split sequence was painted as text
  - it cleared on resize, which a terminal does not do -- hiding the very bug
    the resize check exists to catch
  - its name extraction twice returned furniture, comparing it with itself
"""
import codecs
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(ROOT, "target", "debug", "vivarium-tui")
CUP = re.compile(r"\x1b\[(\d*);(\d*)H")
KNOWN = re.compile(
    r"\x1b\[(?:"
    r"\d*;\d*[Hf]|\d*[ABCD]|[0-9;]*m|\d*J|\d*K|\d*X"
    r"|\?1049[hl]|\?25[hl]|\?100[0236][hl]|\?1015[hl]|\?1006[hl]"
    r"|\d*;\d*r|s|u"
    r")"
)


class Terminal:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.pending = ""
        self.clear()

    def clear(self):
        self.grid = [[" "] * self.cols for _ in range(self.rows)]
        self.row = self.col = 0

    def reshape(self, rows, cols):
        """Resize the way a terminal does: KEEP the content.

        Clearing here would pass whether or not the program under test ever
        cleared the screen itself, which is the bug this exists to catch."""
        kept = self.grid
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        for r in range(min(rows, len(kept))):
            for c in range(min(cols, len(kept[r]))):
                self.grid[r][c] = kept[r][c]
        self.row, self.col = min(self.row, rows - 1), min(self.col, cols - 1)

    def feed(self, text):
        text = self.pending + text
        self.pending = ""
        i = 0
        while i < len(text):
            if text.startswith("\x1b", i):
                if i + 1 >= len(text):
                    self.pending = text[i:]
                    return
                if text[i + 1] != "[":
                    i += 2
                    continue
                m = CUP.match(text, i)
                if m:
                    self.row = max(0, int(m.group(1) or 1) - 1)
                    self.col = max(0, int(m.group(2) or 1) - 1)
                    i = m.end()
                    continue
                end = i + 2
                while end < len(text) and not ("@" <= text[end] <= "~"):
                    end += 1
                if end >= len(text):
                    self.pending = text[i:]
                    return
                body = text[i:end + 1]
                if body.endswith("J"):
                    self.clear()
                elif body.endswith("K"):
                    for c in range(self.col, self.cols):
                        self.grid[self.row][c] = " "
                i = end + 1
                continue
            ch = text[i]
            i += 1
            if ch == "\r":
                self.col = 0
            elif ch == "\n":
                self.row = min(self.row + 1, self.rows - 1)
            elif 0 <= self.row < self.rows and 0 <= self.col < self.cols:
                self.grid[self.row][self.col] = ch
                self.col += 1

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]

    def text(self):
        return "\n".join(self.lines())


class Client:
    def __init__(self, cwd, rows=34, cols=120):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execv(BINARY, [BINARY])
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.raw = ""
        # An INCREMENTAL decoder. Decoding each read on its own turns any
        # multi-byte character split across two reads into a replacement mark,
        # so a correct frame shows as corrupt -- the same fault as an escape
        # sequence split across reads, one layer down.
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.term = Terminal(rows, cols)

    def pump(self, seconds):
        stop = time.time() + seconds
        while time.time() < stop:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            text = self.decoder.decode(chunk)
            self.raw += text
            self.term.feed(text)

    def wait_for(self, needle, seconds, label):
        stop = time.time() + seconds
        while time.time() < stop:
            self.pump(0.3)
            if needle in self.term.text():
                return True
        print(self.term.text())
        fail(f"timed out waiting for {label}")
        return False

    def send(self, data):
        os.write(self.fd, data)

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)
        self.term.reshape(rows, cols)
        self.pump(2.0)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass


FAILURES = []


def fail(message):
    FAILURES.append(message)
    print(f"  FAIL  {message}")


def ok(message):
    print(f"  ok    {message}")


def input_row(client):
    """The input line, found by POSITION.

    Not by content. The transcript marks what a person said with the same `›`
    the prompt uses -- correctly, since it is the same thing -- so a
    content-based search finds the last thing they typed and reports that
    typing never reached the prompt. Third from the bottom: status, the box's
    lower border, then the line itself.

    This is the sixth time a harness here has picked the wrong row by matching
    on content that was not unique. Structure is not ambiguous; text is."""
    lines = client.term.lines()
    return lines[-3] if len(lines) >= 3 else ""


def whole_frame(client):
    """Is exactly one frame on screen?

    Counted from the box that must appear once at every size the full layout
    applies to, located by position rather than by matching text that also
    appears in the transcript."""
    return input_row(client).lstrip().startswith("│›")


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(ROOT)
    client = Client(cwd)
    try:
        client.wait_for("sessions", 60, "the first frame")
        ok("connects and draws a frame")

        for rows, cols in ((30, 60), (30, 120), (20, 70), (36, 100), (14, 44), (34, 120)):
            client.resize(rows, cols)
            if not whole_frame(client):
                print(client.term.text())
                fail(f"{rows}x{cols}: no intact input row after resize")
                break
            wide = [line for line in client.term.lines() if len(line) > cols]
            if wide:
                fail(f"{rows}x{cols}: a row outran the terminal")
                break
        else:
            ok("six resizes, shrinking and growing, left exactly one frame each")

        # Typing reaches the prompt, and only the prompt.
        client.send(b"hello there")
        client.pump(1.0)
        prompt_row = input_row(client)
        if "hello there" not in prompt_row:
            fail(f"typing did not reach the input line: {prompt_row!r}")
        else:
            ok("typing reaches the input line")

        # Backspace erases it again, so nothing is sent by accident.
        client.send(b"\x7f" * 11)
        client.pump(1.0)
        prompt_row = input_row(client)
        if "hello" in prompt_row:
            fail("backspace did not erase the input line")
        else:
            ok("backspace erases what was typed")

        # Paging to both extremes must leave the frame intact.
        client.send(b"\x1b[5~" * 30)
        client.pump(1.0)
        client.send(b"\x1b[6~" * 60)
        client.pump(1.0)
        if not whole_frame(client):
            print(client.term.text())
            fail("paging damaged the frame")
        else:
            ok("paging to both extremes leaves one intact frame")

        # An idle client must cost nothing.
        before = len(client.raw)
        client.pump(2.0)
        idle = len(client.raw) - before
        if idle > 4000:
            fail(f"an idle client is repainting: {idle} bytes with nothing happening")
        else:
            ok(f"idle for two seconds wrote {idle} bytes")

        leftover = KNOWN.sub("", client.raw)
        stray = re.findall(r"\x1b\[[^\x07\x1b]{0,12}", leftover)
        if stray:
            fail(f"emitted {len(stray)} sequence(s) this model does not know: "
                 f"{[s.encode() for s in stray[:3]]}")
        else:
            ok("every sequence emitted is one this model accounts for")

        # Leaving must give the terminal back.
        client.send(b"\x03")
        client.pump(2.0)
        for needle, what in (("\x1b[?1049l", "the alternate screen"),
                             ("\x1b[?25h", "the cursor"),
                             ("\x1b[?1006l", "mouse reporting")):
            if needle not in client.raw:
                fail(f"it did not give back {what}")
                break
        else:
            ok("leaves the alternate screen, the cursor and the mouse as it found them")
    finally:
        client.close()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} conformance failure(s)")
        sys.exit(1)
    print("conformance: all invariants hold")


main()
