#!/usr/bin/env bash
# Drive B7 probe 4: fork-and-snapshot under hostile runtime activity.
# Usage: smalltalk-p4-run.sh <pharo-dir> <probe-dir>
set -uo pipefail

PHARO_DIR="$1"
PROBE_DIR="$2"
WORK="$PHARO_DIR/fork"
VM=(arch -x86_64 "$PHARO_DIR/vm-x64/Pharo.app/Contents/MacOS/Pharo" --headless)
PORT=8971

mkdir -p "$WORK"
cd "$WORK" || exit 1
rm -f p4-events.log p4-result.json p4-load.jsonl p4-vm.log p4-churn.txt p4-fork-*.image p4-fork-*.changes
cp "$PHARO_DIR/Pharo.image" p4.image
cp "$PHARO_DIR/Pharo.changes" p4.changes

"${VM[@]}" p4.image eval "$(cat "$PROBE_DIR/smalltalk-p4-fork-snapshot.st")" >p4-vm.log 2>&1 &
vm_pid=$!

for _ in $(seq 1 160); do
  grep -q listening p4-events.log 2>/dev/null && break
  kill -0 "$vm_pid" 2>/dev/null || break
  sleep 0.25
done
grep -q listening p4-events.log 2>/dev/null || { echo "server never started"; head -5 p4-vm.log; exit 70; }

python3 "$PROBE_DIR/smalltalk-load.py" "$PORT" 32 8 300 >p4-load.jsonl
wait "$vm_pid" 2>/dev/null

echo "=== result ==="
cat p4-result.json 2>/dev/null; echo
echo "=== images the children wrote ==="
ls -la p4-fork-*.image 2>/dev/null || echo "(none)"
echo "=== VM-level complaints in the parent ==="
grep -c 'Bad file descriptor' p4-vm.log 2>/dev/null || true
