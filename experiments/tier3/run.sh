#!/bin/sh
# Does reflection reach tier 3, and does a later task call what it registered?
#
# The demo could not answer this reliably: across five runs the organism chose a
# note four times and a skill once, which is the routing rule working -- it
# prefers the cheap tier until reuse is ALREADY evident, and a five-task corpus
# rarely gets there. This corpus is built for the threshold: the same parse,
# four times, with the data growing so doing it by hand stays annoying.
#
# One shape, four variants, one workspace, policy on. Reuses the dogfood driver
# rather than a second one -- the germline handling in it was hard-won.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
set -a; . "$root/.env"; set +a
[ "${DEEPSEEK_MODEL:-}" = "deepseek-v4-flash" ] || { echo "MODEL PIN FAILED" >&2; exit 1; }

hour=$(date -u +%H)
case "$hour" in
  0[1-3]|0[6-9]) echo "PEAK WINDOW ($hour:00 UTC). Off-peak is mandatory; not running." >&2; exit 1 ;;
esac

out="$here/results"; mkdir -p "$out"
python3 "$root/experiments/kc6/budget.py" --limit 7.00 \
        "$root/experiments/kc6/results" "$root/experiments/dogfood/results" "$out" || exit 1

KC6_REFLECT=1 exec sbcl --script "$root/experiments/dogfood/driver.lisp" "$here/jobs" "$out"
