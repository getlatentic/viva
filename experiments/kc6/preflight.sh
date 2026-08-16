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
sbcl --script "$here/preflight.lisp" "$@"

ledger=$(cat /tmp/kc6-preflight-ledger-path)
echo
echo "--- pre-check three, over the ledger pre-check one just wrote ---"
python3 "$here/instrumentality.py" "$ledger"
