#!/usr/bin/env bash
# B8 axis 1 driver. One FRESH NODE per fault, because half of these are supposed
# to kill it -- a shared node would let the first fatal case silently invalidate
# every case after it.
#
# Each run is bounded by a hard timeout. A fault that wedges every scheduler
# produces no output and no exit: the timeout is the measurement, and the
# heartbeat file says how far the bystander got before it stopped.

set -uo pipefail
cd "$(dirname "$0")"

OUT="${OUT_DIR:-/tmp/b8-faults}"
mkdir -p "$OUT"
# Half of these faults abort the VM, which writes a crash dump to the cwd.
export ERL_CRASH_DUMP="$OUT/erl_crash.dump"
ERL_ROOT="$(erl -noshell -eval 'io:format("~s",[code:root_dir()]), halt().')"

echo "== building =="
erlc -o "$OUT" fault_probe.erl bad_nif.erl || exit 1
cc -shared -undefined dynamic_lookup -fPIC \
   -I"$ERL_ROOT/usr/include" -o "$OUT/bad_nif.so" bad_nif.c || exit 1
echo "built into $OUT"

# fault:timeout_seconds:extra_erl_flags
#
# +t 65536 leaves the atom table large enough to boot (a fresh node interns
# ~15-20k atoms) and small enough to exhaust in seconds. An earlier run used
# +t 8192 and the node died before the bystander wrote a single tick, which
# measured the flag rather than the fault.
FAULTS=(
  "exception:10:"
  "runaway:10:"
  "code_server:10:"
  "memory_capped:20:"
  "memory_capped_heap:20:"
  "atom_exhaustion:30:+t 65536"
  "bad_nif:15:+S 1"
  "bad_nif_saturate:15:"
  "bad_nif_dirty_saturate:15:"
  "memory:12:"
)

echo
echo "== running =="
for entry in "${FAULTS[@]}"; do
  fault="${entry%%:*}"
  rest="${entry#*:}"
  limit="${rest%%:*}"
  flags="${rest#*:}"
  beat="$OUT/heartbeat-$fault.txt"
  : > "$beat"

  start=$(python3 -c 'import time; print(time.time())')
  # -k 4: SIGTERM at the limit, SIGKILL four seconds later. Needed because a
  # node whose schedulers are all wedged in native code CANNOT PROCESS SIGTERM
  # -- measured, not assumed: one such node survived SIGTERM and 4m43s against a
  # 15s limit, and died instantly on SIGKILL. Exit 137 vs 124 records which.
  # shellcheck disable=SC2086
  output=$(timeout -k 4 "$limit" erl -noshell -pa "$OUT" $flags \
             -eval "fault_probe:main([$fault, '$beat'])" 2>&1)
  status=$?
  elapsed=$(python3 -c "import time; print(round(time.time() - $start, 2))")
  ticks=$(wc -c < "$beat" | tr -d ' ')

  case $status in
    0)   verdict="CONTAINED -- node survived and reported" ;;
    124) verdict="WEDGED -- never reported, died on SIGTERM" ;;
    137) verdict="WEDGED -- never reported, IGNORED SIGTERM, needed SIGKILL" ;;
    *)   verdict="NODE DIED (exit $status)" ;;
  esac

  echo "--- $fault ${flags:+[$flags]}"
  echo "    verdict        : $verdict"
  echo "    elapsed        : ${elapsed}s (limit ${limit}s)"
  echo "    bystander ticks: $ticks of ~110 (10ms tick over a 1200ms run)"
  echo "$output" | grep -E '^RESULT' | sed 's/^/    /'
  echo "$output" | grep -vE '^RESULT' | head -3 | sed 's/^/    | /'
done
