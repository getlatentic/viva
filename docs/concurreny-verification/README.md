# Evolution revision: the delivery record

Independent verification of the Phase 2 entry artifact found three lifecycle
holes before any wiring existed, proving the first against the tagged v1 model
(NoResolutionToDiscarded, violated in five states) rather than arguing it.
The revised spec and mirror were merged as THE objects on 2026-08-16:
spec/Evolution.tla (module renamed to match), src/daemon/evolution.lisp, four
configs including both witnesses. All re-verified post-merge: safety over
2,044 distinct states, liveness, both witness violations, self-test against
the real kernel, and one attack per repair failing the traces.

The findings: discard refused while any live task pins the version; tasks have
unborn/live/ended lifetimes so a posthumous activate is refused (ended is
forever); and inheritance is registry-visible via (:task-spawned child parent)
-- the composition law, with its wiring consequence: the task tree's spawn
effect posts it BEFORE the child's worker starts.
