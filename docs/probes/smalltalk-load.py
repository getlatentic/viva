#!/usr/bin/env python3
"""External load generator for B7 probe 1.

Runs outside the Pharo image on purpose: an in-image client is a Smalltalk
Process, and snapshot:andQuit: suspends every Process in the image, so an
in-image client would sleep through the very stall it was meant to measure.

Writes one JSON record per request to stdout: id, send time, receive time,
status. Times are POSIX milliseconds, the same clock the image stamps its
event log with.
"""

import json
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

PORT = int(sys.argv[1])
DURATION_S = float(sys.argv[2])
WORKERS = int(sys.argv[3])
WORK_MS = int(sys.argv[4])

records = []
lock = threading.Lock()
counter = [0]
deadline = time.time() + DURATION_S


def next_id():
    with lock:
        counter[0] += 1
        return counter[0]


def worker():
    while time.time() < deadline:
        rid = next_id()
        url = f"http://127.0.0.1:{PORT}/work?id={rid}&ms={WORK_MS}"
        sent = time.time() * 1000
        status, error = None, None
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                response.read()
                status = response.status
        except urllib.error.HTTPError as exc:
            status = exc.code
            error = f"http {exc.code}"
        except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as exc:
            error = f"{type(exc).__name__}: {exc}"
        got = time.time() * 1000
        with lock:
            records.append(
                {"id": rid, "sentMs": sent, "gotMs": got, "status": status, "error": error}
            )


threads = [threading.Thread(target=worker, daemon=True) for _ in range(WORKERS)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()

for record in sorted(records, key=lambda r: r["sentMs"]):
    print(json.dumps(record))
