#!/usr/bin/env bash
# Drive B7 probe 1: Pharo serving under external load, snapshot mid-flight.
# Usage: smalltalk-p1-run.sh <pharo-dir> <probe-dir>
#
# The arm64 Pharo VM aborts at startup on this host ("Could not allocate
# codeZone in the expected place"), so the probe runs the x86_64 VM under
# Rosetta 2. See the report for what that costs.
set -uo pipefail

PHARO_DIR="$1"
PROBE_DIR="$2"
WORK="$PHARO_DIR/work"
VM=(arch -x86_64 "$PHARO_DIR/vm-x64/Pharo.app/Contents/MacOS/Pharo" --headless)
PORT=8951

mkdir -p "$WORK"
rm -f "$WORK/p1-events.log" "$WORK/p1-image.log" "$WORK/p1-load.jsonl"
cp "$PHARO_DIR/Pharo.image" "$WORK/p1.image"
cp "$PHARO_DIR/Pharo.changes" "$WORK/p1.changes"

cd "$WORK" || exit 1

"${VM[@]}" p1.image eval "$(cat "$PROBE_DIR/smalltalk-p1-snapshot-under-load.st")" >p1-image.log 2>&1 &
vm_pid=$!

for _ in $(seq 1 120); do
  grep -q listening p1-events.log 2>/dev/null && break
  kill -0 "$vm_pid" 2>/dev/null || break
  sleep 0.25
done

if ! grep -q listening p1-events.log 2>/dev/null; then
  echo "P1: server never started" >&2
  head -5 p1-image.log >&2
  exit 70
fi

python3 "$PROBE_DIR/smalltalk-load.py" "$PORT" 18 8 300 >p1-load.jsonl
wait "$vm_pid"

grep RESULT p1-image.log || tail -5 p1-image.log
