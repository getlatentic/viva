# Family 1: paren balance in a Lisp edit

The friction: making a structural edit to a nested Lisp form and getting the
parentheses exactly right. The receipt: broken twice in one session building
this very machinery, fixed only when a probe printed depth per line
(reachability.lisp's self-test, commit history).

Five tasks, one friction, different particulars. Each task is a small Lisp
file and one specified edit; grading is `./check` exiting 0 — it READs the
file (balance is necessary, not sufficient) and asserts the edit's structure.
Files carry stub definitions so they also LOAD cleanly, letting any arm
self-verify with plain sbcl.

`solution/` holds the reference edit and is EXCLUDED from sandboxes by the
runner. `../verify-family.sh f1-paren-balance` proves every check fails on
the initial state and passes on the reference — a check that cannot lose is
not a check.

Split and order, fixed before this family's tasks existed (amendment 11):
scored families are 1-4, held out are 5-6 (authored last, excluded from
pilots and authoring knowledge, INCLUDED in the battery and the primary
n = 6 sign test). Battery run order: 3, 1, 4, 2, 6, 5.
