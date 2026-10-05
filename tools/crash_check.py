"""A daemon killed with SIGKILL mid-turn, and what comes back.

Four places a crash can land, each against a daemon from this checkout with a
stub model on localhost, so nothing is sent anywhere and nothing is paid for:

  a model request in flight   the turn carries on; a retried prompt is not run twice
  an unsafe call in flight    it is not run again; the model is told it was cut off
  a harmless call in flight   it runs again, once
  a prompt waiting behind     acknowledged before the crash, it still runs, once

  python3 tools/crash_check.py
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from upgrade_check import Client, FAILURES, check, fail, ok  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCHER = os.path.join(ROOT, "bin", "viva")


class Model(BaseHTTPRequestHandler):
    """Chat completions, streamed. After a tool result it says what came back;
    otherwise the prompt decides what it asks for."""

    home = ""

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        messages = body.get("messages", [])
        last = messages[-1] if messages else {}
        prompt = next((m.get("content") or "" for m in reversed(messages) if m.get("role") == "user"), "")
        if last.get("role") == "tool":
            chunks = self.say(f"finished: {(last.get('content') or '')[:40]}")
        elif "run the command" in prompt:
            chunks = self.call("bash", {"command": f"echo ran >> {self.home}/bash-runs; sleep 60"})
        elif "look it up" in prompt:
            chunks = self.call("slow_lookup", {})
        else:
            if "slow" in prompt:
                time.sleep(4)
            chunks = self.say(f"answered: {prompt}")
        # The daemon this answers may have been killed while it waited, which
        # is the point of the check, not a fault in it.
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    @staticmethod
    def say(text):
        return [{"choices": [{"index": 0, "delta": {"role": "assistant", "content": text}}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}]

    @staticmethod
    def call(name, arguments):
        return [{"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
                    {"index": 0, "id": f"call-{name}-{time.time_ns()}", "type": "function",
                     "function": {"name": name, "arguments": json.dumps(arguments)}}]}}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}]


class Daemon:
    """A daemon in a home of its own, which can be killed outright and started
    again over the same home."""

    def __init__(self, label):
        self.home = tempfile.mkdtemp(prefix=f"viva-crash-{label}-")
        self.project = os.path.join(self.home, "project")
        os.makedirs(self.project)
        self.model = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        Model.home = self.home
        threading.Thread(target=self.model.serve_forever, daemon=True).start()
        endpoint = f"http://127.0.0.1:{self.model.server_address[1]}/v1/chat/completions"
        with open(os.path.join(self.home, "auth.json"), "w") as out:
            json.dump({"ollama": {"endpoint": endpoint, "models": ["stub"]}}, out)
        # A harmless tool that takes long enough to be caught in the middle.
        tool = os.path.join(self.home, "tools", "slow_lookup")
        os.makedirs(tool)
        with open(os.path.join(tool, "tool.json"), "w") as out:
            json.dump({"name": "slow_lookup", "description": "Looks something up, slowly.",
                       "exec": ["/bin/sh", "run"], "replay": "safe", "parameters": []}, out)
        with open(os.path.join(tool, "run"), "w") as out:
            out.write(f"#!/bin/sh\necho x >> {self.home}/lookup-runs\nsleep 5\necho looked\n")
        self.path = f"/tmp/viva-crash-{os.getpid()}-{label}.sock"
        self.environment = dict(os.environ, VIVA_HOME=self.home, VIVA_SOCKET=self.path,
                                VIVA_JOURNAL=os.path.join(self.home, "journal"))
        for key in [k for k in self.environment if k.endswith("_API_KEY")]:
            del self.environment[key]
        self.process = None
        self.log = open(os.path.join(self.home, "daemon.log"), "a")

    def start(self):
        self.process = subprocess.Popen([LAUNCHER, "daemon", "start"], env=self.environment,
                                        stdout=self.log, stderr=subprocess.STDOUT, cwd=self.project)
        for _ in range(900):
            try:
                return Client(self.path)
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("the daemon did not start")

    def kill(self):
        os.kill(self.process.pid, signal.SIGKILL)
        self.process.wait()

    def lines(self, name):
        try:
            with open(os.path.join(self.home, name)) as found:
                return len(found.readlines())
        except FileNotFoundError:
            return 0

    def prompts_written(self, text):
        """How many times TEXT reached a transcript as a person's prompt."""
        count = 0
        for directory, _, files in os.walk(os.path.join(self.home, "sessions")):
            for name in files:
                with open(os.path.join(directory, name)) as transcript:
                    for line in transcript:
                        entry = json.loads(line)
                        payload = entry.get("payload") or {}
                        if entry.get("kind") == "message" and payload.get("role") == "user":
                            content = payload.get("content")
                            texts = [content] if isinstance(content, str) else \
                                [block.get("text", "") for block in content or [] if isinstance(block, dict)]
                            count += sum(1 for t in texts if t == text)
        return count

    def close(self, keep):
        if self.process and self.process.poll() is None:
            subprocess.run([LAUNCHER, "daemon", "stop"], env=self.environment, capture_output=True, timeout=60)
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill()
        subprocess.run(["pkill", "-f", f"{self.home}/"], capture_output=True)
        self.model.shutdown()
        self.log.close()
        if keep:
            print(f"  daemon home kept: {self.home}")
        else:
            shutil.rmtree(self.home, ignore_errors=True)


def ended(client, session, turn, timeout=90):
    return client.wait(lambda e: e.get("session") == session and e.get("event") in
                       ("turn.completed", "turn.failed", "turn.cancelled")
                       and e["data"].get("turn") == turn, timeout=timeout)


def started(client, session, turn):
    return [e for e in client.events(session)
            if e.get("event") == "turn.started" and e["data"].get("turn") == turn]


def wait_for(predicate, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return False


def session_in(client, daemon):
    reply = client.ask(type="session.start", cwd=daemon.project, model="ollama/stub")
    return reply["session"]["id"]


def scenario(label, body):
    print(label)
    daemon = Daemon(label.split()[0])
    failures = len(FAILURES)
    try:
        body(daemon)
    except Exception as problem:  # noqa: BLE001 - a crash of the check is a failure to report
        fail(f"the check itself failed: {problem!r}")
    finally:
        daemon.close(keep=len(FAILURES) > failures)


def request_in_flight(daemon):
    client = daemon.start()
    session = session_in(client, daemon)
    reply = client.ask(type="prompt", session=session, text="slow", request="a-1")
    turn = reply["turn"]
    client.wait(lambda e: e.get("event") == "turn.started" and e["data"].get("turn") == turn)
    time.sleep(1)
    daemon.kill()
    ok("killed with the model request in flight")
    client = daemon.start()
    again = client.ask(type="prompt", session=session, text="slow", request="a-1")
    check(again.get("duplicate") is True and again.get("turn") == turn,
          "the retried prompt is recognised as the turn it already was", str(again))
    client.ask(type="session.attach", session=session, since=0)
    done = ended(client, session, turn)
    check(done and done["event"] == "turn.completed" and done["data"].get("text") == "answered: slow",
          "the turn carried on to its answer", str(done))
    check(any(e["data"].get("resumed") for e in started(client, session, turn)),
          "it was marked resumed")
    check(daemon.prompts_written("slow") == 1, "the prompt is in the conversation once",
          f"{daemon.prompts_written('slow')} times")


def unsafe_call_in_flight(daemon):
    client = daemon.start()
    session = session_in(client, daemon)
    turn = client.ask(type="prompt", session=session, text="run the command")["turn"]
    check(wait_for(lambda: daemon.lines("bash-runs") == 1), "the command started")
    daemon.kill()
    ok("killed with the command running")
    client = daemon.start()
    client.ask(type="session.attach", session=session, since=0)
    done = ended(client, session, turn)
    check(done and done["event"] == "turn.completed", "the turn carried on to its end", str(done))
    check((done or {}).get("data", {}).get("text", "").startswith("finished: Interrupted"),
          "the model was told the command was cut off", str(done))
    time.sleep(1)
    check(daemon.lines("bash-runs") == 1, "the command did not run a second time",
          f"{daemon.lines('bash-runs')} runs")


def safe_call_in_flight(daemon):
    client = daemon.start()
    session = session_in(client, daemon)
    turn = client.ask(type="prompt", session=session, text="look it up")["turn"]
    check(wait_for(lambda: daemon.lines("lookup-runs") == 1), "the lookup started")
    daemon.kill()
    ok("killed with the lookup running")
    client = daemon.start()
    client.ask(type="session.attach", session=session, since=0)
    done = ended(client, session, turn)
    check(done and (done["data"].get("text") or "").startswith("finished: looked"),
          "the lookup ran again and the turn finished on its answer", str(done))
    check(daemon.lines("lookup-runs") == 2, "it ran exactly once more", f"{daemon.lines('lookup-runs')} runs")


def queued_prompt(daemon):
    client = daemon.start()
    session = session_in(client, daemon)
    first = client.ask(type="prompt", session=session, text="slow")["turn"]
    client.wait(lambda e: e.get("event") == "turn.started" and e["data"].get("turn") == first)
    waiting = client.ask(type="prompt", session=session, text="queued one", request="d-2")
    second = waiting["turn"]
    check(waiting.get("success") and not waiting.get("duplicate"), "the waiting prompt was acknowledged")
    daemon.kill()
    ok("killed with a prompt acknowledged and waiting")
    client = daemon.start()
    client.ask(type="session.attach", session=session, since=0)
    check(ended(client, session, first), "the running turn carried on")
    done = ended(client, session, second)
    check(done and done["data"].get("text") == "answered: queued one",
          "the waiting prompt ran after it", str(done))
    again = client.ask(type="prompt", session=session, text="queued one", request="d-2")
    check(again.get("duplicate") is True and again.get("turn") == second, "a retry of it is a duplicate")
    time.sleep(1)
    check(len(started(client, session, second)) == 1, "it ran once")
    check(daemon.prompts_written("queued one") == 1, "it is in the conversation once")


def main():
    scenario("request — a model request in flight", request_in_flight)
    scenario("unsafe — an unsafe tool call in flight", unsafe_call_in_flight)
    scenario("safe — a harmless tool call in flight", safe_call_in_flight)
    scenario("queued — a prompt acknowledged and waiting", queued_prompt)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} crash failure(s)")
        sys.exit(1)
    print("crash: every acknowledged prompt survived, and nothing unsafe ran twice")


if __name__ == "__main__":
    main()
