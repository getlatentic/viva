#!/usr/bin/env bash
# Drive B7 probe 1 on native ARM64 Squeak (OpenSmalltalk Cog VM).
# Usage: squeak-p1-run.sh <squeak-dir> <probe-dir>
set -uo pipefail

SQ="$1"
PROBE_DIR="$2"
VM="$SQ/cog.app/Contents/MacOS/Squeak"
BASE=$(ls "$SQ" | grep -E '^Squeak6.*\.image$' | head -1)
PORT=8961

cd "$SQ" || exit 1
rm -f p1s-events.log p1s-result.json p1s-load.jsonl
cp "$BASE" p1s.image
cp "${BASE%.image}.changes" p1s.changes

"$VM" -headless p1s.image "$PROBE_DIR/squeak-p1-snapshot-under-load.st" >p1s-vm.log 2>&1 &
vm_pid=$!

for _ in $(seq 1 120); do
  grep -q listening p1s-events.log 2>/dev/null && break
  kill -0 "$vm_pid" 2>/dev/null || break
  sleep 0.25
done
grep -q listening p1s-events.log 2>/dev/null || { echo "server never started"; head -5 p1s-vm.log; exit 70; }

python3 "$PROBE_DIR/smalltalk-load.py" "$PORT" 18 8 300 >p1s-load.jsonl
sleep 3
kill -9 "$vm_pid" 2>/dev/null
wait "$vm_pid" 2>/dev/null
cat p1s-result.json
