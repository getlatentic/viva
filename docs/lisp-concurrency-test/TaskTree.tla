------------------------------- MODULE TaskTree -------------------------------
(* Phase 1.5's task tree, specified BEFORE the coordinator learns the verbs.  *)
(*                                                                            *)
(* One supervisor owns the tree. Tasks have identities that are never reused. *)
(* A child is SCOPED (its lifetime is bounded by its parent's) or DETACHED    *)
(* (genealogy recorded, lifecycle independent). The semantics under check:    *)
(*                                                                            *)
(*   a task cannot be terminal while it owns live scoped work -- its own      *)
(*     outcome waits in DRAINING until the last scoped child resolves;        *)
(*   cancel propagates to live scoped children, never to detached ones,       *)
(*     and propagation is asynchronous, one delivery per step, so TLC         *)
(*     explores parents whose children have not heard yet;                    *)
(*   fan-out is bounded, overflow is refused, never queued silently;         *)
(*   a completion for an already-terminal task changes nothing;               *)
(*   parentage is immutable -- exactly one parent, forever.                   *)
(*                                                                            *)
(* Mirrors DEFINE-OWNER TASKTREE in tasktree.lisp clause for clause.          *)
EXTENDS Integers, FiniteSets

CONSTANTS MaxTasks,   \* identity space; minting is monotonic, ids never reused
          ChildLimit  \* live children a parent may own at once

VARIABLES st,        \* [task -> lifecycle state]
          parent,    \* [task -> parent id, 0 for roots and the unspawned]
          scoped,    \* [task -> whether the task is scoped to its parent]
          pending,   \* [task -> outcome parked while draining, or "none"]
          cancelled, \* [task -> a cancel request has been delivered to it]
          minted     \* ids handed out so far

vars == <<st, parent, scoped, pending, cancelled, minted>>

Tasks == 1..MaxTasks
Live == {"running", "cancelling", "draining"}
Terminal == {"completed", "failed", "cancelled"}
Outcomes == {"completed", "failed", "cancelled"}

TypeOK ==
    /\ st \in [Tasks -> {"unspawned"} \cup Live \cup Terminal]
    /\ parent \in [Tasks -> 0..MaxTasks]
    /\ scoped \in [Tasks -> BOOLEAN]
    /\ pending \in [Tasks -> {"none"} \cup Outcomes]
    /\ cancelled \in [Tasks -> BOOLEAN]
    /\ minted \in 0..MaxTasks

Init ==
    /\ st = [t \in Tasks |-> "unspawned"]
    /\ parent = [t \in Tasks |-> 0]
    /\ scoped = [t \in Tasks |-> FALSE]
    /\ pending = [t \in Tasks |-> "none"]
    /\ cancelled = [t \in Tasks |-> FALSE]
    /\ minted = 0

LiveScopedChildren(p) ==
    {c \in Tasks : parent[c] = p /\ scoped[c] /\ st[c] \in Live}

LiveChildren(p) ==
    {c \in Tasks : parent[c] = p /\ st[c] \in Live}

------------------------------------------------------------------------------
(* Spawning. Identity is minted monotonically; ids are never reused, which is *)
(* what makes a late completion for a finished task unambiguous forever.      *)

SpawnRoot ==
    /\ minted < MaxTasks
    /\ minted' = minted + 1
    /\ st' = [st EXCEPT ![minted + 1] = "running"]
    /\ UNCHANGED <<parent, scoped, pending, cancelled>>

(* Only a RUNNING parent may spawn: a draining parent has already decided its *)
(* outcome, a cancelling one is tearing down, and both taking on new scoped   *)
(* work would reopen a lifetime the tree is closing. Fan-out past ChildLimit  *)
(* is refused -- a stuttering step here; the kernel table publishes the       *)
(* refusal with its reason.                                                   *)
SpawnChild(mode) ==
    \E p \in Tasks :
        /\ st[p] = "running"
        /\ Cardinality(LiveChildren(p)) < ChildLimit
        /\ minted < MaxTasks
        /\ minted' = minted + 1
        /\ st' = [st EXCEPT ![minted + 1] = "running"]
        /\ parent' = [parent EXCEPT ![minted + 1] = p]
        /\ scoped' = [scoped EXCEPT ![minted + 1] = mode]
        /\ UNCHANGED <<pending, cancelled>>

------------------------------------------------------------------------------
(* A task's own work reports. With live scoped children the outcome PARKS in  *)
(* DRAINING: terminal would claim completion while owning running work, the   *)
(* exact lie the cell's :FLUSHING state exists to prevent one level down.     *)
(* Without them, the task is terminal in the same step.                       *)

Finish(o) ==
    \E t \in Tasks :
        /\ st[t] \in {"running", "cancelling"}
        /\ IF LiveScopedChildren(t) /= {}
               THEN /\ st' = [st EXCEPT ![t] = "draining"]
                    /\ pending' = [pending EXCEPT ![t] = o]
               ELSE /\ st' = [st EXCEPT ![t] = o]
                    /\ UNCHANGED pending
        /\ UNCHANGED <<parent, scoped, cancelled, minted>>

(* The last scoped child resolved; the parked outcome lands. Asynchronous on  *)
(* purpose: the supervisor observes the resolution as a message, so TLC       *)
(* explores every interleaving between a child's terminal step and the        *)
(* parent's landing.                                                          *)
DrainComplete ==
    \E t \in Tasks :
        /\ st[t] = "draining"
        /\ LiveScopedChildren(t) = {}
        /\ st' = [st EXCEPT ![t] = pending[t]]
        /\ UNCHANGED <<parent, scoped, pending, cancelled, minted>>

------------------------------------------------------------------------------
(* Cancellation. An external cancel reaches one task; PROPAGATE delivers it   *)
(* onward to live SCOPED children one at a time -- never to detached ones.    *)
(* Cancel is a request: the task's own worker still reports what became of    *)
(* the work, so a cancelled task passes through Finish like everything else.  *)

Cancel ==
    \E t \in Tasks :
        /\ st[t] \in {"running", "draining"}
        /\ cancelled' = [cancelled EXCEPT ![t] = TRUE]
        /\ st' = [st EXCEPT ![t] = IF st[t] = "running" THEN "cancelling" ELSE @]
        /\ UNCHANGED <<parent, scoped, pending, minted>>

Propagate ==
    \E p \in Tasks :
        /\ st[p] \in {"cancelling", "draining"} \cup Terminal
        /\ cancelled[p]
        /\ \E c \in LiveScopedChildren(p) :
             /\ ~cancelled[c]
             /\ cancelled' = [cancelled EXCEPT ![c] = TRUE]
             /\ st' = [st EXCEPT ![c] = IF st[c] = "running" THEN "cancelling" ELSE @]
        /\ UNCHANGED <<parent, scoped, pending, minted>>

(* A completion arriving for a task already terminal is consumed and changes  *)
(* nothing -- in TLA+ that is a stuttering step, which [][Next]_vars already  *)
(* permits, so it needs no action here. The KERNEL table still needs the      *)
(* explicit late-finish clause: the runtime must consume the message, and     *)
(* TerminalIsForever below is the property that says consuming it changes no  *)
(* state. Identity never reused makes the case decidable forever.             *)

------------------------------------------------------------------------------
Next ==
    \/ SpawnRoot
    \/ SpawnChild(TRUE) \/ SpawnChild(FALSE)
    \/ Finish("completed") \/ Finish("failed") \/ Finish("cancelled")
    \/ DrainComplete \/ Cancel \/ Propagate

Fairness ==
    /\ WF_vars(Finish("completed")) /\ WF_vars(Finish("failed"))
    /\ WF_vars(Finish("cancelled"))
    /\ WF_vars(DrainComplete)
    /\ WF_vars(Propagate)

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* Safety: the frozen invariants of the tree.                                 *)

(* A terminal parent owns no live scoped work -- ever, at any instant.        *)
ScopedDiesWithParent ==
    \A p \in Tasks : st[p] \in Terminal => LiveScopedChildren(p) = {}

(* Draining is exactly the state of having decided but not landed: the parked *)
(* outcome exists, and live scoped work or an undelivered resolution remains. *)
DrainingHasPending ==
    \A t \in Tasks : st[t] = "draining" => pending[t] /= "none"

(* Fan-out never exceeds the bound.                                           *)
BoundedFanout ==
    \A p \in Tasks : Cardinality(LiveChildren(p)) <= ChildLimit

(* Parentage is immutable and singular by construction; check the structural  *)
(* consequence: a spawned non-root's parent was spawned before it.            *)
OneParentForever ==
    \A c \in Tasks : parent[c] /= 0 => parent[c] < c

(* Cancellation never propagates ACROSS the scope boundary: a detached task   *)
(* is cancelled only by a direct request, so a cancelled detached task with a *)
(* cancelled parent is coincidence, not causation -- expressed structurally:  *)
(* propagation requires the child to be scoped, so an unscoped cancelled task *)
(* whose parent never received a direct cancel cannot exist ... the direct    *)
(* Cancel action is unconstrained, so the checkable form is the propagation   *)
(* guard itself, verified by the witness configs below.                       *)

(* No spawned task is unspawned again; terminal is forever (checked as an     *)
(* action property).                                                          *)
TerminalIsForever ==
    [][\A t \in Tasks : st[t] \in Terminal => st'[t] = st[t]]_vars

------------------------------------------------------------------------------
(* Liveness under the stated fairness: every spawned task eventually reaches  *)
(* a terminal state -- children resolve, drains land, nothing hangs open.     *)

EveryTaskResolves ==
    \A t \in Tasks : (st[t] \in Live) ~> (st[t] \in Terminal)

------------------------------------------------------------------------------
(* Witnesses: existence claims TLC proves by violating their negation, the    *)
(* ReplayBarrierBroken technique. Run each in its own config, EXPECT the      *)
(* violation; the counterexample trace IS the demonstration.                  *)

(* A detached child can outlive its terminal parent.                          *)
NoDetachedSurvivor ==
    ~\E c \in Tasks :
        /\ parent[c] /= 0 /\ ~scoped[c]
        /\ st[c] \in Live /\ st[parent[c]] \in Terminal

(* A detached child survives even its parent's CANCELLATION untouched.        *)
NoUncancelledOrphan ==
    ~\E c \in Tasks :
        /\ parent[c] /= 0 /\ ~scoped[c] /\ ~cancelled[c]
        /\ st[c] \in Live
        /\ st[parent[c]] = "cancelled" /\ cancelled[parent[c]]

==============================================================================
