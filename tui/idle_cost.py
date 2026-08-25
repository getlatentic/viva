"""What viva costs while nothing is happening.

WHY THIS EXISTS. Every other check measures bytes written, heap size, or the
time one frame takes. A client that repainted the whole transcript thirty times
a second passed all of them: it wrote nothing to the terminal, its heap was
flat, and each frame was still half a millisecond. It burned 85% of a core for
a day and no check could see it.

So this one measures the thing those miss -- CPU actually consumed over a
window of wall-clock, and resident memory -- for a client and a daemon that are
connected, idle, and being left alone. Idle is the case worth guarding: a busy
client is allowed to work, and nothing that is working is a surprise.

    python3 tui/idle_cost.py

WHAT IT DOES NOT DO. It does not reproduce the 85% that prompted it. Every
attempt to stage that -- an empty client, a client holding a transcript, a
daemon killed, its socket directory removed, reconnect pointed at the real
launcher -- costs nothing here, on the build that had the suspected bugs still
in it. So this is a floor, not a regression test for that fault: it says the
ordinary idle states are free, and it would catch a client that started
repainting or restarting a daemon on a timer. Whatever those two processes were
doing is still unexplained.

Every number is measured here. Nothing is asserted from a previous run.
"""
import fcntl
import os
import pty
import shutil
import subprocess
import struct
import sys
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT = os.path.join(ROOT, "tui", "target", "release", "viva-tui")
LAUNCHER = os.path.join(ROOT, "bin", "viva")

# A core is 100. An idle client that repaints costs tens of these; one that
# waits costs a fraction of one. The gap is wide enough that the threshold does
# not have to be delicate.
IDLE_CPU_LIMIT = 2.0
WINDOW = 10

failures = []


def ok(message):
    print(f"  ok    {message}")


def fail(message):
    print(f"  FAIL  {message}")
    failures.append(message)


def cpu_seconds(pid):
    """CPU consumed by PID so far, in seconds."""
    out = subprocess.run(["ps", "-p", str(pid), "-o", "time="],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    total = 0.0
    for part in out.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


def daemon_starts():
    """How many daemon processes exist right now, across the machine.

    Counted rather than timed. A start that fails leaves nothing to measure
    afterwards, and the cost is paid whether or not it succeeds.
    """
    listing = subprocess.run(["pgrep", "-fc", "entry.lisp daemon"],
                             capture_output=True, text=True).stdout.strip()
    return int(listing) if listing.isdigit() else 0


def resident_mb(pid):
    out = subprocess.run(["ps", "-p", str(pid), "-o", "rss="],
                         capture_output=True, text=True).stdout.strip()
    return round(int(out) / 1024, 1) if out else None


def cost_over(pid, seconds=WINDOW):
    """CPU as a percentage of one core, measured across a real window."""
    before = cpu_seconds(pid)
    if before is None:
        return None, None
    time.sleep(seconds)
    after = cpu_seconds(pid)
    if after is None:
        return None, None
    return round((after - before) / seconds * 100, 2), resident_mb(pid)


def start_daemon(environment):
    subprocess.run([LAUNCHER, "daemon", "start", "--background"],
                   env=environment, capture_output=True, timeout=300)
    socket_path = environment["VIVA_SOCKET"]
    for _ in range(120):
        if os.path.exists(socket_path):
            return
        time.sleep(0.5)
    raise SystemExit("the daemon never listened")


def daemon_pid(environment):
    """The pid of OUR daemon, asked of the daemon rather than guessed.

    Matching `entry.lisp daemon` across the process table finds every daemon on
    the machine, and the first version of this took the last one -- so it timed
    a stale process from some earlier run and reported 2 MB for an SBCL image
    that is twelve. A check measuring the wrong process is worse than no check:
    it reports success on evidence about something else.
    """
    answer = subprocess.run([LAUNCHER, "daemon", "status"], env=environment,
                            capture_output=True, text=True, timeout=300).stdout
    for word in answer.replace(",", " ").split():
        if word.isdigit():
            return int(word)
    return None


def open_client(environment, directory):
    """A client that has connected and drawn, or a failure saying it did not.

    ASSERTED, not assumed. A client that died at startup costs no CPU either,
    and an earlier probe cheerfully reported 0% for one that had already exited
    with a broken pipe.
    """
    primary, replica = pty.openpty()
    # A SIZE FIRST. A pty opens at zero by zero, and a full-screen client with
    # no room draws nothing -- which reads as an idle client costing nothing,
    # the exact answer this check exists to distrust.
    fcntl.ioctl(primary, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    client = subprocess.Popen([CLIENT], stdin=replica, stdout=replica, stderr=replica,
                              env=environment, cwd=directory, start_new_session=True)
    time.sleep(4)
    if client.poll() is not None:
        raise SystemExit("the client exited before it could be measured")
    os.set_blocking(primary, False)
    try:
        drawn = os.read(primary, 200000)
    except BlockingIOError:
        drawn = b""
    if b"sessions" not in drawn:
        raise SystemExit(f"the client never drew a frame; it wrote {len(drawn)} bytes")
    return client, primary, replica


def measure_with_a_transcript():
    directory = tempfile.mkdtemp(prefix="viva-idle-full-")
    socket_path = os.path.join(directory, "scripted.sock")
    daemon = subprocess.Popen(
        [sys.executable, "-c",
         "import importlib.util, sys, threading;"
         f"spec = importlib.util.spec_from_file_location('shot', {os.path.join(ROOT, 'tools', 'screenshot.py')!r});"
         "shot = importlib.util.module_from_spec(spec); spec.loader.exec_module(shot);"
         "shot.serve(sys.argv[1], threading.Event(), sys.argv[2])",
         socket_path, directory],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(80):
        if os.path.exists(socket_path):
            break
        time.sleep(0.25)
    if not os.path.exists(socket_path):
        fail("the scripted daemon never listened")
        return

    # THE REAL LAUNCHER, deliberately. Reconnect starts a daemon when it cannot
    # connect, and a daemon start is an SBCL image -- 1.3 seconds of CPU. Every
    # earlier version of this check pointed VIVA_BIN at /usr/bin/false and so
    # priced the one thing that was actually expensive at zero.
    environment = dict(os.environ, VIVA_SOCKET=socket_path, TERM="xterm-256color",
                       VIVA_BIN=LAUNCHER, VIVA_JOURNAL=os.path.join(directory, "journal"))
    primary, replica = pty.openpty()
    fcntl.ioctl(primary, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    client = subprocess.Popen([CLIENT], stdin=replica, stdout=replica, stderr=replica,
                              env=environment, cwd=directory, start_new_session=True)
    time.sleep(5)
    os.set_blocking(primary, False)
    try:
        drawn = os.read(primary, 400000)
    except BlockingIOError:
        drawn = b""
    if b"picker" not in drawn:
        fail("the scripted transcript never reached the screen, so this measures nothing")
        client.kill(); daemon.kill()
        os.close(primary); os.close(replica)
        return

    daemon.kill()
    # AND THE DIRECTORY WITH IT. A daemon start that can still bind the socket
    # succeeds on the first try, which is the happy path and not the one that
    # costs anything. What was found running for a day was a client whose
    # socket lived in a temporary directory that had since been removed, so
    # every start failed and the next was always due.
    shutil.rmtree(directory, ignore_errors=True)
    time.sleep(2)
    if client.poll() is not None:
        fail("the client exited when the daemon went away, rather than waiting")
    else:
        # DAEMON STARTS, COUNTED. The client's own CPU does not include the
        # processes it spawns, and a daemon start is an SBCL image costing 1.3
        # seconds of CPU. A client retrying one every few seconds is expensive
        # in a way that timing the client alone reports as free.
        before = daemon_starts()
        cpu, memory = cost_over(client.pid)
        started = daemon_starts() - before
        print(f"  daemon starts asked for  {started:>6} in {WINDOW}s")
        if started <= 1:
            ok(f"a client that cannot reconnect stops paying for daemon starts ({started})")
        else:
            fail(f"a client that cannot reconnect asked for {started} daemon starts "
                 f"in {WINDOW}s, at about 1.3s of CPU each")
        print(f"  client with transcript,")
        print(f"  daemon gone              {cpu:>6}% of a core   {memory} MB")
        if cpu is not None and cpu <= IDLE_CPU_LIMIT:
            ok(f"a client holding a conversation costs no core when the daemon goes ({cpu}%)")
        else:
            fail(f"a client holding a conversation is spending {cpu}% of a core with no daemon")
    client.kill()
    os.close(primary)
    os.close(replica)


def main():
    if not os.path.exists(CLIENT):
        raise SystemExit(f"no client at {CLIENT} -- "
                         "cargo build --release --manifest-path tui/Cargo.toml")

    directory = tempfile.mkdtemp(prefix="viva-idle-")
    environment = dict(os.environ,
                       VIVA_SOCKET=os.path.join(directory, "idle.sock"),
                       VIVA_JOURNAL=os.path.join(directory, "journal"),
                       TERM="xterm-256color")

    print(f"idle cost, measured over {WINDOW}s windows on this machine\n")
    start_daemon(environment)
    engine = daemon_pid(environment)

    client, primary, replica = open_client(environment, directory)

    cpu, memory = cost_over(client.pid)
    print(f"  client idle, daemon up   {cpu:>6}% of a core   {memory} MB")
    if cpu is not None and cpu <= IDLE_CPU_LIMIT:
        ok(f"an idle client costs no core ({cpu}%)")
    else:
        fail(f"an idle client is spending {cpu}% of a core doing nothing")

    if engine is None:
        fail("could not find the daemon this check started")
    else:
        cpu, memory = cost_over(engine, seconds=5)
        print(f"  daemon idle              {cpu:>6}% of a core   {memory} MB")
        if cpu is not None and cpu <= IDLE_CPU_LIMIT:
            ok(f"an idle daemon costs no core ({cpu}%)")
        else:
            fail(f"an idle daemon is spending {cpu}% of a core doing nothing")

    # THE CASE THAT WAS MISSED. A daemon that goes away and cannot be restarted
    # is not an error the client reports once and forgets -- it is a state it
    # sits in, and what it costs while sitting there is the whole question.
    subprocess.run([LAUNCHER, "daemon", "stop"], env=environment,
                   capture_output=True, timeout=300)
    time.sleep(2)
    if client.poll() is None:
        cpu, memory = cost_over(client.pid)
        print(f"  client, daemon gone      {cpu:>6}% of a core   {memory} MB")
        if cpu is not None and cpu <= IDLE_CPU_LIMIT:
            ok(f"a client whose daemon went away costs no core ({cpu}%)")
        else:
            fail(f"a client whose daemon went away is spending {cpu}% of a core")
    else:
        fail("the client exited when the daemon went away, rather than waiting")

    client.kill()
    os.close(primary)
    os.close(replica)

    # THE CASE THE EMPTY CLIENT CANNOT SHOW. What a lost daemon costs is the
    # cost of laying the conversation out again, so a client with nothing on
    # screen reports nothing however badly it is behaving. This one is served a
    # real transcript first, by the scripted daemon the screenshot tool uses.
    measure_with_a_transcript()

    print()
    if failures:
        print(f"idle cost: {len(failures)} failure(s)")
        return 1
    print("idle cost: nothing is spent while nothing happens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
