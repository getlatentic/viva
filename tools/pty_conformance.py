"""The terminal invariants, driven over a real pty against a real daemon."""
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

ROOT = sys.argv[1]
CUP = re.compile(r"\x1b\[(\d*);(\d*)H")
# Every sequence the TUI is allowed to emit. One that is not here is a failure:
# it means the TUI grew a sequence this model has never been checked against.
KNOWN = re.compile(
    r"\x1b\[(?:"
    r"\d*;\d*H"          # cursor position
    r"|2J"               # erase all
    r"|[0-9;]*m"         # colour and weight
    r"|\?1049[hl]"       # alternate screen
    r"|\?25[hl]"         # cursor visibility
    r"|\?100[026][hl]"   # mouse reporting
    r"|\?1002[hl]"
    r"|\?1006[hl]"
    r"|>\d*u|<u|\?u"     # kitty keyboard
    r")"
)


class Terminal:
    """Only the sequences the TUI emits. Not an emulator; see the shell script."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.pending = ""
        self.clear()

    def reshape(self, rows, cols):
        """Change size the way a terminal does: KEEP what is there.

        Clearing here was the first version and it was unfaithful in the exact
        direction that matters. A real terminal does not discard its content on
        resize -- that is the whole reason a fresh frame buffer must clear it,
        and a model that clears would have shown a clean frame whether or not
        the program under test ever did. The check would have passed on the
        broken build."""
        kept = self.grid
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        for r in range(min(rows, len(kept))):
            for c in range(min(cols, len(kept[r]))):
                self.grid[r][c] = kept[r][c]
        self.row = min(self.row, rows - 1)
        self.col = min(self.col, cols - 1)

    def clear(self):
        self.grid = [[" "] * self.cols for _ in range(self.rows)]
        self.row = self.col = 0

    def feed(self, text):
        """Apply TEXT, holding back an escape sequence that is not all here yet.

        The pending buffer is not a nicety. Output arrives in chunks at
        whatever boundary the pty chose, so a sequence is routinely split in
        half -- and a model without a buffer renders the tail of it as
        literal text. The frame then shows `;5>240;0;38;5;240m` where a border
        should be, which is corruption invented by the observer. A real
        terminal buffers here; a model that does not is not modelling it."""
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
                while end < len(text) and text[end] not in "HJKmhlu":
                    end += 1
                if end >= len(text):
                    # The terminator has not arrived. Wait for it rather than
                    # painting the parameters onto the screen.
                    self.pending = text[i:]
                    return
                body = text[i:end + 1]
                if body.endswith("J") or body.endswith("?1049h"):
                    self.clear()
                i = end + 1
                continue
            ch = text[i]
            i += 1
            if ch in "\n\r":
                continue
            if 0 <= self.row < self.rows and 0 <= self.col < self.cols:
                self.grid[self.row][self.col] = ch
                self.col += 1

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]

    def text(self):
        return "\n".join(self.lines())


def live_session_ids():
    """The daemon's session ids for this repository, newest last."""
    import subprocess
    out = subprocess.run([os.path.join(ROOT, "bin", "viva"), "daemon", "status"],
                         capture_output=True, text=True, cwd=ROOT).stdout
    return [line.split()[0] for line in out.splitlines()
            if line.startswith("  s") and ROOT in line]


class Session:
    def __init__(self, rows=30, cols=100, target=None, fresh=False):
        """A client. TARGET attaches to one named session, FRESH makes a new one.

        Without either, `viva live` picks whichever live session belongs to
        this directory -- and with several open that is not the one the last
        client used. A reattach check that does not name its session is
        checking that SOME session has the text, which is not the property."""
        binary = os.path.join(ROOT, "bin", "viva")
        argv = [binary, "live"]
        if target:
            argv.append(target)
        elif fresh:
            argv.append("--new")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execv(binary, argv)
        self.rows, self.cols = rows, cols
        self.set_size(rows, cols)
        self.raw = ""
        self.term = Terminal(rows, cols)

    def set_size(self, rows, cols):
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

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
            text = chunk.decode("utf-8", "replace")
            self.raw += text
            self.term.feed(text)

    def body(self):
        """The panes, without the input box and status line.

        Searching the WHOLE screen for a prompt matches it on the input line
        while it is still being typed -- so a check for "the prompt reached the
        transcript" passed before Enter had even been pressed. That is the
        third time a check in this file has matched the wrong region and
        reported a feature working."""
        return "\n".join(self.term.lines()[:-4])

    def wait_for(self, needle, seconds, label, where=None):
        stop = time.time() + seconds
        while time.time() < stop:
            self.pump(0.4)
            haystack = (where or self.term.text)()
            if needle in haystack:
                return
        print(self.term.text())
        fail(f"timed out waiting for {label}")

    def send(self, data):
        os.write(self.fd, data)

    def resize(self, rows, cols):
        self.set_size(rows, cols)
        os.kill(self.pid, signal.SIGWINCH)
        # The model KEEPS its content, as a terminal does. If the program
        # fails to clear, the stale cells are still there and the check sees
        # them -- which is the entire point.
        self.term.reshape(rows, cols)
        self.pump(2.5)

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


def prompts(session):
    """How many input prompts are on screen. Exactly one is a whole frame.

    The prompt rather than the sessions pane: the layout DROPS side panes on a
    narrow terminal, by design, so counting them fails at 40 columns for a
    correct reason. The input box is present at every size the full layout
    applies to, which makes it the thing that is one-or-broken."""
    return sum(1 for line in session.term.lines() if line.lstrip().startswith("│ >"))


def marked_session(session):
    """The name of the session carrying the current-session marker."""
    for line in session.term.lines():
        stripped = line.strip()
        if stripped.startswith("│>"):
            # The NAME, not the row: the row carries a right-hand border whose
            # column moves with the width, so comparing rows across a resize
            # compares the padding and reports a change that did not happen.
            #
            # Borders stripped from BOTH ends. Taking the last field was the
            # first version and it returned the right-hand border character --
            # so the check compared "│" with "│" and could not fail, which is
            # the shape of check this whole file exists to stop shipping.
            parts = stripped.strip("│").lstrip(">").split()
            for part in parts:
                # Marks and the selection bracket are furniture, not names.
                # This filter has now been wrong twice -- first returning the
                # right-hand border, then the bracket -- and each time the
                # check compared furniture with itself and could not fail.
                if part not in ("*", "-", "!", "~", ".", "│", ">", "[", "[-", "[*", "[!"):
                    return part.lstrip("[")
    return None


def check_unknown_sequences(session):
    leftover = KNOWN.sub("", session.raw)
    stray = re.findall(r"\x1b\[[^\x07\x1b]{0,20}", leftover)
    if stray:
        fail(f"the TUI emitted {len(stray)} sequence(s) this model does not know: "
             f"{[s.encode() for s in stray[:3]]}")
    else:
        ok("every sequence emitted is one this model accounts for")


def main():
    before = set(live_session_ids())
    session = Session(fresh=True)
    try:
        session.wait_for("viva", 300, "the first frame")

        # 2, 3, 4 -- resize in both directions and in a storm.
        for rows, cols in ((30, 60), (30, 120), (20, 60), (34, 100), (12, 40), (30, 100)):
            session.resize(rows, cols)
            count = prompts(session)
            if count != 1:
                print(session.term.text())
                fail(f"{rows}x{cols}: {count} input prompts after resize")
                break
            wide = [line for line in session.term.lines() if len(line) > cols]
            if wide:
                fail(f"{rows}x{cols}: a row outran the terminal")
                break
        else:
            ok("six resizes, shrinking and growing, left exactly one frame each")

        # 8 -- a click lands on the same logical target before and after a resize.
        session.resize(30, 100)
        session.send(b"\x1b[<0;6;5M\x1b[<0;6;5m")     # click a session row
        session.pump(2.0)
        after_click = marked_session(session)
        session.resize(28, 90)
        after_resize = marked_session(session)
        if after_click is None or after_click in ("│", ">"):
            fail(f"no session name was read from the marker row: {after_click!r}")
        elif after_click != after_resize:
            fail(f"the selection moved across a resize: {after_click} -> {after_resize}")
        else:
            ok(f"the clicked session ({after_click}) survives a resize")

        # 7 -- paging never scrolls past either end.
        session.send(b"\x1b[6~" * 10)                  # page down at the bottom
        session.pump(1.0)
        bottom = session.term.text()
        session.send(b"\x1b[5~" * 40)                  # page up hard
        session.pump(1.5)
        session.send(b"\x1b[6~" * 60)                  # and all the way back
        session.pump(1.5)
        if prompts(session) != 1:
            fail("paging damaged the frame")
        else:
            ok("paging to both extremes leaves one intact frame")

        # 5 -- what the person said must survive a detach and reattach. The
        # local echo showed it once and lost it; only an event can persist.
        mine = [s for s in live_session_ids() if s not in before]
        if not mine:
            fail("could not tell which session this client created")
            return
        target = mine[-1]
        marker = "conformance probe %d" % os.getpid()
        session.send(marker.encode() + b"\r")
        session.wait_for("> " + marker, 60, "the prompt to reach the transcript",
                         where=session.body)
        ok("a sent prompt appears in the transcript")

        session.send(b"\x03")            # detach
        session.pump(3.0)
        again = Session(target=target)
        try:
            again.wait_for("viva", 300, "the reattached frame")
            again.pump(4.0)
            found = again.body().count("> " + marker)
            if found == 0:
                print(again.term.text())
                fail(f"the prompt did not survive a reattach; looked for {'> ' + marker!r}")
            elif found != 1:
                fail(f"the prompt was replayed {found} times")
            else:
                ok("the prompt survives a reattach, exactly once")
            check_unknown_sequences(again)
        finally:
            again.close()

        check_unknown_sequences(session)
    finally:
        session.close()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} conformance failure(s)")
        sys.exit(1)
    print("conformance: all invariants hold")


main()
