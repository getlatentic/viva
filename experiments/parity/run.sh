#!/bin/sh
# vivarium against pi, same model, same task, same starting repository.
#
# The point is not to win. It is to find out whether Level 1 is real: a harness
# that solves nothing an established one solves has a gap, and the gap is worth
# more than the score. Every fixture starts with a failing `run_tests.py` and is
# judged by whether that test passes afterwards -- not by what the agent said it
# did, which is the only claim a transcript can make.
#
#   ./run.sh                     both harnesses, every fixture
#   ./run.sh --only median       one fixture
#   ./run.sh --harness vivarium  one harness
#   ./run.sh --repeats 3         n=1 is inside the noise for any of this
#
# Both sides get: the same model, AGENTS.md as the only instruction file,
# no skills, no extensions, no memory. Anything either side loads from the
# user's home directory would be a difference in configuration rather than in
# harness, so both are told not to.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
model=${PARITY_MODEL:-deepseek-v4-flash}
provider=${PARITY_PROVIDER:-deepseek}
work=${PARITY_WORK:-/tmp/vivarium-parity}
only=""
harnesses="vivarium pi"
repeats=1

while [ $# -gt 0 ]; do
  case "$1" in
    --only) only="$2"; shift 2 ;;
    --harness) harnesses="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fixtures=$(ls "$here/fixtures")
[ -n "$only" ] && fixtures="$only"

rm -rf "$work"; mkdir -p "$work"
results="$work/results.tsv"
printf 'harness\tfixture\trun\tsolved\tseconds\n' > "$results"

run_one() {
  harness=$1; fixture=$2; attempt=$3
  sandbox="$work/$harness-$fixture-$attempt"
  rm -rf "$sandbox"
  cp -R "$here/fixtures/$fixture/repo" "$sandbox"
  prompt=$(cat "$here/fixtures/$fixture/PROMPT")
  started=$(date +%s)

  case "$harness" in
    vivarium)
      # No skills or extensions exist under a fresh fixture, and --root keeps
      # the run inside it, so neither side can wander into the other's output.
      "$root/bin/vivarium" do "$prompt" --cwd "$sandbox" --root "$sandbox" \
        --model "$provider" --limit 25 > "$sandbox/.transcript" 2>&1 || true
      ;;
    pi)
      ( cd "$sandbox" && timeout 900 pi -p "$prompt" \
          --provider "$provider" --model "$model" \
          --no-session -ne -ns -np > "$sandbox/.transcript" 2>&1 || true )
      ;;
  esac

  finished=$(date +%s)
  if ( cd "$sandbox" && python3 run_tests.py >/dev/null 2>&1 ); then solved=1; else solved=0; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$harness" "$fixture" "$attempt" "$solved" \
    "$((finished - started))" >> "$results"
  printf '  %-9s %-10s run %s  %s  %ss\n' "$harness" "$fixture" "$attempt" \
    "$([ "$solved" = 1 ] && echo solved || echo '  --  ')" "$((finished - started))"
}

printf 'model: %s/%s   fixtures: %s   repeats: %s\n\n' "$provider" "$model" \
  "$(echo $fixtures | tr '\n' ' ')" "$repeats"

attempt=1
while [ "$attempt" -le "$repeats" ]; do
  for fixture in $fixtures; do
    for harness in $harnesses; do
      run_one "$harness" "$fixture" "$attempt"
    done
  done
  attempt=$((attempt + 1))
done

printf '\n'
awk -F'\t' 'NR>1 {solved[$1]+=$4; total[$1]++; seconds[$1]+=$5}
  END {printf "%-10s %-8s %s\n", "harness", "solved", "median-ish seconds/task";
       for (h in total) printf "%-10s %d/%-6d %d\n", h, solved[h], total[h], seconds[h]/total[h]}' "$results"
printf '\nper-run detail: %s\ntranscripts:    %s/<harness>-<fixture>-<run>/.transcript\n' "$results" "$work"
