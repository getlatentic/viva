#!/bin/sh
# Does vivarium on task 6 work better than vivarium on task 1?
#
# Six ordinary maintenance tasks in one small Python project, done in sequence,
# each in a FRESH conversation and a FRESH copy of the repository. Two arms that
# differ by exactly one thing:
#
#   ACCUMULATE   .vivarium/ carries forward between tasks. Whatever the agent
#                chose to write down, and any skill it wrote, is there next time.
#   RESET        .vivarium/ is wiped between tasks. Same agent, same tasks, same
#                order, no memory of having been here.
#
# Nothing tells the agent to remember anything. The `remember` tool is in the
# tool set with its ordinary description and that is all; being told to use it
# would measure compliance, not adaptation.
#
# WHAT IS SHARED BETWEEN TASKS IS PROCEDURE, NEVER ANSWER. Each task's defect is
# independent and no task's fix is any other's. What repeats is the cost of
# working here at all: finding that ./check is the test runner, that it must be
# run from the repository root, that vendor/ is a dead copy that nothing imports,
# and that every amount is integer cents. If memory ever carries an answer rather
# than a procedure, this measures cheating; check-answers.sh exists to say so.
#
# Judged by ./check exiting 0, and costed from the recorded transcript -- tool
# calls and model requests that actually happened, not what the agent reported.
#
#   ./run.sh                          both arms, one sequence each
#   ./run.sh --repeats 3              three sequences per arm
#   ./run.sh --arm accumulate
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
model=${ADAPT_MODEL:-deepseek}
work=${ADAPT_WORK:-/tmp/vivarium-adaptation}
arms="accumulate reset"
repeats=1

# The order is fixed and shared by both arms. Discovery-heavy tasks are not
# front-loaded: if they were, ACCUMULATE would look good for having been handed
# the expensive part first.
order="split-remainder float-balance format-amount overdraft refund-sign monthly-summary"

while [ $# -gt 0 ]; do
  case "$1" in
    --arm) arms="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

rm -rf "$work"; mkdir -p "$work"
results="$work/results.tsv"
printf 'arm\tsequence\tposition\ttask\tsolved\trequests\ttoolcalls\tseconds\tremembered\n' > "$results"

count_events() {   # transcript-dir -> "requests toolcalls"
  python3 - "$1" <<'PY'
import json, pathlib, sys
requests = calls = 0
for path in pathlib.Path(sys.argv[1]).glob("*.jsonl"):
    for line in path.read_text(errors="replace").splitlines():
        try: entry = json.loads(line)
        except Exception: continue
        payload = entry.get("payload") or {}
        if payload.get("role") == "assistant":
            requests += 1
            calls += sum(1 for block in (payload.get("content") or [])
                         if block.get("type") == "tool_call")
print(requests, calls)
PY
}

run_sequence() {
  arm=$1; sequence=$2
  carried="$work/$arm-$sequence-carried"
  rm -rf "$carried"; mkdir -p "$carried"
  position=0
  for task in $order; do
    position=$((position + 1))
    sandbox="$work/$arm-$sequence-$position-$task"
    rm -rf "$sandbox"
    cp -R "$here/repo" "$sandbox"
    python3 "$here/tasks/$task/break.py" "$sandbox"

    # The treatment, and the only difference between the arms.
    if [ "$arm" = accumulate ] && [ -d "$carried/.vivarium" ]; then
      cp -R "$carried/.vivarium" "$sandbox/.vivarium"
    fi

    transcripts="$sandbox/.transcripts"
    started=$(date +%s)
    "$root/bin/vivarium" do "$(cat "$here/tasks/$task/PROMPT")" \
      --cwd "$sandbox" --root "$sandbox" --model "$model" --limit 30 \
      --session-dir "$transcripts" > "$sandbox/.log" 2>&1 || true
    finished=$(date +%s)

    if ( cd "$sandbox" && ./check >/dev/null 2>&1 ); then solved=1; else solved=0; fi
    set -- $(count_events "$transcripts")
    requests=$1; calls=$2

    remembered=0
    if [ -f "$sandbox/.vivarium/MEMORY.md" ]; then
      remembered=$(grep -c '^-' "$sandbox/.vivarium/MEMORY.md" 2>/dev/null || echo 0)
    fi

    # Carry forward whatever this task left behind, for the next one.
    if [ "$arm" = accumulate ] && [ -d "$sandbox/.vivarium" ]; then
      rm -rf "$carried/.vivarium"
      cp -R "$sandbox/.vivarium" "$carried/.vivarium"
      rm -rf "$carried/.vivarium/sessions" "$carried/.vivarium/.transcripts"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$sequence" "$position" \
      "$task" "$solved" "$requests" "$calls" "$((finished - started))" "$remembered" >> "$results"
    printf '  %-10s seq %s  %d. %-16s %s  %2s req  %2s calls  %3ss  mem:%s\n' \
      "$arm" "$sequence" "$position" "$task" \
      "$([ "$solved" = 1 ] && echo solved || echo '  --  ')" \
      "$requests" "$calls" "$((finished - started))" "$remembered"
  done
}

printf 'model: %s   tasks: %s   repeats: %s\n\n' "$model" "$(echo $order | wc -w | tr -d ' ')" "$repeats"

sequence=1
while [ "$sequence" -le "$repeats" ]; do
  for arm in $arms; do
    run_sequence "$arm" "$sequence"
    printf '\n'
  done
  sequence=$((sequence + 1))
done

python3 "$here/report.py" "$results"
printf '\nper-run detail: %s\nsandboxes:      %s\n' "$results" "$work"
