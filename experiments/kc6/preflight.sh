#!/bin/sh
# KC6 pre-checks one and three, together, on a ledger written by this build.
#
# One is reachability: the whole genealogy traversed through the real wire with
# no model involved. Three is instrumentality: were created versions actually
# resolved afterwards. Running them as a pair is the point -- three is only
# meaningful over a ledger from a single arm-A run, and one produces exactly
# that. Non-zero if either refuses.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# THE MODEL PIN, gated rather than promised (amendment 13): only
# deepseek-v4-flash may spend. A pre-check that trusts the .env to be right
# is a pre-check that discovers Pro pricing after the bill.
pinned=$(sed -n 's/^DEEPSEEK_MODEL=//p' "$root/.env" 2>/dev/null | tail -1)
if [ "$pinned" != "deepseek-v4-flash" ]; then
  echo "MODEL PIN FAILED: DEEPSEEK_MODEL is '${pinned:-unset}', amendment 13"
  echo "allows only deepseek-v4-flash. Fix $root/.env before anything spends."
  exit 1
fi
echo "model pin: deepseek-v4-flash (gated)"
echo

# ZERO FIRST, because it is the one that can invalidate the other two. One and
# three can both pass against an organism no model can reach: they drive the
# Lisp wire, and a model drives the tool surface.
echo "--- pre-check zero, reachability by the entity under test ---"
sbcl --script "$here/reachability.lisp" || {
  echo
  echo "STOPPING: arm A is not reachable, so nothing below would mean anything."
  exit 1
}

echo
echo "--- pre-check one, the lifecycle through the real wire ---"
sbcl --script "$here/preflight.lisp" "$@"

ledger=$(cat /tmp/kc6-preflight-ledger-path)
echo
echo "--- pre-check three, over the ledger pre-check one just wrote ---"
python3 "$here/instrumentality.py" "$ledger"
