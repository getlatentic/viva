"""`viva daemon upgrade` against a real daemon: nothing a person can see restarts.

A daemon from this checkout serves two clients, a background job and a turn
that is still running when the upgrade is asked for, with a prompt queued behind
it. The model is a stub on localhost, so nothing is sent anywhere and nothing is
paid for. After the upgrade the check requires the same process, the same
connections, every event exactly once and in order, the job still running and
still reporting, and the queued prompt answered -- by the new image.

  python3 tools/upgrade_check.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# `--program PATH` runs a built image instead of this checkout's launcher, and
# replaces the file before the upgrade the way the installer does.
PROGRAM = sys.argv[sys.argv.index("--program") + 1] if "--program" in sys.argv else None
LAUNCHER = os.path.abspath(PROGRAM) if PROGRAM else os.path.join(ROOT, "bin", "viva")
FAILURES = []


def ok(message):
    print(f"  ok    {message}")


def fail(message):
    print(f"  FAIL  {message}")
    FAILURES.append(message)


def check(condition, message, detail=""):
    if condition:
        ok(message)
    else:
        fail(f"{message}{': ' + detail if detail else ''}")
    return condition


# --- a model that answers without being asked twice --------------------------

SLOW_SECONDS = 4


class Model(BaseHTTPRequestHandler):
    """Chat completions, streamed. `start the job` asks for a background bash
    command; `slow` takes SLOW_SECONDS; anything else is echoed back."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        messages = body.get("messages", [])
        prompt = next((m.get("content") or "" for m in reversed(messages)
                       if m.get("role") == "user"), "")
        answered_tool = messages and messages[-1].get("role") == "tool"
        if "start the job" in prompt and not answered_tool:
            arguments = json.dumps({"command": "i=0; while true; do i=$((i+1)); "
                                               "echo tick-$i; sleep 0.2; done",
                                    "background": True, "name": "ticker"})
            chunks = [{"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
                {"index": 0, "id": "call_1", "type": "function",
                 "function": {"name": "bash", "arguments": arguments}}]}}]},
                      {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}]
        else:
            if "slow" in prompt and not answered_tool:
                time.sleep(SLOW_SECONDS)
            chunks = [{"choices": [{"index": 0, "delta": {"role": "assistant",
                                                          "content": f"answered: {prompt}"}}]},
                      {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}]
        chunks.append({"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3,
                                                "total_tokens": 13}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


# --- a client of the daemon's protocol ---------------------------------------

class Client:
    """One connection. Events and responses are collected on a reader thread,
    so a check can wait for what it expects without losing what came first."""

    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.connect(path)
        self.reader = self.socket.makefile("r", encoding="utf-8")
        self.greeting = json.loads(self.reader.readline())
        self.lines = []
        self.closed = False
        self.lock = threading.Condition()
        self.next_id = 100
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.reader:
            with self.lock:
                self.lines.append(json.loads(line))
                self.lock.notify_all()
        with self.lock:
            self.closed = True
            self.lock.notify_all()

    def send(self, **request):
        self.next_id += 1
        request["id"] = self.next_id
        self.socket.sendall((json.dumps(request) + "\n").encode())
        return self.next_id

    def wait(self, predicate, timeout=60):
        deadline = time.time() + timeout
        with self.lock:
            while True:
                for item in self.lines:
                    if predicate(item):
                        return item
                left = deadline - time.time()
                if left <= 0 or self.closed:
                    return None
                self.lock.wait(left)

    def ask(self, timeout=60, **request):
        wanted = self.send(**request)
        return self.wait(lambda item: item.get("type") == "response" and item.get("id") == wanted,
                         timeout)

    def events(self, session):
        with self.lock:
            return [item for item in self.lines
                    if item.get("session") == session and "seq" in item]


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    home = tempfile.mkdtemp(prefix="viva-upgrade-")
    project = os.path.join(home, "project")
    os.makedirs(project)
    model = ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{model.server_address[1]}/v1/chat/completions"
    with open(os.path.join(home, "auth.json"), "w") as out:
        json.dump({"ollama": {"endpoint": endpoint, "models": ["stub"]}}, out)
    path = os.path.join(home, "viva.sock")
    environment = dict(os.environ, VIVA_HOME=home, VIVA_SOCKET=path,
                       VIVA_JOURNAL=os.path.join(home, "journal"))
    for key in [k for k in environment if k.endswith("_API_KEY")]:
        del environment[key]
    log = open(os.path.join(home, "daemon.log"), "w")
    daemon = subprocess.Popen([LAUNCHER, "daemon", "start"], env=environment,
                              stdout=log, stderr=subprocess.STDOUT, cwd=project)
    job_pid = None
    try:
        print("before the upgrade")
        for _ in range(600):
            try:
                watcher = Client(path)
                break
            except OSError:
                time.sleep(0.1)
        else:
            fail("the daemon did not start")
            return
        pid = watcher.greeting["pid"]
        ok(f"a daemon from this checkout answers, pid {pid}")

        # Empty: no session has started the journal, and there is nothing to
        # wait for. The upgrade after this one is then a second in a row.
        empty = subprocess.run([LAUNCHER, "daemon", "upgrade"], env=environment,
                               capture_output=True, text=True, timeout=900)
        check(empty.returncode == 0 and "nothing restarted" in empty.stdout,
              "a daemon with no sessions upgrades", empty.stdout + empty.stderr)
        check(watcher.ask(type="session.list"), "the connection it had still answers")
        started = Client(path).greeting["started"]

        reply = watcher.ask(type="session.start", cwd=project, model="ollama/stub", label="upgrade")
        if not check(reply and reply.get("success"), "a session starts on the stub model", str(reply)):
            return
        session = reply["session"]["id"]
        second = Client(path)
        check(second.ask(type="session.attach", session=session, since=0).get("success"),
              "a second client watches the same session")

        job = watcher.ask(type="prompt", session=session, text="start the job")
        turn = job.get("turn")
        done = watcher.wait(lambda e: e.get("event") == "turn.completed"
                            and e["data"].get("turn") == turn, timeout=90)
        check(done, "a turn starts a background job through the bash tool")
        def printed(client):
            return "".join(e["data"].get("text", "") for e in client.events(session)
                           if e.get("event") == "tool.output")

        deadline = time.time() + 30
        while "tick-2" not in printed(watcher) and time.time() < deadline:
            time.sleep(0.1)
        check("tick-2" in printed(watcher), "the job's output reaches the watching clients")
        jobs = subprocess.run(["pgrep", "-f", "echo tick-"], capture_output=True, text=True)
        pids = [int(p) for p in jobs.stdout.split()]
        job_pid = pids[0] if pids else None
        check(job_pid, "the job is a running process")

        slow = watcher.ask(type="prompt", session=session, text="slow")["turn"]
        watcher.wait(lambda e: e.get("event") == "turn.started" and e["data"].get("turn") == slow)
        queued = watcher.ask(type="prompt", session=session, text="queued behind the slow one")["turn"]
        if PROGRAM:
            # What get.sh does: a new file renamed over the old, so the running
            # daemon holds a file that is no longer on disk.
            staged = LAUNCHER + ".new"
            shutil.copy2(LAUNCHER, staged)
            os.replace(staged, LAUNCHER)
        print("the upgrade, with a turn running and a prompt queued behind it")
        began = time.time()
        upgrade = subprocess.run([LAUNCHER, "daemon", "upgrade"], env=environment,
                                 capture_output=True, text=True, timeout=900)
        took = time.time() - began
        print("\n".join("    | " + line for line in upgrade.stdout.strip().splitlines()))
        if not check(upgrade.returncode == 0 and "nothing restarted" in upgrade.stdout,
                     f"viva daemon upgrade reports success in {took:.1f}s",
                     upgrade.stdout + upgrade.stderr):
            return
        check("waiting:" in upgrade.stdout, "it said what it waited for")

        print("after the upgrade")
        slow_done = watcher.wait(lambda e: e.get("event") == "turn.completed"
                                 and e["data"].get("turn") == slow, timeout=5)
        check(slow_done, "the running turn finished instead of being cut off")
        fresh = Client(path)
        check(fresh.greeting["pid"] == pid, "the same process serves", f"{fresh.greeting['pid']} != {pid}")
        check(fresh.greeting["started"] > started, "a new image serves it")
        check(daemon.poll() is None, "the daemon process never exited")
        answer = watcher.ask(type="session.list")
        check(answer and answer.get("success"), "the first client's connection still answers")
        answer = second.ask(type="session.list")
        check(answer and answer.get("success"), "the second client's connection still answers")
        listed = [s["id"] for s in (answer or {}).get("sessions", [])]
        check(session in listed, "the session is still running", str(listed))

        released = watcher.wait(lambda e: e.get("event") == "turn.completed"
                                and e["data"].get("turn") == queued, timeout=60)
        check(released and "queued behind" in (released["data"].get("text") or ""),
              "the queued prompt was answered after the upgrade")

        last = max(e["seq"] for e in watcher.events(session))
        later = watcher.wait(lambda e: e.get("event") == "tool.output" and e["seq"] > last, timeout=10)
        check(later, "the job's output still reaches the clients")
        check(job_pid and pid_alive(job_pid), "the job is the same running process")

        for name, client in (("first", watcher), ("second", second)):
            seqs = [e["seq"] for e in client.events(session)]
            gaps = [b for a, b in zip(seqs, seqs[1:]) if b != a + 1]
            check(seqs and not gaps, f"the {name} client saw every event once, in order",
                  f"out of order at {gaps[:5]}")
        replay = fresh.ask(type="session.attach", session=session, since=0)
        final = max(e["seq"] for e in watcher.events(session))
        replayed = fresh.wait(lambda e: e.get("session") == session and e.get("seq") == final, timeout=10)
        seqs = [e["seq"] for e in fresh.events(session)]
        check(replay and replayed and seqs == list(range(1, len(seqs) + 1)),
              "a client attaching now replays the whole stream without a gap")
    finally:
        subprocess.run([LAUNCHER, "daemon", "stop"], env=environment,
                       capture_output=True, timeout=120)
        try:
            daemon.wait(timeout=30)
        except subprocess.TimeoutExpired:
            daemon.kill()
        if job_pid:
            time.sleep(0.5)
            check(not pid_alive(job_pid), "stopping the daemon stops the job it carried over")
        model.shutdown()
        log.close()
        if FAILURES:
            print(f"\ndaemon log: {os.path.join(home, 'daemon.log')}")
        else:
            shutil.rmtree(home, ignore_errors=True)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} upgrade failure(s)")
        sys.exit(1)
    print("upgrade: nothing restarted")


if __name__ == "__main__":
    main()
