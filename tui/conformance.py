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
import subprocess
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(ROOT, "target", "debug", "vivarium-tui")


def build():
    """Build before driving, so the check cannot pass or fail on a stale binary.

    It already did: a fix was made, the unit tests were rebuilt and passed, and
    this check kept failing against the binary from before it."""
    # RELEASE, because that is the one the launcher prefers. Building only
    # debug was the first version, and it meant this suite drove a release
    # binary from before the change under test -- the same stale-artifact trap
    # as running without building at all, wearing a different hat.
    for profile in (["build"], ["build", "--release"]):
        result = subprocess.run(["cargo"] + profile, cwd=ROOT, capture_output=True)
        if result.returncode != 0:
            sys.stderr.write(result.stderr.decode())
            sys.exit(f"cargo {' '.join(profile)} failed")


build()
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
    def __init__(self, cwd, rows=34, cols=120, environment=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            # BARE `vivarium`, which is what a person types. Driving the
            # binary directly leaves the routing untested, and driving
            # `vivarium tui` leaves the bare-name default untested -- and the
            # default is the path almost everybody takes.
            # Through `viva`, the short name, because that is what a person
            # types. It is a symlink to the same launcher, and the launcher
            # resolves symlinks to find its root -- so driving it here is also
            # a check that the resolution still works from the other name.
            launcher = os.path.join(os.path.dirname(ROOT), "bin", "vivarium")
            short = os.path.expanduser("~/.local/bin/viva")
            entry = short if os.path.exists(short) else launcher
            os.execve(entry, [entry], environment or os.environ)
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


def own_daemon(cwd):
    """A daemon of our own, on its own socket, stopped afterwards.

    NOT the one a person is using. An earlier version of this check drove the
    default socket, and its probe prompts went into a real session in a real
    workspace -- because `vivarium live` with no argument attaches to whatever
    is live for that directory. A test that writes into somebody's work is a
    test that has to be apologised for.
    """
    socket_path = os.path.join(tempfile.mkdtemp(), "check.sock")
    environment = dict(os.environ, VIVARIUM_SOCKET=socket_path)
    launcher = os.path.join(os.path.dirname(ROOT), "bin", "vivarium")
    process = subprocess.Popen(
        [launcher, "daemon", "start", "--background"],
        cwd=cwd, env=environment,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    process.wait()
    for _ in range(600):
        if os.path.exists(socket_path):
            time.sleep(0.5)
            return socket_path, environment
        time.sleep(0.5)
    sys.exit("the check's own daemon never came up")


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(ROOT)
    socket_path, environment = own_daemon(cwd)
    client = Client(cwd, environment=environment)
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

        # A new tab is a new session, and it must appear as both.
        before_tabs = client.term.lines()[0]
        client.send(b"\x0e")                       # ctrl-n
        # Starting a session builds an agent and resolves a model, which on a
        # daemon that has not done it yet is not instant.
        client.pump(20.0)
        after_tabs = client.term.lines()[0]
        # ONE MORE than there was, not `two`. The check's own daemon starts
        # with no sessions at all, so asserting a second tab appeared failed on
        # a run where the first one had just been created correctly.
        before_count, after_count = before_tabs.count("│"), after_tabs.count("│")
        if after_count != before_count + 1:
            fail(f"ctrl-n did not add a tab: before={before_tabs!r} after={after_tabs!r}")
        else:
            ok(f"ctrl-n starts a session and opens it in a tab ({before_count} -> {after_count})")

        # And closing the view does not end the session it was showing.
        sessions_before = sum(1 for l in client.term.lines() if l.startswith("│>") or l.startswith("│ "))
        client.send(b"\x17")                       # ctrl-w
        client.pump(2.0)
        closed_count = client.term.lines()[0].count("│")
        if closed_count != after_count - 1:
            fail(f"ctrl-w did not close the tab: {client.term.lines()[0]!r}")
        elif not any("idle" in l or "working" in l for l in client.term.lines()):
            fail("closing the tab took the session with it")
        else:
            ok("ctrl-w closes the view and leaves the session running")
        _ = sessions_before

        # Finding a session that is not running -- the question the sidebar
        # cannot answer, and most sessions are its answer.
        client.send(b"\x10")                       # ctrl-p
        client.pump(4.0)
        if "find a session" not in client.term.text():
            print(client.term.text())
            fail("ctrl-p opened no picker")
        else:
            found = [l for l in client.term.lines() if "msg" in l]
            if not found:
                print(client.term.text())
                fail("the picker listed nothing")
            else:
                ok(f"ctrl-p lists {len(found)} recorded session(s)")
                client.send(b"vite")
                client.pump(4.0)
                narrowed = [l for l in client.term.lines() if "msg" in l]
                if not narrowed:
                    ok("searching narrowed to nothing (no match in this workspace)")
                elif len(narrowed) < len(found):
                    ok(f"typing narrows the list: {len(found)} -> {len(narrowed)}")
                else:
                    fail(f"typing did not narrow the list: {len(found)} -> {len(narrowed)}")
        # Resume the one that is highlighted. A recorded session is a file,
        # not a running thing, so continuing it is starting -- and the daemon
        # publishes what it loaded, which is what makes it visible here. It
        # also gives the scroll check below something to scroll.
        client.send(b"\r")
        client.pump(8.0)
        if "find a session" in client.term.text():
            fail("enter did not close the picker")
        else:
            ok("enter resumes the highlighted session")
        # HOME first. A resumed conversation opens at its newest output, like
        # any other, so the first thing said in it is above the window -- the
        # earlier version of this check looked at the visible rows and reported
        # a missing prompt while the transcript held it three screens up.
        client.pump(4.0)
        client.send(b"\x1b[H")
        client.pump(2.0)
        body = "\n".join(client.term.lines()[2:-5])
        if "›" not in body:
            print("\n".join(client.term.lines()[:12]))
            fail("the resumed conversation shows no earlier prompt")
        else:
            ok("a resumed session shows what was said in it, from the top")
        client.send(b"\x1b[F")                     # End, back to following
        client.pump(1.0)

        # Scrolling back must reveal something that was not on screen.
        bottom = client.term.text()
        client.send(b"\x1b[5~" * 4)
        client.pump(1.5)
        scrolled = client.term.text()
        if scrolled == bottom:
            fail("paging up changed nothing on screen "
                 "(is there more conversation than fits?)")
        elif "scrolled" not in scrolled:
            fail("the client did not say it had stopped following")
        else:
            ok("paging up reveals earlier output and says it is not following")
        client.send(b"\x1b[F")                     # End
        client.pump(1.5)
        if "scrolled" in client.term.text():
            fail("End did not return to following")
        else:
            ok("End returns to the newest output")

        # A SLASH LINE IS NEVER A PROMPT. `/quit` used to be sent to the
        # model, which politely said goodbye while the client stayed put.
        client.send(b"/nonsense\r")
        client.pump(3.0)
        frame = client.term.text()
        if "not a command" not in frame:
            print(frame)
            fail("an unknown slash command was not refused locally")
        elif "Goodbye" in frame or "assist" in frame:
            fail("the unknown command was answered by the model")
        else:
            ok("an unknown slash command is refused, not forwarded")

        client.send(b"/help\r")
        client.pump(2.0)
        if "/detach" not in client.term.text():
            fail("/help listed nothing")
        else:
            ok("/help answers locally")

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

        # Leaving must give the terminal back -- and `/quit` must be a way to
        # leave, not something to send.
        client.send(b"/quit\r")
        client.pump(3.0)
        if "\x1b[?1049l" not in client.raw:
            fail("/quit did not leave")
        else:
            ok("/quit leaves the client")
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
        launcher = os.path.join(os.path.dirname(ROOT), "bin", "vivarium")
        subprocess.run([launcher, "daemon", "stop"], env=environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} conformance failure(s)")
        sys.exit(1)
    print("conformance: all invariants hold")


# Guarded, because this file is imported for its terminal model. Without it,
# importing the model ran the whole suite as a side effect.
if __name__ == "__main__":
    main()
