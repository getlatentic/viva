#!/usr/bin/env bash
# Drive B7 probe 2 on native ARM64 Squeak: snapshot mid-computation, kill the
# original, restart the saved image, see whether the work continues.
# Usage: squeak-p2-run.sh <squeak-dir> <probe-dir>
set -uo pipefail

SQ="$1"
PROBE_DIR="$2"
VM="$SQ/cog.app/Contents/MacOS/Squeak"
BASE=$(ls "$SQ" | grep -E '^Squeak6.*\.image$' | head -1)

cd "$SQ" || exit 1
rm -f p2s-trace.log p2s-original.log p2s-restored.log
cp "$BASE" p2s.image
cp "${BASE%.image}.changes" p2s.changes

echo "### phase 1: original runs, snapshots itself, keeps going"
"$VM" -headless p2s.image "$PROBE_DIR/squeak-p2-resume.st" >p2s-original.log 2>&1 &
orig=$!

for _ in $(seq 1 160); do
  grep -q snapshot-end p2s-trace.log 2>/dev/null && break
  sleep 0.25
done
grep -q snapshot-end p2s-trace.log 2>/dev/null || { echo "no snapshot happened"; head -5 p2s-original.log; exit 70; }

sleep 4
echo "--- original server: $(curl -s --max-time 5 http://127.0.0.1:8962/ || echo UNREACHABLE)"
echo "--- original server: $(curl -s --max-time 5 http://127.0.0.1:8962/ || echo UNREACHABLE)"
sleep 2

kill -9 "$orig" 2>/dev/null
wait "$orig" 2>/dev/null
echo "--- original killed. Last line it wrote:"
tail -1 p2s-trace.log
tail -1 p2s-trace.log | cut -d' ' -f1 >p2s-cutoff.txt

sleep 2
echo
echo "### phase 2: restart the SAVED image"
python3 -c 'import time; print(int(time.time()*1000))' >p2s-launch.txt
"$VM" -headless p2s.image >p2s-restored.log 2>&1 &
restored=$!
sleep 10
echo "--- restored server: $(curl -s --max-time 5 http://127.0.0.1:8962/ || echo UNREACHABLE)"
echo "--- restored server: $(curl -s --max-time 5 http://127.0.0.1:8962/ || echo UNREACHABLE)"
sleep 5
kill -9 "$restored" 2>/dev/null
wait "$restored" 2>/dev/null
echo "--- restored image stopped"
