--------------------------- MODULE Evolution ---------------------------
(* Evolution.tla, revised after review found three holes. Diff from v1:       *)
(*                                                                            *)
(* FINDING 1, provable against v1: DISCARD ignored live pins. A task pinned   *)
(* to a candidate kept resolving to it after the owner judged it "will not    *)
(* be kept" -- and no invariant noticed, because CandidateOnlyByOwnPin only   *)
(* speaks of candidates and PinsAreReal explicitly allowed pinned-discarded.  *)
(* The blind spot is NoResolutionToDiscarded below; the BrokenDiscard flag    *)
(* reproduces v1's unguarded semantics, and its witness config violates the   *)
(* new invariant -- the hole is real, not imagined. The repair: discard is    *)
(* REFUSED while any live task pins the version, in the refusal-with-reason   *)
(* idiom every other owner already uses. Retired stays pinnable-after: a      *)
(* retired version passed promotion once; a discarded one never did.          *)
(*                                                                            *)
(* FINDING 2: v1's mirror lacked the spec's live-task guard on ACTIVATE, so a *)
(* stale activate arriving after task-ended recreated pins nobody would ever  *)
(* drop. The spec now distinguishes unborn / live / ended so the mirror has   *)
(* something to conform to: activation and inheritance require a LIVE task,   *)
(* ended is forever, identities are never reused.                             *)
(*                                                                            *)
(* FINDING 3, the composition law for law 9: INHERIT makes spawn-time         *)
(* context inheritance REGISTRY-VISIBLE. If inheritance were only a           *)
(* thread-local snapshot, the parent's death would drop the last registry pin *)
(* while the child still executes the candidate, and even the guarded discard *)
(* would judge it unpinned. The registry must know what the child holds, or   *)
(* the discard guard cannot see through spawns. Wiring consequence: the task  *)
(* tree's spawn effect must post (:task-spawned child parent) to the          *)
(* evolution owner BEFORE the child's worker starts.                          *)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Components, MaxVersions, Tasks, Broken, BrokenDiscard

Versions == 1..MaxVersions

VARIABLES minted, vcomp, status, lineage, active,
          lifec      \* [Tasks -> {"unborn","live","ended"}]

vars == <<minted, vcomp, status, lineage, active, lifec>>

TypeOK ==
    /\ minted \in 0..MaxVersions
    /\ vcomp \in [Versions -> Components]
    /\ status \in [Versions -> {"none", "candidate", "promoted", "retired", "discarded"}]
    /\ lineage \in [Components -> Seq(Versions)]
    /\ active \in [Tasks -> [Components -> 0..MaxVersions]]
    /\ lifec \in [Tasks -> {"unborn", "live", "ended"}]

Init ==
    /\ minted = 0
    /\ vcomp = [v \in Versions |-> CHOOSE c \in Components : TRUE]
    /\ status = [v \in Versions |-> "none"]
    /\ lineage = [c \in Components |-> <<>>]
    /\ active = [t \in Tasks |-> [c \in Components |-> 0]]
    /\ lifec = [t \in Tasks |-> "unborn"]

CurrentPromoted(c) ==
    IF lineage[c] = <<>> THEN 0 ELSE lineage[c][Len(lineage[c])]

Resolution(t, c) ==
    IF active[t][c] /= 0 THEN active[t][c] ELSE CurrentPromoted(c)

Pinned(v) == \E t \in Tasks : active[t][vcomp[v]] = v

------------------------------------------------------------------------------
Create(c) ==
    /\ minted < MaxVersions
    /\ minted' = minted + 1
    /\ vcomp' = [vcomp EXCEPT ![minted + 1] = c]
    /\ status' = [status EXCEPT ![minted + 1] = "candidate"]
    /\ UNCHANGED <<lineage, active, lifec>>

(* Tasks are born: a root with no pins, or a child INHERITING its live        *)
(* parent's pins as a snapshot the registry can see. Identity is single-use:  *)
(* unborn -> live -> ended, never back.                                       *)
SpawnRoot(t) ==
    /\ lifec[t] = "unborn"
    /\ lifec' = [lifec EXCEPT ![t] = "live"]
    /\ UNCHANGED <<minted, vcomp, status, lineage, active>>

Inherit(t, p) ==
    /\ lifec[t] = "unborn"
    /\ lifec[p] = "live"
    /\ t /= p
    /\ lifec' = [lifec EXCEPT ![t] = "live"]
    /\ active' = [active EXCEPT ![t] = active[p]]
    /\ UNCHANGED <<minted, vcomp, status, lineage>>

Activate(t, v) ==
    /\ lifec[t] = "live"
    /\ status[v] = "candidate"
    /\ active' = [active EXCEPT ![t][vcomp[v]] = v]
    /\ IF Broken
           THEN lineage' = [lineage EXCEPT ![vcomp[v]] = Append(@, v)]
           ELSE UNCHANGED lineage
    /\ UNCHANGED <<minted, vcomp, status, lifec>>

TaskEnd(t) ==
    /\ lifec[t] = "live"
    /\ lifec' = [lifec EXCEPT ![t] = "ended"]
    /\ active' = [active EXCEPT ![t] = [c \in Components |-> 0]]
    /\ UNCHANGED <<minted, vcomp, status, lineage>>

Promote(v) ==
    /\ status[v] = "candidate"
    /\ status' = [w \in Versions |->
                    IF w = v THEN "promoted"
                    ELSE IF w = CurrentPromoted(vcomp[v]) /\ status[w] = "promoted"
                             THEN "retired"
                             ELSE status[w]]
    /\ lineage' = [lineage EXCEPT ![vcomp[v]] = Append(@, v)]
    /\ UNCHANGED <<minted, vcomp, active, lifec>>

Revert(c) ==
    /\ Len(lineage[c]) > 1
    /\ LET current == lineage[c][Len(lineage[c])]
           previous == lineage[c][Len(lineage[c]) - 1]
       IN status' = [w \in Versions |->
                       IF w = current THEN "retired"
                       ELSE IF w = previous THEN "promoted"
                       ELSE status[w]]
    /\ lineage' = [lineage EXCEPT ![c] = SubSeq(@, 1, Len(@) - 1)]
    /\ UNCHANGED <<minted, vcomp, active, lifec>>

(* THE REPAIR: a candidate somebody live is running may not be judged         *)
(* "will not be kept" out from under them. Refused, named, retried after the  *)
(* pinning tasks end. BrokenDiscard reproduces v1 for the witness.            *)
Discard(v) ==
    /\ status[v] = "candidate"
    /\ BrokenDiscard \/ ~Pinned(v)
    /\ status' = [status EXCEPT ![v] = "discarded"]
    /\ UNCHANGED <<minted, vcomp, lineage, active, lifec>>

Next ==
    \/ \E c \in Components : Create(c)
    \/ \E t \in Tasks : SpawnRoot(t)
    \/ \E t, p \in Tasks : Inherit(t, p)
    \/ \E t \in Tasks, v \in Versions : Activate(t, v)
    \/ \E t \in Tasks : TaskEnd(t)
    \/ \E v \in Versions : Promote(v)
    \/ \E c \in Components : Revert(c)
    \/ \E v \in Versions : Discard(v)

(* Liveness now states its real condition out loud: a pinned candidate        *)
(* resolves only after its pinning tasks end, so candidate resolution is      *)
(* bounded by task lifetime, exactly as deactivation is. Fairness on TaskEnd  *)
(* is the model's form of "tasks end"; a STUCK session that never ends holds  *)
(* its candidate open, visibly, which is that state's meaning everywhere      *)
(* else in this system.                                                       *)
Fairness ==
    /\ \A v \in Versions : WF_vars(Discard(v))
    /\ \A t \in Tasks : WF_vars(TaskEnd(t))

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
OnePromotedPerComponent ==
    \A c \in Components :
        /\ Cardinality({v \in Versions : status[v] = "promoted" /\ vcomp[v] = c}) <= 1
        /\ (lineage[c] /= <<>>) =>
              status[lineage[c][Len(lineage[c])]] \in {"promoted"}

LineageIsReal ==
    \A c \in Components : \A i \in 1..Len(lineage[c]) :
        /\ lineage[c][i] <= minted
        /\ vcomp[lineage[c][i]] = c

(* Pins exist only inside a lifetime: none before birth, none after death.    *)
NoPinsOutsideLife ==
    \A t \in Tasks : lifec[t] /= "live" => \A c \in Components : active[t][c] = 0

PinsAreReal ==
    \A t \in Tasks, c \in Components :
        active[t][c] /= 0 =>
            /\ active[t][c] <= minted
            /\ vcomp[active[t][c]] = c

CandidateOnlyByOwnPin ==
    \A t \in Tasks, c \in Components :
        LET r == Resolution(t, c)
        IN (r /= 0 /\ status[r] = "candidate") => active[t][c] = r

(* THE NEW LAW, v1's blind spot: no live task ever resolves a component to a  *)
(* discarded version. Violated by the BrokenDiscard witness against v1's      *)
(* semantics; held by the guarded discard, including through inheritance.     *)
NoResolutionToDiscarded ==
    \A t \in Tasks, c \in Components :
        lifec[t] = "live" =>
            LET r == Resolution(t, c)
            IN r /= 0 => status[r] /= "discarded"

------------------------------------------------------------------------------
CandidateResolves ==
    \A v \in Versions :
        (status[v] = "candidate") ~>
            (status[v] \in {"promoted", "discarded", "retired"})

==============================================================================
