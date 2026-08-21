#!/bin/sh
# The two harder families (#11), under the control #40 named.
#
# Same guards as every other run here, and each one is a lesson rather than
# ceremony: the model pin, because a run on the wrong model is a run that
# proves nothing about the budget it spent; the off-peak window, because it is
# mandatory; the budget ceiling, checked by a tool rather than by whoever
# remembered; and the lock, because two drivers against one workspace produce
# a results file that looks like data and is not.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
set -a; . "$root/.env"; set +a
[ "${DEEPSEEK_MODEL:-}" = "deepseek-v4-flash" ] || { echo "MODEL PIN FAILED" >&2; exit 1; }

hour=$(date -u +%H)
case "$hour" in
  0[1-3]|0[6-9]) echo "PEAK WINDOW ($hour:00 UTC). Off-peak is mandatory; not running." >&2; exit 1 ;;
esac

# The gate before the run, never after: a family whose rules are not all
# load-bearing produces numbers that mean less than they look, and finding that
# out afterwards means paying for it twice.
sh "$here/verify-family.sh" ledger   >/dev/null || { echo "ledger gate is not green" >&2; exit 1; }
sh "$here/verify-family.sh" manifest >/dev/null || { echo "manifest gate is not green" >&2; exit 1; }

out="$here/results"; mkdir -p "$out"
lock="$out/.running"
if ! mkdir "$lock" 2>/dev/null; then
  echo "A run is already going ($lock exists). Wait for it, or remove it if stale." >&2
  exit 1
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

python3 "$root/experiments/kc6/budget.py" --limit 7.00 \
        "$root/experiments/kc6/results" "$root/experiments/dogfood/results" \
        "$root/experiments/tier3/results" "$out" || exit 1

KC6_REFLECT=1 sbcl --script "$root/experiments/dogfood/driver.lisp" "$here/jobs" "$out"
