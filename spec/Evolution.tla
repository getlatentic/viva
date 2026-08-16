------------------------------- MODULE Evolution -------------------------------
(* Phase 2's evolution lifecycle, entered through the proof before wiring.    *)
(*                                                                            *)
(* What is modelled is the LIFECYCLE of self-modification, never the evolved  *)
(* code: versions are opaque identities, and the guarantee this spec carries  *)
(* is about who may change which authority when -- candidates reach authority *)
(* only through these actions, promotion is serialized by construction (one   *)
(* owner, one Next), a task's activation is invisible outside that task, and  *)
(* deactivation is bounded by task lifetime. What an evolved function DOES    *)
(* is validated and capability-bounded at runtime, not proven here.           *)
(*                                                                            *)
(* DEACTIVATED and REVERTED are different words on purpose, as the event      *)
(* vocabulary has insisted since before this file existed: deactivation ends  *)
(* one task's local pin; reversion moves the promoted lineage back for        *)
(* everyone.                                                                  *)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Components, MaxVersions, Tasks, Broken

Versions == 1..MaxVersions

VARIABLES minted,    \* versions created so far
          vcomp,     \* [Versions -> Components] which component a version is of
          status,    \* [Versions -> {"none","candidate","promoted","retired","discarded"}]
          lineage,   \* [Components -> Seq(Versions)] promotion history; last is current
          active,    \* [Tasks -> [Components -> 0..MaxVersions]] task-local pins
          live       \* [Tasks -> BOOLEAN]

vars == <<minted, vcomp, status, lineage, active, live>>

TypeOK ==
    /\ minted \in 0..MaxVersions
    /\ vcomp \in [Versions -> Components]
    /\ status \in [Versions -> {"none", "candidate", "promoted", "retired", "discarded"}]
    /\ lineage \in [Components -> Seq(Versions)]
    /\ active \in [Tasks -> [Components -> 0..MaxVersions]]
    /\ live \in [Tasks -> BOOLEAN]

Init ==
    /\ minted = 0
    /\ vcomp = [v \in Versions |-> CHOOSE c \in Components : TRUE]
    /\ status = [v \in Versions |-> "none"]
    /\ lineage = [c \in Components |-> <<>>]
    /\ active = [t \in Tasks |-> [c \in Components |-> 0]]
    /\ live = [t \in Tasks |-> TRUE]

CurrentPromoted(c) ==
    IF lineage[c] = <<>> THEN 0 ELSE lineage[c][Len(lineage[c])]

(* What a task's resolution of a component yields: its own pin, else the      *)
(* promoted default. The definition IS the isolation; the invariants below    *)
(* check the state can never make it lie.                                     *)
Resolution(t, c) ==
    IF active[t][c] /= 0 THEN active[t][c] ELSE CurrentPromoted(c)

------------------------------------------------------------------------------
Create(c) ==
    /\ minted < MaxVersions
    /\ minted' = minted + 1
    /\ vcomp' = [vcomp EXCEPT ![minted + 1] = c]
    /\ status' = [status EXCEPT ![minted + 1] = "candidate"]
    /\ UNCHANGED <<lineage, active, live>>

(* Task-local activation: a live task pins a candidate of the right           *)
(* component. Under BROKEN the activation also seizes the promoted lineage -- *)
(* the leak the witness config demonstrates.                                  *)
Activate(t, v) ==
    /\ live[t]
    /\ status[v] = "candidate"
    /\ active' = [active EXCEPT ![t][vcomp[v]] = v]
    /\ IF Broken
           THEN lineage' = [lineage EXCEPT ![vcomp[v]] = Append(@, v)]
           ELSE UNCHANGED lineage
    /\ UNCHANGED <<minted, vcomp, status, live>>

(* Deactivation is bounded by task lifetime: the pins die with the task, and  *)
(* only the pins -- the lineage does not move.                                *)
TaskEnd(t) ==
    /\ live[t]
    /\ live' = [live EXCEPT ![t] = FALSE]
    /\ active' = [active EXCEPT ![t] = [c \in Components |-> 0]]
    /\ UNCHANGED <<minted, vcomp, status, lineage>>

(* Promotion: the single owner moves the default lineage forward. The         *)
(* previously promoted version of that component retires.                     *)
Promote(v) ==
    /\ status[v] = "candidate"
    /\ status' = [w \in Versions |->
                    IF w = v THEN "promoted"
                    ELSE IF w = CurrentPromoted(vcomp[v]) /\ status[w] = "promoted"
                             THEN "retired"
                             ELSE status[w]]
    /\ lineage' = [lineage EXCEPT ![vcomp[v]] = Append(@, v)]
    /\ UNCHANGED <<minted, vcomp, active, live>>

(* Reversion: the lineage steps BACK -- the current promoted version retires  *)
(* and its predecessor is promoted again. Not deactivation: every task's pin  *)
(* is untouched, and the change is for everyone.                              *)
Revert(c) ==
    /\ Len(lineage[c]) > 1
    /\ LET current == lineage[c][Len(lineage[c])]
           previous == lineage[c][Len(lineage[c]) - 1]
       IN status' = [w \in Versions |->
                       IF w = current THEN "retired"
                       ELSE IF w = previous THEN "promoted"
                       ELSE status[w]]
    /\ lineage' = [lineage EXCEPT ![c] = SubSeq(@, 1, Len(@) - 1)]
    /\ UNCHANGED <<minted, vcomp, active, live>>

Discard(v) ==
    /\ status[v] = "candidate"
    /\ status' = [status EXCEPT ![v] = "discarded"]
    /\ UNCHANGED <<minted, vcomp, lineage, active, live>>

Next ==
    \/ \E c \in Components : Create(c)
    \/ \E t \in Tasks, v \in Versions : Activate(t, v)
    \/ \E t \in Tasks : TaskEnd(t)
    \/ \E v \in Versions : Promote(v)
    \/ \E c \in Components : Revert(c)
    \/ \E v \in Versions : Discard(v)

(* A candidate is eventually resolved -- promoted, discarded, or retired --   *)
(* under weak fairness on Discard alone, which is always available to a       *)
(* candidate: nothing may sit in limbo forever.                               *)
Fairness == \A v \in Versions : WF_vars(Discard(v))

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* Safety: the frozen invariants of self-modification.                        *)

(* At most one promoted version per component, and it is the lineage's last.  *)
OnePromotedPerComponent ==
    \A c \in Components :
        /\ Cardinality({v \in Versions : status[v] = "promoted" /\ vcomp[v] = c}) <= 1
        /\ (lineage[c] /= <<>>) =>
              status[lineage[c][Len(lineage[c])]] \in {"promoted"}

(* The lineage holds only versions that were actually created for it.         *)
LineageIsReal ==
    \A c \in Components : \A i \in 1..Len(lineage[c]) :
        /\ lineage[c][i] <= minted
        /\ vcomp[lineage[c][i]] = c

(* Deactivation bounded by lifetime: a dead task pins nothing.                *)
NoPinsAfterDeath ==
    \A t \in Tasks : ~live[t] => \A c \in Components : active[t][c] = 0

(* A pin refers to a real candidate-or-better of the right component.         *)
PinsAreReal ==
    \A t \in Tasks, c \in Components :
        active[t][c] /= 0 =>
            /\ active[t][c] <= minted
            /\ vcomp[active[t][c]] = c
            /\ status[active[t][c]] \in {"candidate", "promoted", "retired", "discarded"}

(* THE isolation law: an unpromoted candidate reaches a task's resolution     *)
(* only through that task's own pin. Under BROKEN, an activation leaks into   *)
(* the shared lineage and every other task resolves to somebody's experiment  *)
(* -- the witness violation.                                                  *)
CandidateOnlyByOwnPin ==
    \A t \in Tasks, c \in Components :
        LET r == Resolution(t, c)
        IN (r /= 0 /\ status[r] = "candidate") => active[t][c] = r

------------------------------------------------------------------------------
(* Liveness under the stated fairness.                                        *)

CandidateResolves ==
    \A v \in Versions :
        (status[v] = "candidate") ~>
            (status[v] \in {"promoted", "discarded", "retired"})

==============================================================================
