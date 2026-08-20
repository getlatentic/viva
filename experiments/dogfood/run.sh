#!/bin/sh
# The dogfood run: 25 real recurring jobs, one image, policy on.
#
# INTERLEAVED BY VARIANT, not grouped by shape: v1 of every shape, then v2 of
# every shape. Grouping would let a shape's own repetition carry the result
# and say nothing about whether retention crosses kinds of work; interleaving
# makes a v4 task face artifacts retained by four different shapes, which is
# what a real week looks like.
#
# One image for the whole corpus, like a KC6 cell: retention that cannot
# outlive a process is not retention, and the whole question here is what
# accumulates.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
set -a; . "$root/.env"; set +a
[ "${DEEPSEEK_MODEL:-}" = "deepseek-v4-flash" ] || { echo "MODEL PIN FAILED" >&2; exit 1; }

out="$here/results"
mkdir -p "$out"
python3 "$root/experiments/kc6/budget.py" --limit 7.00 "$root/experiments/kc6/results" "$out" || exit 1

KC6_REFLECT=1 exec sbcl --script "$here/driver.lisp" "$here/jobs" "$out"
