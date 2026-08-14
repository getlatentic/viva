#!/usr/bin/env bash
# B7 probe 4c: the checkpoint-rate saturation curve.
#
# 4b showed that fork-and-checkpoint never fails but that driving it at 5 Hz
# blows out the parent's stall tail. The engineering number that matters is not
# more fork-success counts, it is the maximum sustained checkpoint frequency
# below a latency budget. This sweeps the spacing and reports the curve.
#
# Usage: smalltalk-p4c-envelope.sh <pharo-dir> <probe-dir>
set -uo pipefail

PHARO_DIR="$1"
PROBE_DIR="$2"
WORK="$PHARO_DIR/fork"
VM=(arch -x86_64 "$PHARO_DIR/vm-x64/Pharo.app/Contents/MacOS/Pharo" --headless)
PORT=8973

mkdir -p "$WORK"; cd "$WORK" || exit 1
printf '%-9s %-7s %6s %6s %6s %7s %8s %9s\n' spacing forks p50 p90 p99 max ">200ms" "cli p99"

for spec in "40 3000" "50 1500" "60 750" "80 375"; do
  set -- $spec; iters=$1; spacing=$2
  rm -f p4b-events.log p4b-result.json p4b-load.jsonl p4b-vm.log p4b-fork-*.image
  cp "$PHARO_DIR/Pharo.image" p4b.image; cp "$PHARO_DIR/Pharo.changes" p4b.changes
  echo "$iters $spacing" >p4b-config.txt

  "${VM[@]}" p4b.image eval "$(cat "$PROBE_DIR/smalltalk-p4b-fork-soak.st")" >p4b-vm.log 2>&1 &
  vm=$!
  for _ in $(seq 1 160); do
    grep -q listening p4b-events.log 2>/dev/null && break
    kill -0 "$vm" 2>/dev/null || break
    sleep 0.25
  done
  duration=$(( iters * spacing / 1000 + 60 ))
  python3 "$PROBE_DIR/smalltalk-load.py" "$PORT" "$duration" 8 300 >p4b-load.jsonl &
  load=$!
  wait "$vm" 2>/dev/null
  kill -9 "$load" 2>/dev/null; wait "$load" 2>/dev/null

  python3 - "$spacing" <<'PY'
import json, sys, pathlib
spacing = sys.argv[1]
stalls = sorted(int(l.split()[2]) for l in pathlib.Path('p4b-events.log').read_text().splitlines()
                if l.startswith('forkstall'))
lat = sorted(r['gotMs'] - r['sentMs'] for r in
             (json.loads(x) for x in pathlib.Path('p4b-load.jsonl').read_text().splitlines() if x.strip())
             if r['status'] == 200)
q = lambda v, p: v[min(len(v) - 1, int(len(v) * p))] if v else 0
print(f"{spacing+'ms':<9} {len(stalls):<7} {q(stalls,.5):>6} {q(stalls,.9):>6} "
      f"{q(stalls,.99):>6} {(stalls[-1] if stalls else 0):>7} "
      f"{sum(1 for s in stalls if s>200):>8} {round(q(lat,.99)):>9}")
PY
done
