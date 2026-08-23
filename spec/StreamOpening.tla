------------------------------ MODULE StreamOpening ------------------------------
(* A session's stream opens with the session opening.                         *)
(*                                                                            *)
(* Unstated until it broke, which is why it broke. While the cell's worker    *)
(* thread was the only publisher, its first act being SESSION.STARTED made    *)
(* that event sequence 1 by construction, and nobody wrote the property down. *)
(*                                                                            *)
(* Resuming added a SECOND publisher. START-SESSION reloads a recorded        *)
(* conversation and publishes it into the new cell from the CALLER's thread,  *)
(* the moment SPAWN returns -- and SPAWN returns as soon as the worker thread *)
(* is made, not once it has run. So two threads race to publish first, and    *)
(* the caller won twenty times out of twenty: the transcript arrived before   *)
(* the session had started.                                                   *)
(*                                                                            *)
(* NOTHING WAS LOST. The cell lock assigns sequence numbers atomically, so    *)
(* the stream stayed contiguous and every event was delivered exactly once --  *)
(* which is precisely why the existing ReplayBarrier proof kept holding and   *)
(* said nothing about this. Contiguity is not ordering-by-meaning.            *)
(*                                                                            *)
(* Broken = TRUE models the worker publishing SESSION.STARTED as its first    *)
(* act. Broken = FALSE models the fix: SPAWN publishes it before the thread   *)
(* exists, so no other publisher can precede it.                              *)
EXTENDS Integers, Sequences

CONSTANTS Announcements,  \* how many events the resume publishes (model bound)
          Broken          \* TRUE checks the racing arrangement

VARIABLES log,       \* the cell's event stream, in sequence order
          spawned,   \* the cell exists and its registration is visible
          worker,    \* the worker thread has started running
          pending    \* announcements the caller has still to publish

vars == <<log, spawned, worker, pending>>

Started == "session.started"
Resumed == "user.message"

TypeOK ==
    /\ spawned \in BOOLEAN
    /\ worker \in BOOLEAN
    /\ pending \in 0..Announcements
    /\ \A i \in 1..Len(log) : log[i] \in {Started, Resumed}

Init ==
    /\ log = <<>>
    /\ spawned = FALSE
    /\ worker = FALSE
    /\ pending = Announcements

------------------------------------------------------------------------------
(* SPAWN. Registers the cell and makes the worker thread. In the fixed        *)
(* arrangement it also publishes SESSION.STARTED first -- in the SAME step,   *)
(* because it happens before any other thread can exist to interleave with.   *)

Spawn ==
    /\ ~spawned
    /\ spawned' = TRUE
    /\ log' = IF Broken THEN log ELSE Append(log, Started)
    /\ UNCHANGED <<worker, pending>>

(* The worker begins running at a moment nobody controls.                     *)
StartWorker ==
    /\ spawned
    /\ ~worker
    /\ worker' = TRUE
    /\ UNCHANGED <<log, spawned, pending>>

(* Its first act, in the racing arrangement.                                  *)
WorkerAnnouncesStart ==
    /\ Broken
    /\ worker
    /\ \A i \in 1..Len(log) : log[i] # Started
    /\ log' = Append(log, Started)
    /\ UNCHANGED <<spawned, worker, pending>>

(* The caller publishes the resumed conversation as soon as SPAWN returns.    *)
(* It does not wait for the worker, and has no way to know whether it has run.*)
CallerAnnouncesResume ==
    /\ spawned
    /\ pending > 0
    /\ pending' = pending - 1
    /\ log' = Append(log, Resumed)
    /\ UNCHANGED <<spawned, worker>>

(* Everything that was going to happen has happened. Stated explicitly rather *)
(* than disabling deadlock checking: a spec that cannot say when it is done   *)
(* cannot tell "finished" from "stuck", and telling those apart is most of    *)
(* what these files are for.                                                  *)
Done ==
    /\ spawned
    /\ worker
    /\ pending = 0
    /\ \E i \in 1..Len(log) : log[i] = Started
    /\ UNCHANGED vars

Next ==
    \/ Spawn
    \/ StartWorker
    \/ WorkerAnnouncesStart
    \/ CallerAnnouncesResume
    \/ Done

Fairness ==
    /\ WF_vars(Spawn)
    /\ WF_vars(StartWorker)
    /\ WF_vars(WorkerAnnouncesStart)
    /\ WF_vars(CallerAnnouncesResume)

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* THE invariant: if anything has been published, the first thing published   *)
(* was the session starting. Checked at every instant, not at the end -- a    *)
(* client reads the stream while it is being written.                         *)

OpensWithStart == Len(log) > 0 => log[1] = Started

(* And it is announced exactly once, however the threads interleave.          *)
StartedOnce ==
    Len(SelectSeq(log, LAMBDA event : event = Started)) <= 1

(* Liveness: the conversation does arrive, and the session does start.        *)
EventuallyWhole ==
    <>[](/\ Len(SelectSeq(log, LAMBDA event : event = Started)) = 1
         /\ Len(SelectSeq(log, LAMBDA event : event = Resumed)) = Announcements)

==============================================================================
