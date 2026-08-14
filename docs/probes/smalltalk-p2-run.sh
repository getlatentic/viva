#!/usr/bin/env bash
# Drive B7 probe 2: snapshot mid-computation, kill the original, restart the
# saved image, and see whether the work continues or restarts.
# Usage: smalltalk-p2-run.sh <pharo-dir> <probe-dir>
#
# --no-quit on the restart matters: with no subcommand the default Pharo
# command line handler prints its usage and quits, which tears the resumed
# image down a few hundred milliseconds after it has resumed.
set -uo pipefail

PHARO_DIR="$1"
PROBE_DIR="$2"
WORK="$PHARO_DIR/work"
VM=(arch -x86_64 "$PHARO_DIR/vm-x64/Pharo.app/Contents/MacOS/Pharo" --headless)

mkdir -p "$WORK"
rm -f "$WORK/p2-trace.log" "$WORK/p2-original.log" "$WORK/p2-restored.log"
cp "$PHARO_DIR/Pharo.image" "$WORK/p2.image"
cp "$PHARO_DIR/Pharo.changes" "$WORK/p2.changes"
cd "$WORK" || exit 1

echo "### phase 1: original image runs, snapshots itself, keeps going"
"${VM[@]}" p2.image eval "$(cat "$PROBE_DIR/smalltalk-p2-resume.st")" >p2-original.log 2>&1 &
orig=$!

for _ in $(seq 1 160); do
  grep -q snapshot-end p2-trace.log 2>/dev/null && break
  sleep 0.25
done
grep -q snapshot-end p2-trace.log 2>/dev/null || { echo "no snapshot happened"; head -5 p2-original.log; exit 70; }

sleep 4
echo "--- original server: $(curl -s --max-time 5 http://127.0.0.1:8952/ || echo UNREACHABLE)"
echo "--- original server: $(curl -s --max-time 5 http://127.0.0.1:8952/ || echo UNREACHABLE)"
sleep 2

kill -9 "$orig" 2>/dev/null
wait "$orig" 2>/dev/null
echo "--- original killed. Last line it wrote:"
tail -1 p2-trace.log
tail -1 p2-trace.log | cut -d' ' -f1 >p2-cutoff.txt

sleep 2
echo
echo "### phase 2: restart the SAVED image"
launch=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "$launch" >p2-launch.txt
"${VM[@]}" p2.image --no-quit >p2-restored.log 2>&1 &
restored=$!
sleep 10
echo "--- restored server: $(curl -s --max-time 5 http://127.0.0.1:8952/ || echo UNREACHABLE)"
echo "--- restored server: $(curl -s --max-time 5 http://127.0.0.1:8952/ || echo UNREACHABLE)"
sleep 5
kill -9 "$restored" 2>/dev/null
wait "$restored" 2>/dev/null
echo "--- restored image stopped"
