#!/usr/bin/env bash
# Drive B7 probe 5: the headless autonomy audit.
# Usage: squeak-p5-run.sh <squeak-dir> <probe-dir>
#
# An operation that puts up a modal dialog cannot report that it did, so the
# watchdog here is the instrument: if the image stops writing progress, whatever
# it last said it was ATTEMPTING is the operation that wants a human. The suite
# then restarts past it, so one blocking operation does not hide the rest.
set -uo pipefail

SQ="$1"
PROBE_DIR="$2"
VM="$SQ/cog.app/Contents/MacOS/Squeak"
BASE=$(ls "$SQ" | grep -E '^Squeak6.*\.image$' | head -1)
BUDGET=26   # seconds per attempt: image boot plus room for the op to finish

cd "$SQ" || exit 1
rm -f p5-log.txt p5-start.txt
: >p5-log.txt
cp "$BASE" p5.image
cp "${BASE%.image}.changes" p5.changes

start=0
for round in $(seq 1 20); do
  echo "$start" >p5-start.txt
  "$VM" -headless p5.image "$PROBE_DIR/squeak-p5-autonomy.st" >/dev/null 2>&1 &
  vm=$!
  for _ in $(seq 1 $((BUDGET * 4))); do
    grep -q '^SUITE = FINISHED' p5-log.txt && break
    sleep 0.25
  done
  kill -9 "$vm" 2>/dev/null; wait "$vm" 2>/dev/null

  grep -q '^SUITE = FINISHED' p5-log.txt && { echo "suite completed"; break; }

  # Whatever is still ATTEMPTING with no verdict after it is the blocker.
  stuck=$(grep 'ATTEMPTING' p5-log.txt | tail -1 | cut -d' ' -f1)
  if [ -z "$stuck" ]; then echo "image never reached the suite"; break; fi
  echo "$stuck = BLOCKED (no verdict within ${BUDGET}s -- waiting on a human)" >>p5-log.txt
  # Count distinct operations already decided, and resume after the blocker.
  start=$(grep -cE ' = (ATTEMPTING)$' p5-log.txt)
  echo "blocked on: $stuck -- restarting at index $start"
done

echo
echo "=== audit ==="
grep -vE ' = ATTEMPTING$' p5-log.txt | awk '!seen[$1]++'
