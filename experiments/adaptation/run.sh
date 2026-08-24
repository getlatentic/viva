#!/bin/sh
# Does vivarium on task 6 work better than vivarium on task 1?
#
# Six ordinary maintenance tasks in one small Python project, done in sequence,
# each in a FRESH conversation and a FRESH copy of the repository. Two arms that
# differ by exactly one thing:
#
#   ACCUMULATE   .viva/ carries forward between tasks. Whatever the agent
#                chose to write down, and any skill it wrote, is there next time.
#   RESET        .viva/ is wiped between tasks. Same agent, same tasks, same
#                order, no memory of having been here.
#   NUDGED       exactly ACCUMULATE, plus one sentence appended to the system
#                prompt. Added after ACCUMULATE returned mem:0 on all twelve
#                runs: with nothing written down the first two arms are the same
#                experiment twice, and their difference is the noise floor.
#
# The nudge names a CATEGORY and never a content -- "anything you had to work
# out", not what to work out. A nudge that said what to remember would be an
# answer key with extra steps.
#
# ACCUMULATE deliberately tells the agent nothing: `remember` is in the tool set
# with its ordinary description and that is all, because instructing it would
# measure compliance rather than the default. NUDGED then asks the separate
# question of whether the capability exists at all when invited.
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

nudge="Before you finish, write down anything you had to work out about this project that you would otherwise have to work out again."

carries_memory() { case "$1" in accumulate|nudged|curated) return 0 ;; *) return 1 ;; esac; }

# PROCEDURAL plants the same procedure-only memory before every task and carries
# nothing forward. It exists because NUDGED's own notes turned out to describe
# tasks it had not yet attempted -- 7 of them -- so NUDGED's cost reduction is
# procedure and leakage mixed together. Planting a fixed memory that names no
# defect and no fix isolates the procedure half: whatever this arm saves is
# saved by knowing how to work here, because there is nothing else in the file.
plants_memory()  { [ "$1" = procedural ]; }
append_for()     { case "$1" in nudged|curated) printf '%s' "$nudge" ;; *) printf '' ;; esac; }

# CURATED is NUDGED plus the curator extension, which consolidates the notes
# into repository-level facts after each run. It exists because rewording what
# `remember` asks for moved nothing measurable: the writer has just done one
# task and cannot see past it, while a consolidator handed notes from many tasks
# can see which parts recur.
extension_for()  { [ "$1" = curated ] && printf "%s" "$here/extensions" || printf ''; }

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
printf 'arm\tsequence\tposition\ttask\tsolved\trequests\ttoolcalls\tseconds\tremembered\tprompt\tcompletion\n' > "$results"

count_events() {   # transcript-dir -> "requests toolcalls prompt completion"
  # TOKENS, not only requests. Cost per solved task is a headline metric and a
  # request count is a poor stand-in: an arm that reads a retained note spends
  # its budget in the prompt while one that rediscovers spends it in tool
  # output, at identical request counts. Each reply's usage was already in the
  # transcript; nothing needed adding but the sum.
  python3 - "$1" <<'PY'
import json, pathlib, sys
requests = calls = prompt = completion = 0
for path in pathlib.Path(sys.argv[1]).glob("*.jsonl"):
    for line in path.read_text(errors="replace").splitlines():
        try: entry = json.loads(line)
        except Exception: continue
        payload = entry.get("payload") or {}
        if payload.get("role") == "assistant":
            requests += 1
            calls += sum(1 for block in (payload.get("content") or [])
                         if block.get("type") == "tool_call")
            usage = payload.get("usage") or {}
            # Providers disagree on the names, and a missing key is a zero
            # rather than a crash: a run that dies costing itself is worse
            # than one that reports a visible zero somebody can chase.
            prompt += usage.get("prompt_tokens") or usage.get("input_tokens") or 0
            completion += (usage.get("completion_tokens")
                           or usage.get("output_tokens") or 0)
print(requests, calls, prompt, completion)
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
    if carries_memory "$arm" && [ -d "$carried/.viva" ]; then
      cp -R "$carried/.viva" "$sandbox/.viva"
    fi
    if plants_memory "$arm"; then
      mkdir -p "$sandbox/.viva"
      cp "$here/planted/MEMORY.md" "$sandbox/.viva/MEMORY.md"
    fi

    transcripts="$sandbox/.transcripts"
    started=$(date +%s)
    set --
    [ -n "$(append_for "$arm")" ] && set -- "$@" --append "$(append_for "$arm")"
    [ -n "$(extension_for "$arm")" ] && set -- "$@" --extension "$(extension_for "$arm")"
    "$root/bin/viva" do "$(cat "$here/tasks/$task/PROMPT")" \
      --cwd "$sandbox" --root "$sandbox" --model "$model" --limit 30 \
      --session-dir "$transcripts" "$@" > "$sandbox/.log" 2>&1 || true
    finished=$(date +%s)

    if ( cd "$sandbox" && ./check >/dev/null 2>&1 ); then solved=1; else solved=0; fi
    set -- $(count_events "$transcripts")
    requests=$1; calls=$2; prompt=$3; completion=$4

    remembered=0
    if [ -f "$sandbox/.viva/MEMORY.md" ]; then
      remembered=$(grep -c '^-' "$sandbox/.viva/MEMORY.md" 2>/dev/null || echo 0)
    fi

    # Carry forward whatever this task left behind, for the next one.
    if carries_memory "$arm" && [ -d "$sandbox/.viva" ]; then
      rm -rf "$carried/.viva"
      cp -R "$sandbox/.viva" "$carried/.viva"
      rm -rf "$carried/.viva/sessions" "$carried/.viva/.transcripts"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$sequence" "$position" \
      "$task" "$solved" "$requests" "$calls" "$((finished - started))" "$remembered" \
      "$prompt" "$completion" >> "$results"
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
