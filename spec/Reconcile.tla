--------------------------- MODULE Reconcile ---------------------------
(* The co-effect ledger, and what a compensation that FAILS PARTWAY does.     *)
(*                                                                            *)
(* Trigger, from #13: pull this in when tier-3 registry churn makes reverts   *)
(* real. It has. #5 put registry entries under the evolution lifecycle, and a *)
(* tool graduated into the registry on live data the same day, so promote and *)
(* revert now move files somebody else will read.                             *)
(*                                                                            *)
(* THE STANDING OBLIGATION from review: model a compensation that fails       *)
(* partway. An assumed-atomic repair is the comfort the Cordis probe          *)
(* rejected, and it is the easiest thing in the world to write into a spec    *)
(* without noticing -- one action moving `compensating` to `reverted`, and    *)
(* the fact that undoing three file writes is three operations that can each  *)
(* fail disappears. So the atomic version is here as ATOMIC, wired to a       *)
(* witness config, and it must violate. An attack that cannot lose is not an  *)
(* attack.                                                                    *)
(*                                                                            *)
(* WHAT IS BEING MODELLED. A registry operation has effects outside the       *)
(* ledger: a script written, a manifest written, a version promoted. The      *)
(* ledger claims a status. The world holds a prefix of the effects. The whole *)
(* question is whether the claim can ever be wrong -- and specifically        *)
(* whether it can be wrong in the direction that looks FINISHED, because a    *)
(* half-undone registration that reports `reverted` is a manifest naming a    *)
(* script that is not there, discovered by whoever calls it next.             *)
(*                                                                            *)
(* STUCK IS A REAL STATE, not a modelling failure. A compensation that has    *)
(* exhausted its retries with effects still in the world must say so. The     *)
(* alternative is not "no stuck states", it is stuck states that call         *)
(* themselves reverted.                                                       *)
EXTENDS Integers

CONSTANTS Ops, MaxSteps, MaxAttempts, Atomic

VARIABLES done, status, tries

vars == <<done, status, tries>>

Statuses == {"none", "applying", "applied", "compensating", "reverted", "stuck"}

TypeOK ==
    /\ done \in [Ops -> 0..MaxSteps]
    /\ status \in [Ops -> Statuses]
    /\ tries \in [Ops -> 0..MaxAttempts]

Init ==
    /\ done = [o \in Ops |-> 0]
    /\ status = [o \in Ops |-> "none"]
    /\ tries = [o \in Ops |-> 0]

Begin(o) ==
    /\ status[o] = "none"
    /\ status' = [status EXCEPT ![o] = "applying"]
    /\ UNCHANGED <<done, tries>>

(* One effect lands in the world. Not all of them: that is the point. *)
ApplyStep(o) ==
    /\ status[o] = "applying"
    /\ done[o] < MaxSteps
    /\ done' = [done EXCEPT ![o] = done[o] + 1]
    /\ status' = [status EXCEPT ![o] =
                    IF done[o] + 1 = MaxSteps THEN "applied" ELSE "applying"]
    /\ UNCHANGED tries

(* An effect refuses to land. The world keeps the prefix already written. *)
ApplyFail(o) ==
    /\ status[o] = "applying"
    /\ status' = [status EXCEPT ![o] = "compensating"]
    /\ UNCHANGED <<done, tries>>

Revert(o) ==
    /\ status[o] = "applied"
    /\ status' = [status EXCEPT ![o] = "compensating"]
    /\ UNCHANGED <<done, tries>>

(* Undoing is stepwise, because undoing three file writes is three
   operations. This is the action ATOMIC replaces. *)
CompensateStep(o) ==
    /\ ~Atomic
    /\ status[o] = "compensating"
    /\ done[o] > 0
    /\ done' = [done EXCEPT ![o] = done[o] - 1]
    /\ UNCHANGED <<status, tries>>

CompensateFail(o) ==
    /\ ~Atomic
    /\ status[o] = "compensating"
    /\ done[o] > 0
    /\ tries[o] < MaxAttempts
    /\ tries' = [tries EXCEPT ![o] = tries[o] + 1]
    /\ UNCHANGED <<done, status>>

Exhausted(o) ==
    /\ ~Atomic
    /\ status[o] = "compensating"
    /\ done[o] > 0
    /\ tries[o] = MaxAttempts
    /\ status' = [status EXCEPT ![o] = "stuck"]
    /\ UNCHANGED <<done, tries>>

Settled(o) ==
    /\ status[o] = "compensating"
    /\ done[o] = 0
    /\ status' = [status EXCEPT ![o] = "reverted"]
    /\ UNCHANGED <<done, tries>>

(* THE COMFORTABLE ASSUMPTION, wired to a witness: we called revert, so it is
   reverted. The world is not consulted and the effects stay where they are. *)
AtomicRevert(o) ==
    /\ Atomic
    /\ status[o] = "compensating"
    /\ status' = [status EXCEPT ![o] = "reverted"]
    /\ UNCHANGED <<done, tries>>

Next == \E o \in Ops :
    \/ Begin(o) \/ ApplyStep(o) \/ ApplyFail(o) \/ Revert(o)
    \/ CompensateStep(o) \/ CompensateFail(o) \/ Exhausted(o)
    \/ Settled(o) \/ AtomicRevert(o)

(* FAIRNESS, and what it assumes out loud. An operation that has begun either
   makes progress or fails -- there is a process running it. That is weak
   fairness on the applying actions, and it is an ASSUMPTION, not a fact: a
   genuinely hung apply is possible in the world and this model does not cover
   it. Stating it here is the difference between an assumption and a blind
   spot. Without it the first liveness check found o1 stuttering forever in
   "applying", which is the model correctly refusing to promise something
   nothing guaranteed. *)
Spec == Init /\ [][Next]_vars
        /\ \A o \in Ops :
              /\ WF_vars(ApplyStep(o) \/ ApplyFail(o))
              /\ WF_vars(CompensateStep(o) \/ Settled(o) \/ Exhausted(o))
              /\ WF_vars(AtomicRevert(o))

-----------------------------------------------------------------------------

(* The ledger's claim and the world agree. This is the one that atomic
   compensation breaks, and it breaks it in the direction that looks
   finished. *)
LedgerMatchesWorld ==
    \A o \in Ops :
        /\ (status[o] = "applied")  => done[o] = MaxSteps
        /\ (status[o] = "reverted") => done[o] = 0
        /\ (status[o] = "none")     => done[o] = 0

(* A partly-applied operation is never resting. It is mid-flight, being undone,
   or escalated -- never quietly one of the two states that mean "settled". *)
NoSilentPartial ==
    \A o \in Ops :
        (done[o] > 0 /\ done[o] < MaxSteps)
            => status[o] \in {"applying", "compensating", "stuck"}

(* NOTHING IS LEFT MID-FLIGHT FOREVER. The resting set includes "none",
   because an operation nobody started is not an unsettled operation -- the
   first draft omitted it and TLC produced the obvious counter-example, an op
   sitting at "none" forever. It also includes "stuck", because a compensation
   that has exhausted its retries with effects still in the world must be
   escalated rather than retried into eternity. A property demanding eventual
   "reverted" would be demanding that the world always cooperates, which is
   the assumption under audit here. *)
EventuallySettled ==
    \A o \in Ops :
        <>[](status[o] \in {"none", "applied", "reverted", "stuck"})

=============================================================================
