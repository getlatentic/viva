#!/bin/sh
# The three-legged gate: fail-before, pass-after, corrupted-fails.
#
# The third leg is the one that matters and the one that is usually missing. A
# grader that passes the right answer and rejects an empty file has shown
# nothing: the question is whether it rejects the answers a CARELESS but
# reasonable solver would produce. tier3's first corpus had a decoy at a path
# nothing read, so the kind check was never load-bearing -- a gate that could
# not fail.
#
# So each family states its careless solvers, and this refuses to bless a
# variant where any of them scores the same as the correct one.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
family=${1:-ledger}

fail() { printf '%s\n' "$*" >&2; exit 1; }

for job in "$here/jobs/$family"/v*; do
  name=$(basename "$job")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cp -R "$job"/. "$work/"
  rm -rf "$work/solution"

  # 1. FAIL BEFORE: nothing answered yet.
  if (cd "$work" && ./check >/dev/null 2>&1); then
    fail "$family/$name: the gate passed with no answer at all"
  fi

  # 2. PASS AFTER: the reference answer, computed from the pristine data.
  python3 "$here/solve.py" "$family" "$work" > "$work/answer.txt"
  if ! (cd "$work" && ./check >/dev/null 2>&1); then
    fail "$family/$name: the gate rejected the reference answer"
  fi

  # 3. CORRUPTED FAILS: every careless solver must score differently.
  # AN ANSWER IS A LINE, not a word. The first version split on whitespace and
  # counted words, which silently required every family to answer in a single
  # token -- a family answering "sessions seconds" had each half written as its
  # own answer, and its five careless solvers counted as ten.
  wrong=$(python3 "$here/solve.py" "$family" "$work" --careless)
  printf '%s\n' "$wrong" | while IFS= read -r value; do
    [ -n "$value" ] || continue
    printf '%s\n' "$value" > "$work/answer.txt"
    if (cd "$work" && ./check >/dev/null 2>&1); then
      fail "$family/$name: a careless answer ($value) passed -- the gate does not discriminate"
    fi
  done

  # Every careless solver must be DISTINGUISHABLE, not merely rejected. One
  # that scores what the correct solver scores never reached the gate at all,
  # and the rule it drops is untested -- which is how a decoy ends up at a path
  # nothing reads. The count is asserted, not reported.
  distinct=$(printf '%s' "$wrong" | grep -c . || true)
  expected=$(python3 "$here/solve.py" "$family" "$work" --careless-count)
  if [ "$distinct" != "$expected" ]; then
    fail "$family/$name: only $distinct of $expected careless solvers differ from the correct answer -- a rule is not load-bearing here"
  fi
  printf '  %-14s ok  (%d/%d careless solvers distinguishable and rejected)\n' \
         "$family/$name" "$distinct" "$expected"
  rm -rf "$work"
  trap - EXIT
done
printf '%s: three-legged gate green\n' "$family"
