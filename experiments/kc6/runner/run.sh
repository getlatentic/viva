#!/bin/sh
# The KC6 cell runner: three gates, then one cell in one image.
#
#   ./run.sh CELL FAMILY ARM REPEAT      e.g. ./run.sh cell f3-agent-surface A 1
#
# Gate 1: the model pin and reachability (preflight's own gates).
# Gate 2: off-peak only -- peak is 01:00-04:00 and 06:00-10:00 UTC, and
#         amendment 13 makes off-peak mandatory. KC6_ALLOW_PEAK=1 overrides
#         for a deliberate, logged exception.
# Gate 3: the meter -- budget.py over everything KC6 has ever spent, plus the
#         pre-battery anchor runs when present. Non-zero means STOP.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
kc6=$(cd "$here/.." && pwd)
root=$(cd "$kc6/../.." && pwd)
results="$kc6/results"
mkdir -p "$results"

set -a; . "$root/.env"; set +a
[ "${DEEPSEEK_MODEL:-}" = "deepseek-v4-flash" ] || {
  echo "MODEL PIN FAILED: '$DEEPSEEK_MODEL' is not deepseek-v4-flash" >&2; exit 1; }

hour=$(date -u +%H)
case "$hour" in
  01|02|03|06|07|08|09)
    [ "${KC6_ALLOW_PEAK:-0}" = "1" ] || {
      echo "PEAK HOURS (${hour}xx UTC): amendment 13 mandates off-peak." >&2
      echo "Come back outside 01-04 and 06-10 UTC, or set KC6_ALLOW_PEAK=1" >&2
      echo "for a deliberate, logged exception." >&2
      exit 1; } ;;
esac

anchors=""
for d in /tmp/kc6-live/.transcripts /tmp/kc6-armb/.transcripts /tmp/kc6-iso/.transcripts; do
  [ -d "$d" ] && anchors="$anchors $d"
done
python3 "$kc6/budget.py" --limit 7.00 "$results" $anchors || exit 1

command=$1; shift
case "$command" in
  cell)
    family=$1; arm=$2; repeat=$3
    out="$results/$family-$arm-r$repeat"
    rm -rf "$out"; mkdir -p "$out"
    echo "=== $family arm $arm repeat $repeat ==="
    sbcl --script "$here/driver.lisp" "$kc6/families/$family" "$arm" "$out"

    # Token columns from the transcripts the run actually wrote, merged with
    # the driver's task rows into the one results file.
    python3 - "$out" "$family" "$arm" "$repeat" >> "$results/results.tsv" <<'PY'
import json, pathlib, sys
out, family, arm, repeat = pathlib.Path(sys.argv[1]), *sys.argv[2:5]
rows = {}
for line in (out / "tasks.tsv").read_text().splitlines()[1:]:
    position, task, solved, seconds = line.split("\t")
    rows[task] = [position, task, solved, seconds]
for task, row in sorted(rows.items()):
    req = calls = prompt = completion = hit = miss = 0
    for path in (out / f"{task}-transcripts").rglob("*.jsonl"):
        for line in path.read_text(errors="replace").splitlines():
            try: entry = json.loads(line)
            except ValueError: continue
            payload = entry.get("payload") or {}
            if payload.get("role") != "assistant": continue
            req += 1
            calls += sum(1 for block in (payload.get("content") or [])
                         if block.get("type") == "tool_call")
            usage = payload.get("usage") or {}
            prompt += usage.get("prompt_tokens", usage.get("input_tokens", 0)) or 0
            completion += usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0
            hit += usage.get("prompt_cache_hit_tokens", 0) or 0
            miss += usage.get("prompt_cache_miss_tokens", 0) or 0
    print("\t".join([arm, family, repeat] + row +
                    [str(req), str(calls), str(prompt), str(completion),
                     str(hit), str(miss)]))
PY
    echo "--- meter after ---"
    python3 "$kc6/budget.py" --limit 7.00 "$results" $anchors || true
    ;;
  pilot)
    # Pre-check 2's runs: AN and B on the bound three, three repeats each.
    # B's cells double as battery cells (amendment 14) -- identical
    # configuration, so a re-run would buy independent noise and nothing else.
    # Sub-cap: the pilot may spend at most $1.50 of the seven.
    for family in f3-agent-surface f1-paren-balance f4-tlc-verdicts; do
      for repeat in 1 2 3; do
        for arm in AN B; do
          done_rows=$(awk -F'	' -v a="$arm" -v f="$family" -v r="$repeat"             '$1==a && $2==f && $3==r' "$results/results.tsv" | wc -l)
          [ "$done_rows" -ge 5 ] && { echo "skip $family $arm r$repeat (done)"; continue; }
          pilot_dirs=$(ls -d "$results"/*-AN-r* "$results"/*-B-r* 2>/dev/null || true)
          if [ -n "$pilot_dirs" ]; then
            python3 "$kc6/budget.py" --limit 1.50 $pilot_dirs || {
              echo "PILOT SUB-CAP REACHED" >&2; exit 1; }
          fi
          python3 "$kc6/budget.py" --limit 7.00 "$results" $anchors || exit 1
          "$0" cell "$family" "$arm" "$repeat"
        done
      done
    done
    echo "=== pre-check 2 ==="
    # Report-only, by the protocol's own sentence: a failure here is "reported
    # as a tax", never a gate. The first version of this line let the
    # comparison's exit code block the battery, which quietly promoted a
    # reporting check into a stopping one.
    python3 "$here/precheck2.py" "$results/results.tsv" || true
    ;;

  battery)
    # The truncation spend order: A and C family by family in battery order,
    # with the pre-check 3/4 checkpoint after the bound three's A cells;
    # then B -- whose cells the pilot already ran.
    checkpointed=0
    for family in f3-agent-surface f1-paren-balance f4-tlc-verdicts                   f2-usage-totals f6-version-prose f5-symbol-callers; do
      for arm in A C; do
        for repeat in 1 2 3; do
          done_rows=$(awk -F'	' -v a="$arm" -v f="$family" -v r="$repeat"             '$1==a && $2==f && $3==r' "$results/results.tsv" | wc -l)
          [ "$done_rows" -ge 5 ] && { echo "skip $family $arm r$repeat (done)"; continue; }
          python3 "$kc6/budget.py" --limit 7.00 "$results" $anchors || {
            echo "BUDGET: families drop whole from the end of the order." >&2; exit 1; }
          "$0" cell "$family" "$arm" "$repeat"
        done
      done
      if [ "$checkpointed" = 0 ] && [ "$family" = f4-tlc-verdicts ]; then
        echo "=== checkpoint: pre-checks 3 and 4 over the bound three's A cells ==="
        python3 "$here/precheck34.py" "$results" || {
          echo "CHECKPOINT FAILED: the battery stops here, by protocol." >&2; exit 1; }
        checkpointed=1
      fi
    done
    for family in f3-agent-surface f1-paren-balance f4-tlc-verdicts; do
      for repeat in 1 2 3; do
        done_rows=$(awk -F'	' -v a="B" -v f="$family" -v r="$repeat"           '$1=="B" && $2==f && $3==r' "$results/results.tsv" | wc -l)
        [ "$done_rows" -ge 5 ] && { echo "skip $family B r$repeat (done)"; continue; }
        python3 "$kc6/budget.py" --limit 7.00 "$results" $anchors || {
          echo "BUDGET during B: kill side unaffected; keep becomes provisional." >&2; exit 1; }
        "$0" cell "$family" "B" "$repeat"
      done
    done
    echo "battery complete"
    ;;

  *)
    echo "usage: ./run.sh cell FAMILY ARM REPEAT | pilot | battery" >&2; exit 2 ;;
esac
