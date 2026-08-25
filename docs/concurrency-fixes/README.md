# The Viva concurrency kernel: what was done and how to run it

> **Integrated 2026-08-16.** `kernel.lisp` now lives at `src/daemon/kernel.lisp`
> inside the `viva/daemon` system, the specs at `spec/`, and the
> coordinator in `actor.lisp` dispatches every lifecycle message through
> `cell-transition`. The queue policy is applied (`queue-policy.lisp` is kept
> here as the delivery record). Integration found and fixed two holes the
> delivered table and spec shared differently -- resume-with-queued-prompts
> stranded the queue in both, in different ways -- plus a missing
> suspended-overflow refusal; the self-test now replays those traces too.
> TLC re-verification on this machine awaits `tla2tools.jar`.

Everything here was executed and verified before delivery: the kernel compiles
clean under SBCL 2.2.9 and its self-test passes from the compiled fasl; both
TLA+ specs were model-checked with TLC (tla2tools v1.7.4), all safety
invariants and liveness properties hold over the complete state space at the
configured bounds, and the pre-fix replay algorithm was checked too, where TLC
produces the history-gap counterexample in eight states.

## The six steps, mapped to files

Step 1 and 2 (extract the pure transition function, generate it from one
declaration) are `kernel.lisp`. The `define-owner` macro produces the
production transition function, the clause table for conformance enumeration,
and an `unmatched-transition` condition with an `ignore-message` restart, so a
lifecycle hole signals instead of improvising. The cell owner is extracted
from the behaviour `actor.lisp` already implements, with the two implicit
end-of-life phases of `run-cell` made explicit as `:flushing` and
`:completed`. The journal owner encodes generation identity.

Step 3 (model checking) is `CellLifecycle.tla` and `ReplayBarrier.tla` with
their `.cfg` files, replacing the hand-rolled explorer as agreed. The specs
mirror the `define-owner` tables action for action.

Step 4 (property tests at the runtime boundary) is `replay-trace` in
`kernel.lisp`: a TLC counterexample trace pastes in as a list of steps and
becomes a regression test. `run-self-test` demonstrates the shape with the
traces that were once production incidents, including the stale completion,
the resume-resurrection, and the flush-retained shutdown.

Step 5 (queue policy) is `queue-policy.lisp`: drop-in replacements for
`publish` and `accept-prompt` bounding the two queues `actor.lisp` leaves
open, with refusal and drop as declared, published outcomes, the same shape as
`+journal-high-water+`.

Step 6 is the exit rule at the bottom of this file.

## Running it

    sbcl --non-interactive \
         --eval '(compile-file "kernel.lisp")' \
         --eval '(load "kernel.fasl")' \
         --eval '(viva.kernel:run-self-test)'

    java -cp tla2tools.jar tlc2.TLC -deadlock -config CellLifecycle.cfg  CellLifecycle.tla
    java -cp tla2tools.jar tlc2.TLC -deadlock -config ReplayBarrier.cfg  ReplayBarrier.tla
    java -cp tla2tools.jar tlc2.TLC -deadlock -config ReplayBarrierBroken.cfg ReplayBarrier.tla

The first two TLC runs report no error. The third reproduces the pre-fix
replay gap: with a ring of 3 and the old capture-committed composition, TLC
exhibits delivery of `<<2, 3>>` with event 1 committed on disk and read by
nobody, which is the 1001..1904 defect at minimal scale. `-deadlock` disables
deadlock reporting because a bounded model legitimately runs out of publisher
steps.

## Verified properties

Safety, checked over every reachable interleaving: at most one terminal event
per turn; terminal events only for started turns; the current turn was
started; no owned work in flushing or completed; leaving the registry requires
proven durability; completed implies session.completed was published; and for
replay, the destination mailbox holds `1, 2, 3, ...` with no gap and no
duplicate at every instant.

Liveness, under stated fairness: shutdown resolves to durable completion or
declared stuck, never a silent hang; every in-flight completion is consumed
provided the session is not parked at a closed gate forever; the replay
catch-up terminates complete.

Two findings surfaced during checking are worth keeping. TLC's first liveness
counterexample was a client toggling suspend and resume forever, starving
completion delivery under weak fairness; the honest encoding is strong
fairness on delivery, because the completion message sits in the mailbox and
is consumed in any phase, and the drain property is conditioned on leaving
suspension infinitely often, because suspension outliving turns is the design.
And the broken-replay model needed the no-evict-before-commit rule added so
its counterexample is the silent loss, not the declared degradation, which
your ring already announces.

## Wiring the kernel into actor.lisp

The coordinator's `handle` becomes mechanical: translate the mailbox message
to the kernel alphabet, call `cell-transition`, execute the returned effects.
The effect descriptions map one to one onto what `handle`, `start-turn`,
`finish-turn` and `begin-stopping` already do; the difference is that the
decision now lives in one checked table and the coordinator only performs.
Wrap the call so a hole becomes a diagnostic:

    (handler-bind ((viva.kernel:unmatched-transition
                     (lambda (c)
                       (publish cell "session.error"
                                (event::object "detail" (princ-to-string c)))
                       (invoke-restart 'viva.kernel:ignore-message))))
      (multiple-value-bind (next effects)
          (viva.kernel:cell-transition state message)
        ...))

## The exit rule, frozen

Tag the kernel v1 once the self-test and both TLC runs are green against the
integrated coordinator. After that, a new concern is a blocker only if it
produces a TLC counterexample against a frozen invariant or a runtime
reproduction; imagination alone routes to the hardening backlog. Phase 1.5
extends the model first: add spawn-scoped-child, spawn-detached,
cancel-parent, and late-child-completion as messages in `define-owner` and as
actions in a `TaskTree.tla` written the same way as these two, run TLC, and
only then implement. New features enter through the proof, so the proof never
goes stale.
