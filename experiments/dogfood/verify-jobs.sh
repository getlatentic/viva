#!/bin/sh
# Every check must FAIL with no answer and PASS with the reference one.
# A check that cannot lose measures nothing -- the rule that has caught an
# authoring bug in every family written under it so far.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
failures=0
for job in "$here"/jobs/*/v*/; do
  name=$(echo "$job" | sed "s|$here/jobs/||;s|/$||")
  work=$(mktemp -d)
  (cd "$job" && find . -mindepth 1 -maxdepth 1 ! -name solution -exec cp -R {} "$work/" \;)
  if (cd "$work" && ./check >/dev/null 2>&1); then before=PASSED; failures=$((failures+1))
  else before=failed; fi
  cp "$job"solution/* "$work/"
  if (cd "$work" && ./check >/dev/null 2>&1); then after=passed
  else after=FAILED; failures=$((failures+1)); (cd "$work" && ./check 2>&1 | head -4) || true; fi
  printf '%-14s no answer: %-7s reference: %s\n' "$name" "$before" "$after"
  rm -rf "$work"
done
[ "$failures" -eq 0 ] || { echo "$failures gate violation(s)" >&2; exit 1; }
echo "every check can lose, and the reference satisfies every check"
