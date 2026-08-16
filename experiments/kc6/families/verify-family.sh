#!/bin/sh
# The authoring gate: every check must FAIL on the initial state and PASS on
# the reference solution. A task whose check cannot lose measures nothing,
# and this family's own friction was found by exactly this kind of probe.
#
#   ./verify-family.sh f1-paren-balance
set -eu
here=$(cd "$(dirname "$0")" && pwd)
family="$here/$1"
[ -d "$family" ] || { echo "no such family: $1" >&2; exit 2; }

failures=0
for task in "$family"/t*/; do
  name=$(basename "$task")
  work=$(mktemp -d)
  # The sandbox view: everything except the reference solution.
  (cd "$task" && find . -maxdepth 1 -type f -exec cp {} "$work/" \;)
  if (cd "$work" && ./check >/dev/null 2>&1)
  then before=PASSED; failures=$((failures + 1))
  else before=failed; fi
  cp "$task"/solution/* "$work/"
  if (cd "$work" && ./check >/dev/null 2>&1)
  then after=passed
  else after=FAILED; failures=$((failures + 1)); (cd "$work" && ./check) || true; fi
  printf '%-4s initial: %-7s reference: %s\n' "$name" "$before" "$after"
  rm -rf "$work"
done

if [ "$failures" -ne 0 ]; then
  echo "$failures gate violation(s): a check passed before the edit or failed after it" >&2
  exit 1
fi
echo "every check can lose, and the reference satisfies every check"
