#!/usr/bin/env python3
"""Correlate B7 probe 1's client log with the image's snapshot window.

Requests the client sent after the image deliberately stopped its server are
not failures of the snapshot; they are the load generator outliving the probe,
and are excluded.
"""

import json
import sys

events = {}
for line in open(sys.argv[2]):
    parts = line.split()
    events[" ".join(parts[:-1])] = int(parts[-1])

snap_start, snap_end, stopped = events["snapshot-begin"], events["snapshot-end"], events["stopped"]

records = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
in_window = [r for r in records if r["sentMs"] < stopped]
ok = [r for r in in_window if r["status"] == 200 and not r["error"]]
bad = [r for r in in_window if r not in ok]

in_flight = [r for r in in_window if r["sentMs"] < snap_start < r["gotMs"]]
in_flight_lost = [r for r in in_flight if r["error"] or r["status"] != 200]


def latency(rs):
    return sorted(r["gotMs"] - r["sentMs"] for r in rs)


def pct(values, p):
    return round(values[min(len(values) - 1, int(len(values) * p))], 1) if values else None


completions = sorted(r["gotMs"] for r in ok)
gaps = [(b - a, a) for a, b in zip(completions, completions[1:])]
worst_gap, worst_at = max(gaps) if gaps else (0, 0)

before = latency([r for r in ok if r["gotMs"] < snap_start - 500])
during = latency([r for r in ok if snap_start <= r["gotMs"] <= snap_end + 1000])
after = latency([r for r in ok if r["gotMs"] > snap_end + 1000])

print(json.dumps({
    "imagePauseMs": snap_end - snap_start,
    "requestsInWindow": len(in_window),
    "requestsOk": len(ok),
    "requestsFailed": len(bad),
    "failures": [{"id": r["id"], "error": r["error"]} for r in bad][:5],
    "inFlightAtSnapshotStart": len(in_flight),
    "inFlightLost": len(in_flight_lost),
    "completionsDuringPause": sum(1 for c in completions if snap_start < c < snap_end),
    "worstCompletionGapMs": round(worst_gap, 1),
    "worstGapAtSnapshotOffsetMs": round(worst_at - snap_start, 1),
    "latencyBeforeMs": {"n": len(before), "p50": pct(before, .5), "max": pct(before, 1.0)},
    "latencyAcrossPauseMs": {"n": len(during), "p50": pct(during, .5), "max": pct(during, 1.0)},
    "latencyAfterMs": {"n": len(after), "p50": pct(after, .5), "max": pct(after, 1.0)},
}, indent=2))
