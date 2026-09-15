----------------------------- MODULE CellLifecycle -----------------------------
(* The cell coordinator from actor.lisp / kernel.lisp, checked exhaustively.  *)
(*                                                                            *)
(* Mirrors DEFINE-OWNER CELL action for action. Turn identities are 1..N;     *)
(* CURRENT = 0 means no turn. WORKERS is the set of turns whose completion    *)
(* message is still in flight -- delivering one that is no longer current is  *)
(* the stale-completion case COMPLETE-TURN guards. QUEUED counts prompts      *)
(* waiting behind the running turn. TERMINALS counts terminal events          *)
(* published per turn: the invariant the whole design hangs on is that it     *)
(* never exceeds one.                                                         *)
(*                                                                            *)
(* MODEL is the generation of model the agent answers on. A change asked for  *)
(* while a turn runs is STAGED and applied when that turn ends; RUNNINGON is  *)
(* the generation the running turn started on.                               *)
EXTENDS Integers

CONSTANTS MaxTurns, QueueLimit,
          MaxRetargets,  \* model changes a person asks for (model bound)
          Staged         \* TRUE holds a change asked for during a turn until it ends

VARIABLES phase,      \* idle working suspended stopping flushing completed stuck
          current,    \* the running turn, or 0
          queued,     \* prompts waiting, 0..QueueLimit
          minted,     \* turns created so far
          started,    \* turns that published turn.started
          workers,    \* turns with a completion message in flight
          terminals,  \* [turn -> how many terminal events published]
          sflushed,   \* session.completed published
          registered, \* still in the registry
          model,      \* the model generation the agent answers on
          staged,     \* a generation waiting for the running turn to end, or 0
          runningOn,  \* the generation the current turn started on
          retargets   \* model changes asked for so far

vars == <<phase, current, queued, minted, started, workers, terminals,
          sflushed, registered, model, staged, runningOn, retargets>>

modelVars == <<model, staged, runningOn, retargets>>

Turns == 1..MaxTurns

TypeOK ==
    /\ phase \in {"idle", "working", "suspended", "stopping",
                  "flushing", "completed", "stuck"}
    /\ current \in 0..MaxTurns
    /\ queued \in 0..QueueLimit
    /\ minted \in 0..MaxTurns
    /\ started \subseteq Turns
    /\ workers \subseteq Turns
    /\ terminals \in [Turns -> 0..2]
    /\ sflushed \in BOOLEAN
    /\ registered \in BOOLEAN
    /\ model \in 0..MaxRetargets
    /\ staged \in 0..MaxRetargets
    /\ runningOn \in 0..MaxRetargets
    /\ retargets \in 0..MaxRetargets

Init ==
    /\ phase = "idle"
    /\ current = 0
    /\ queued = 0
    /\ minted = 0
    /\ started = {}
    /\ workers = {}
    /\ terminals = [t \in Turns |-> 0]
    /\ sflushed = FALSE
    /\ registered = TRUE
    /\ model = 0
    /\ staged = 0
    /\ runningOn = 0
    /\ retargets = 0

(* The model a turn starting now gets: whatever was held for it, else the one *)
(* already in use. :APPLY-STAGED-MODEL.                                       *)
Applied == IF staged /= 0 THEN staged ELSE model

------------------------------------------------------------------------------
(* Starting a turn: mint, publish turn.started, apply a held model, start a   *)
(* worker.                                                                    *)
StartTurn(t) ==
    /\ current' = t
    /\ started' = started \cup {t}
    /\ workers' = workers \cup {t}
    /\ model' = Applied
    /\ staged' = 0
    /\ runningOn' = Applied

(* SUBMIT while idle starts at once; while working or suspended it queues,    *)
(* and past the limit it is refused with a declared reason (the new queue     *)
(* policy). While stopping or flushing it is refused.                         *)
SubmitIdle ==
    /\ phase = "idle"
    /\ minted < MaxTurns
    /\ minted' = minted + 1
    /\ StartTurn(minted + 1)
    /\ phase' = "working"
    /\ UNCHANGED <<queued, terminals, sflushed, registered, retargets>>

SubmitQueued ==
    /\ phase \in {"working", "suspended"}
    /\ queued < QueueLimit
    /\ queued' = queued + 1
    /\ UNCHANGED <<phase, current, minted, started, workers, terminals,
                   sflushed, registered>>
    /\ UNCHANGED modelVars

(* Overflow and stopping-phase refusals change no lifecycle state, so they    *)
(* are stuttering steps here; the kernel table declares their diagnostics.    *)

------------------------------------------------------------------------------
(* The current turn's completion message is delivered: identity matches, one  *)
(* terminal event is published, a held model is applied, and either the      *)
(* queue starts the next turn -- with a worker of its own -- or the cell goes *)
(* idle. FINISH-TURN.                                                         *)
FinishCurrent ==
    /\ phase = "working"
    /\ current /= 0
    /\ current \in workers
    /\ terminals' = [terminals EXCEPT ![current] = @ + 1]
    /\ model' = Applied
    /\ staged' = 0
    /\ IF queued > 0 /\ minted < MaxTurns
           THEN /\ minted' = minted + 1
                /\ queued' = queued - 1
                /\ current' = minted + 1
                /\ started' = started \cup {minted + 1}
                /\ workers' = (workers \ {current}) \cup {minted + 1}
                /\ runningOn' = Applied
                /\ phase' = "working"
           ELSE /\ current' = 0
                /\ workers' = workers \ {current}
                /\ phase' = "idle"
                /\ UNCHANGED <<minted, queued, started, runningOn>>
    /\ UNCHANGED <<sflushed, registered, retargets>>

(* A worker can end while suspended (it finished at a checkpoint before       *)
(* parking, or cancel raced the gate).                                        *)
FinishSuspended ==
    /\ phase = "suspended"
    /\ current /= 0
    /\ current \in workers
    /\ workers' = workers \ {current}
    /\ terminals' = [terminals EXCEPT ![current] = @ + 1]
    /\ current' = 0
    /\ model' = Applied
    /\ staged' = 0
    /\ UNCHANGED <<phase, queued, minted, started, sflushed, registered,
                   runningOn, retargets>>

(* The one turn STOPPING waits for reports: publish its terminal, publish     *)
(* session.completed, post the flush. RUN-CELL's completion arm.              *)
FinishStopping ==
    /\ phase = "stopping"
    /\ current /= 0
    /\ current \in workers
    /\ workers' = workers \ {current}
    /\ terminals' = [terminals EXCEPT ![current] = @ + 1]
    /\ current' = 0
    /\ phase' = "flushing"
    /\ sflushed' = TRUE
    /\ UNCHANGED <<queued, minted, started, registered>>
    /\ UNCHANGED modelVars

(* A completion whose turn is not current changes nothing. COMPLETE-TURN's    *)
(* stale arm, and the STUCK absorption: the message is consumed, no terminal  *)
(* event is published, no identity is touched.                                *)
DeliverStale ==
    /\ \E t \in workers :
        /\ t /= current
        /\ workers' = workers \ {t}
    /\ UNCHANGED <<phase, current, queued, minted, started, terminals,
                   sflushed, registered>>
    /\ UNCHANGED modelVars

(* In STUCK the coordinator has exited: a late completion is consumed as a    *)
(* diagnostic even for the turn that was current when the deadline fired.     *)
DeliverAfterStuck ==
    /\ phase = "stuck"
    /\ \E t \in workers : workers' = workers \ {t}
    /\ UNCHANGED <<phase, current, queued, minted, started, terminals,
                   sflushed, registered>>
    /\ UNCHANGED modelVars

------------------------------------------------------------------------------
Suspend ==
    /\ phase \in {"idle", "working"}
    /\ phase' = "suspended"
    /\ UNCHANGED <<current, queued, minted, started, workers, terminals,
                   sflushed, registered>>
    /\ UNCHANGED modelVars

(* Resume with a current turn re-enters working; with none and prompts       *)
(* queued it STARTS the next one -- the delivered spec resumed to idle and    *)
(* stranded the queue, disagreeing with the kernel table which stranded it a  *)
(* different way; both fixed together on integration day.                     *)
Resume ==
    /\ phase = "suspended"
    /\ IF current /= 0
           THEN /\ phase' = "working"
                /\ UNCHANGED <<current, queued, minted, started, workers,
                               model, staged, runningOn>>
           ELSE IF queued > 0 /\ minted < MaxTurns
                    THEN /\ phase' = "working"
                         /\ minted' = minted + 1
                         /\ queued' = queued - 1
                         /\ current' = minted + 1
                         /\ started' = started \cup {minted + 1}
                         /\ workers' = workers \cup {minted + 1}
                         /\ model' = Applied
                         /\ staged' = 0
                         /\ runningOn' = Applied
                    ELSE /\ phase' = "idle"
                         /\ UNCHANGED <<current, queued, minted, started, workers,
                                        model, staged, runningOn>>
    /\ UNCHANGED <<terminals, sflushed, registered, retargets>>

(* No Resume exists from stopping/flushing/stuck/completed: the resurrection  *)
(* bug is a transition this machine cannot express.                           *)

------------------------------------------------------------------------------
(* A person asks for another model. With no turn running it is applied at     *)
(* once; with one running it waits for that turn to end, so every request of  *)
(* a turn goes to one model. STAGED = FALSE is the witness that applies it at *)
(* once regardless. Stopping and flushing refuse it: a stuttering step, like  *)
(* the other refusals.                                                        *)
Retarget ==
    /\ phase \in {"idle", "working", "suspended"}
    /\ retargets < MaxRetargets
    /\ retargets' = retargets + 1
    /\ IF current = 0 \/ ~Staged
           THEN /\ model' = retargets + 1
                /\ staged' = 0
           ELSE /\ staged' = retargets + 1
                /\ UNCHANGED model
    /\ UNCHANGED <<phase, current, queued, minted, started, workers, terminals,
                   sflushed, registered, runningOn>>

------------------------------------------------------------------------------
(* BEGIN-STOPPING's two shapes: with a turn, drain it under a deadline; with  *)
(* none, publish completion and flush at once. The queue is discarded.        *)
Shutdown ==
    /\ phase \in {"idle", "working", "suspended"}
    /\ queued' = 0
    /\ IF current /= 0
           THEN /\ phase' = "stopping"
                /\ UNCHANGED sflushed
           ELSE /\ phase' = "flushing"
                /\ sflushed' = TRUE
    /\ UNCHANGED <<current, minted, started, workers, terminals, registered>>
    /\ UNCHANGED modelVars

(* The stop deadline: STUCK is a state, not a hang. The turn's worker may     *)
(* still be out there; its message is consumed by DeliverAfterStuck.          *)
Deadline ==
    /\ phase = "stopping"
    /\ phase' = "stuck"
    /\ current' = 0
    /\ UNCHANGED <<queued, minted, started, workers, terminals,
                   sflushed, registered>>
    /\ UNCHANGED modelVars

(* Completion is proven durable, then the session leaves the registry; an     *)
(* unconfirmed flush retries and the session stays inspectable.               *)
FlushConfirm ==
    /\ phase = "flushing"
    /\ phase' = "completed"
    /\ registered' = FALSE
    /\ UNCHANGED <<current, queued, minted, started, workers, terminals,
                   sflushed>>
    /\ UNCHANGED modelVars

FlushFail ==
    /\ phase = "flushing"
    /\ UNCHANGED vars

------------------------------------------------------------------------------
Next ==
    \/ SubmitIdle \/ SubmitQueued
    \/ FinishCurrent \/ FinishSuspended \/ FinishStopping
    \/ DeliverStale \/ DeliverAfterStuck
    \/ Suspend \/ Resume \/ Retarget \/ Shutdown \/ Deadline
    \/ FlushConfirm \/ FlushFail

(* Fairness for liveness: a delivered completion or the deadline eventually   *)
(* resolves a stopping session; the journal eventually confirms the flush.    *)
(* FLUSHFAIL deliberately has no fairness: an eternally failing journal is    *)
(* modelled, and shutdown liveness must hold anyway through retry -- which is *)
(* why FlushConfirm's weak fairness is the assumption that carries it.        *)
(* FINISHCURRENT gets STRONG fairness: the completion message sits in the     *)
(* mailbox and is consumed in any phase, so a client toggling suspend/resume  *)
(* forever cannot starve delivery in the real system -- weak fairness would   *)
(* let the model starve it, and TLC exhibits exactly that oscillation.        *)
(* FINISHSUSPENDED gets none: a closed gate may park a worker forever, which  *)
(* is what suspension means. RETARGET gets none: nobody has to change model.  *)
Fairness ==
    /\ SF_vars(FinishCurrent)
    /\ WF_vars(FinishStopping)
    /\ WF_vars(Deadline)
    /\ WF_vars(FlushConfirm)
    /\ WF_vars(DeliverStale)
    /\ WF_vars(DeliverAfterStuck)

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* Safety: the frozen invariants.                                             *)

AtMostOneTerminal == \A t \in Turns : terminals[t] <= 1

TerminalOnlyForStarted == \A t \in Turns : terminals[t] >= 1 => t \in started

CurrentIsStarted == current /= 0 => current \in started

(* Completion may not be claimed while owned work is outstanding.             *)
NoWorkAfterFlush ==
    phase \in {"flushing", "completed"} => current = 0

(* AWAIT-SHUTDOWN's contract: leaving the registry requires proven            *)
(* durability. STUCK stays registered forever, on purpose.                    *)
DeregisterOnlyCompleted == ~registered => (phase = "completed" /\ sflushed)

CompletedIsDurable == phase = "completed" => sflushed

(* A model change never reaches a turn already running: the turn answers on   *)
(* the model it started on, to its last request. The witness violates it.     *)
RunningTurnKeepsItsModel ==
    (current /= 0 /\ phase \in {"working", "suspended", "stopping"})
        => model = runningOn

(* A change asked for during a turn is applied when that turn ends, so a      *)
(* session at rest never holds one it has not made.                           *)
NothingStagedAtRest == phase = "idle" => staged = 0

------------------------------------------------------------------------------
(* Liveness under the stated fairness.                                        *)

(* Shutdown resolves: to durable completion or to declared STUCK, never to a  *)
(* silent hang.                                                               *)
ShutdownResolves ==
    (phase \in {"stopping", "flushing"}) ~> (phase \in {"completed", "stuck"})

(* Every completion message in flight is eventually consumed -- by the        *)
(* identity match, the stale arm, or the stuck diagnostic -- PROVIDED the     *)
(* session is not parked at a closed gate forever. A permanently suspended    *)
(* session legitimately never resolves its turn; suspension outliving turns   *)
(* is the design, so the property is conditioned on leaving suspension        *)
(* infinitely often.                                                          *)
WorkersDrain ==
    ([]<>(phase /= "suspended"))
        => \A t \in Turns : (t \in workers) ~> (t \notin workers)

==============================================================================
