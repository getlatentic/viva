#!/usr/bin/env bash
# Drive B7 probe 4b: the fork-snapshot soak.
# Usage: smalltalk-p4b-run.sh <pharo-dir> <probe-dir>
set -uo pipefail

PHARO_DIR="$1"
PROBE_DIR="$2"
WORK="$PHARO_DIR/fork"
VM=(arch -x86_64 "$PHARO_DIR/vm-x64/Pharo.app/Contents/MacOS/Pharo" --headless)
PORT=8973

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -f p4b-events.log p4b-result.json p4b-load.jsonl p4b-vm.log p4b-churn.txt p4b-fork-*.image p4b-fork-*.changes
cp "$PHARO_DIR/Pharo.image" p4b.image
cp "$PHARO_DIR/Pharo.changes" p4b.changes

"${VM[@]}" p4b.image eval "$(cat "$PROBE_DIR/smalltalk-p4b-fork-soak.st")" >p4b-vm.log 2>&1 &
vm_pid=$!

for _ in $(seq 1 160); do
  grep -q listening p4b-events.log 2>/dev/null && break
  kill -0 "$vm_pid" 2>/dev/null || break
  sleep 0.25
done
grep -q listening p4b-events.log 2>/dev/null || { echo "server never started"; head -5 p4b-vm.log; exit 70; }

# Long enough to cover the whole soak; the image stops the server itself.
python3 "$PROBE_DIR/smalltalk-load.py" "$PORT" 280 8 300 >p4b-load.jsonl &
load=$!
wait "$vm_pid" 2>/dev/null
kill -9 "$load" 2>/dev/null; wait "$load" 2>/dev/null

echo "=== result ==="
cat p4b-result.json 2>/dev/null; echo
echo "=== images on disk (rotated) ==="
ls p4b-fork-*.image 2>/dev/null | wc -l
echo "=== zombie children still around ==="
pgrep -P "$vm_pid" 2>/dev/null | wc -l
