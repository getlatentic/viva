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
            # THIS TREE'S launcher, never the one on PATH. `~/.local/bin/viva`
            # points at whichever checkout was installed, and driving it from
            # a worktree ran a client from one tree against a daemon from
            # another: a reconnect check passed on a client that could not
            # reconnect, because a stale tab looks like a surviving one.
            launcher = os.path.join(os.path.dirname(ROOT), "bin", "vivarium")
            os.execve(launcher, [launcher], environment or os.environ)
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
        # A client that has left takes its pty with it, and writing to the
        # far end of a closed one raises EIO. Teardown keeps typing on
        # purpose -- to prove the terminal was handed back -- so the write
        # failing is the expected end, not a fault to raise here.
        try:
            os.write(self.fd, data)
        except OSError:
            pass

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
    typing never reached the prompt. Second from the bottom: the box's lower
    edge, then the line itself. The box's top edge carries the status.

    This is the sixth time a harness here has picked the wrong row by matching
    on content that was not unique. Structure is not ambiguous; text is."""
    lines = client.term.lines()
    return lines[-2] if len(lines) >= 2 else ""


def status_row(client):
    """The input box's top edge, which is where the status is said."""
    lines = client.term.lines()
    return lines[-3] if len(lines) >= 3 else ""


def menu_region(client):
    """The rows the slash menu draws into: directly above the input box.

    Scoped by POSITION. Searching the whole frame for a command name finds it
    in the transcript -- /help prints them, and so does a refusal -- and this
    check has now made that mistake three times under three different names.
    Structure is not ambiguous; text is."""
    # Its own box, found by walking up from the input box to the top border.
    # A fixed window of rows was the first attempt and it reached into the
    # transcript -- which, in this workspace, contains a recorded `/quit`,
    # because that is the bug that started all of this. The check then reported
    # a menu that had narrowed perfectly as one that had not narrowed at all.
    lines = client.term.lines()
    if len(lines) < 6:
        return ""
    rows = []
    index = len(lines) - 4          # box bottom, input, box top, then here
    while index >= 0:
        rows.append(lines[index])
        if lines[index].lstrip().startswith("╭"):
            break
        index -= 1
    return "\n".join(rows)


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
    # Its own journal too. On the default root, every session this check
    # starts was written into the real home -- and once a daemon brings back
    # whatever was live when the last one stopped, they would come back in
    # the person's own daemon.
    own = tempfile.mkdtemp()
    socket_path = os.path.join(own, "check.sock")
    environment = dict(os.environ, VIVARIUM_SOCKET=socket_path,
                       VIVARIUM_JOURNAL=os.path.join(own, "journal"))
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
    # The short name resolves to a launcher. What a person types is `viva`,
    # and the launcher finds its root by following the link -- so the link has
    # to land on a bin/vivarium, whichever checkout it was installed from.
    short = os.path.expanduser("~/.local/bin/viva")
    if os.path.islink(short):
        target = os.path.realpath(short)
        if os.path.basename(target) == "vivarium" and os.access(target, os.X_OK):
            ok(f"`viva` resolves to a launcher ({os.path.dirname(os.path.dirname(target))})")
        else:
            fail(f"`viva` resolves to {target}, which is not a launcher")

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

        # A session nothing has been said in opens on the welcome: what will
        # answer, what this directory has retained, what was said here before,
        # and which keys do what. A blank page is a claim that nothing is here.
        page = "\n".join(client.term.lines()[1:-3])
        missing = [word for word in ("keys", "learned here", "earlier sessions", "ctrl-p")
                   if word not in page]
        if missing:
            print("---- frame at failure ----")
            print("\n".join(client.term.lines()))
            fail(f"the fresh session shows no welcome; missing {missing}")
        else:
            ok("a fresh session opens on the welcome")

        # A bang line runs here and comes back as a call. Through a real
        # daemon, so the whole chain is under test -- and a path dropped on
        # the prompt is not mistaken for a command, which is what sent a
        # dragged screenshot to the refusal instead of to the model.
        client.send(b"!echo conformance-bang\r")
        client.pump(8.0)
        page = "\n".join(client.term.lines()[1:-3])
        if "conformance-bang" not in page:
            print("---- frame at failure ----")
            print("\n".join(client.term.lines()))
            fail("a bang line did not run")
        else:
            ok("! runs a command here, and it reads as a call")

        # TYPED, NOT SENT. Pressing Enter forwards it to the model, which is a
        # paid request on every run of this check and leaves a short recorded
        # session behind -- one the resume check below then picked, and it
        # needs a long one. The classification shows in the menu: a path being
        # typed is not a command being typed, so no menu opens.
        client.send(b"/var/folders/x/screenshot.png")
        client.pump(1.5)
        typed_menu = menu_region(client)
        client.send(b"\x7f" * 40)
        client.pump(1.0)
        if "/find" in typed_menu or "/help" in typed_menu:
            fail(f"a dropped path opened the command menu: {typed_menu!r}")
        else:
            ok("a dropped path is not mistaken for a command")

        # No column for work that is not happening. Located by POSITION -- the
        # column's title sits at the right of the row under the tabs -- and
        # not by searching the frame, where `/help` prints a blurb with the
        # word `running` in it. That is the seventh time here.
        head = client.term.lines()[1]
        if "running" in head[-34:]:
            fail(f"the running column is there with nothing running: {head[-34:]!r}")
        else:
            ok("no column for work that is not happening")

        # The sessions column is there by default and ctrl-b puts it away.
        # It holds the conversations you have had here, which is what a person
        # comes back for -- and it is a quarter of the width, so it goes.
        def column_shown():
            return any(row.lstrip().startswith("sessions") for row in client.term.lines()[1:4])
        if not column_shown():
            fail("the sessions column is not there to begin with")
        else:
            client.send(b"\x02")                   # ctrl-b: away
            client.pump(1.5)
            gone = not column_shown()
            client.send(b"\x02")                   # ctrl-b: back
            client.pump(1.5)
            if not gone:
                fail("ctrl-b did not hide the sessions column")
            elif not column_shown():
                fail("ctrl-b did not bring the sessions column back")
            else:
                ok("the sessions column is there, and ctrl-b puts it away and back")

        # And closing the view does not end the session it was showing: the
        # tab bar counts the running sessions, and the count must not fall.
        def running(row):
            found = re.search(r"(\d+) session", row)
            return int(found.group(1)) if found else 0
        sessions_before = running(client.term.lines()[0])
        client.send(b"\x17")                       # ctrl-w
        client.pump(2.0)
        closed_count = client.term.lines()[0].count("│")
        if closed_count != after_count - 1:
            fail(f"ctrl-w did not close the tab: {client.term.lines()[0]!r}")
        elif running(client.term.lines()[0]) < sessions_before:
            fail(f"closing the tab took the session with it: {client.term.lines()[0]!r}")
        else:
            ok("ctrl-w closes the view and leaves the session running")

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
        # CLEAR THE FILTER, then move to a session that HAS messages.
        #
        # Two workspace assumptions bit here in turn. The narrowing check types
        # a word that matches in one workspace only, so elsewhere the list was
        # empty and Enter resumed nothing. Clearing the filter fixed that and
        # exposed the second: the newest recorded session is the empty one
        # ctrl-n created earlier in this very run, so resuming it correctly
        # showed no conversation. Neither was a product fault.
        client.send(b"\x7f" * 8)
        client.pump(2.0)
        # THE LONGEST one, not the first with anything in it. The scroll check
        # below needs more conversation than fits on a screen, and picking the
        # first non-empty session landed on a two-message one often enough to
        # make that check fail for a reason it was not testing.
        def messages(row):
            # The number immediately BEFORE `msg`. Taking the largest digit in
            # the row took the age -- `16 msg  20h ago` counted as twenty.
            found = re.search(r"(\d+)\s+msg", row)
            return int(found.group(1)) if found else 0
        rows = [l for l in client.term.lines() if " msg" in l]
        wanted = max(range(len(rows)), key=lambda index: messages(rows[index])) if rows else 0
        client.send(b"\x1b[B" * wanted)          # down to it
        client.pump(1.5)

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
            print("---- frame at failure ----")
            print("\n".join(client.term.lines()))
            print("---- end ----")
            fail("the resumed conversation shows no earlier prompt")
        else:
            ok("a resumed session shows what was said in it, from the top")
        client.send(b"\x1b[F")                     # End, back to following
        client.pump(1.0)

        # THE DAEMON DIES AND COMES BACK, under a live client. The session it
        # was running is the one with a conversation, resumed a moment ago; it
        # must come back under the same id, with the same conversation, into
        # the same tab -- and the client must get there on its own. A client
        # that reported `the daemon closed the connection` and stopped made
        # `survives a restart` mean `if you restart the client too`.
        launcher = os.path.join(os.path.dirname(ROOT), "bin", "vivarium")
        # THE TAB OF THE SESSION WITH A CONVERSATION. The client starts a
        # session for this directory at launch, and one nothing was said in is
        # correctly NOT brought back -- so the bar legitimately loses a tab,
        # and comparing the whole row reported that as a lost session.
        def tabs_of(row):
            return [part.strip() for part in row.split("+")[0].split("│") if part.strip()]
        tabs_before = tabs_of(client.term.lines()[0])

        transcript_before = client.term.text()
        subprocess.run([launcher, "daemon", "stop"], env=environment, cwd=cwd,
                       capture_output=True, timeout=120)
        client.pump(3.0)
        if "reconnecting" not in status_row(client):
            fail(f"the client did not say it was reconnecting: {status_row(client)!r}")
        subprocess.run([launcher, "daemon", "start", "--background"], env=environment,
                       cwd=cwd, capture_output=True, timeout=300)
        # Backoff doubles to a five-second cap; a restart that takes the daemon
        # twenty seconds to bring sessions back is answered within thirty.
        client.pump(30.0)
        status = status_row(client)
        tabs_after = tabs_of(client.term.lines()[0])
        if "reconnecting" in status or "lost" in status:
            print("---- frame at failure ----")
            print("\n".join(client.term.lines()))
            fail(f"the client never reconnected: {status!r}")
        # A TAB, not a particular one. The session with a conversation here is
        # the one this check resumed from the picker, and that lives in
        # whichever directory it was recorded in -- so naming the project was
        # asserting where the picker's newest session happened to be. Which
        # session came back is checked below, by its conversation.
        elif not any(tab != "viva" for tab in tabs_after):
            fail(f"no tab survived the restart: {tabs_before!r} -> {tabs_after!r}")
        else:
            ok("the daemon restarts under a live client, and the tab is still there")
        client.send(b"\x1b[H")
        client.pump(2.0)
        body = "\n".join(client.term.lines()[2:-5])
        if "›" not in body:
            print("---- frame at failure ----")
            print("\n".join(client.term.lines()))
            fail("after the restart the conversation is gone")
        else:
            ok("the session came back with its conversation, under the same id")
        client.send(b"\x1b[F")
        client.pump(1.5)

        # Scrolling back must reveal something that was not on screen.
        bottom = client.term.text()
        client.send(b"\x1b[5~" * 4)
        client.pump(1.5)
        scrolled = client.term.text()
        # WHAT THIS RUN HAPPENED TO RESUME may be shorter than the screen, and
        # a view with nothing above it has not failed to scroll. The picker
        # lists newest first and the long conversations are below the fold, so
        # this check cannot choose a tall one. `journal_replay.py` drives the
        # same keys against a transcript known to be tall, which is where the
        # scrolling itself is proven.
        if scrolled == bottom and "scrolled" not in scrolled:
            ok("this session is shorter than the screen, so there is nothing above")
        elif scrolled == bottom:
            fail("paging up changed nothing, with more conversation than fits")
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
        # FORWARDED OR NOT, by structure. Searching the frame for a model's
        # manners found `assist` in the RESUMED conversation above -- the
        # eighth time here that a check matched text it did not own. A command
        # that was forwarded appears as a question, marked like any other.
        page = "\n".join(client.term.lines()[1:-3])
        if "not a command" not in frame:
            print(frame)
            fail("an unknown slash command was not refused locally")
        elif "› /nonsense" in page:
            fail("the unknown command was sent to the model as a question")
        else:
            ok("an unknown slash command is refused, not forwarded")

        # THE MENU. A closed set nobody can see is barely better than no set.
        client.send(b"/")
        client.pump(2.0)
        region = menu_region(client)
        offered = [name for name in ("/find", "/new", "/close", "/quit", "/help")
                   if name in region]
        if len(offered) < 4:
            print(client.term.text())
            fail(f"pressing / offered only {offered}")
        else:
            ok(f"pressing / offers {len(offered)} commands with what they do")

        client.send(b"fi")
        client.pump(1.5)
        narrowed = menu_region(client)
        if "/find" not in narrowed:
            print(client.term.text())
            fail("typing narrowed the menu away from the match")
        elif "/quit" in narrowed:
            print(client.term.text())
            fail("typing did not narrow the menu")
        else:
            ok("typing narrows it to the one that matches")

        # Escape abandons the line, so the menu goes with it.
        client.send(b"\x1b")
        client.pump(1.5)
        if "/find" in menu_region(client) and "/quit" in menu_region(client):
            fail("escape left the menu up")
        else:
            ok("escape dismisses the menu")

        # WHAT IT HAS LEARNED. The whole point of the harness is that it
        # retains; a client that cannot show what it retained is hiding the
        # product.
        client.send(b"\x0c")                       # ctrl-l
        client.pump(4.0)
        panel = client.term.text()
        missing = [w for w in ("notes", "skills", "tools") if w not in panel]
        if missing:
            print(panel)
            fail(f"the learned panel does not list {missing}")
        else:
            ok("ctrl-l shows notes, skills and tools")
        # Any key closes it: a read-only look should not need a second way out.
        client.send(b"x")
        client.pump(1.5)
        if "what this session has learned" in client.term.text():
            fail("the learned panel would not close")
        else:
            ok("any key closes the learned panel")
        # And the counts are on the status line without being asked for.
        if "learned" not in status_row(client):
            fail(f"the status line does not carry the counts: {status_row(client)!r}")
        else:
            ok("the status line carries the counts unasked")

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
