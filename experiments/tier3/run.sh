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

. "$root/tools/offpeak.sh"
offpeak_or_refuse || exit 1

out="$here/results"; mkdir -p "$out"

# ONE RUN AT A TIME. Two drivers against one workspace share a results file and
# a .vivarium directory, and the collision is not loud: it produced a row
# reading `pans v5` where `5<tab>spans<tab>v5` should have been, one task
# apparently costing 235k tokens, and a corpus whose rows arrived out of order.
# All of it looks like data. A run that starts while another is going is not an
# inconvenience, it is a silently contaminated result, so it is refused.
lock="$out/.running"
if ! mkdir "$lock" 2>/dev/null; then
  echo "A run is already going ($lock exists). Wait for it, or remove that directory if it is stale." >&2
  exit 1
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
python3 "$root/experiments/kc6/budget.py" --limit 7.00 \
        "$root/experiments/kc6/results" "$root/experiments/dogfood/results" "$out" || exit 1

# NOT exec: the trap above has to survive to release the lock.
KC6_REFLECT=1 sbcl --script "$root/experiments/dogfood/driver.lisp" "$here/jobs" "$out"
