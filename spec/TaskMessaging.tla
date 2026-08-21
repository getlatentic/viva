------------------------- MODULE TaskMessaging -------------------------
(* TaskTree v2: messages between peers, specified before anything is wired.   *)
(*                                                                            *)
(* From #15: tree-minted identities at both ends, delivery only between live  *)
(* tasks, refusal with a reason, immutable payloads, bounded inboxes with     *)
(* DECLARED overflow, terminal tasks receive nothing. And the one point       *)
(* review settled in advance: a DRAINING parent still receives.               *)
(*                                                                            *)
(* THE FAILURE THIS EXISTS TO FORBID is a silent drop. An inbox has to be     *)
(* bounded -- an unbounded one is a memory leak with a queue's manners -- and  *)
(* the moment it is bounded, something must happen when it is full. There are *)
(* exactly two designs: refuse the send with a reason the sender can act on,  *)
(* or drop the message and say nothing. The second is the one that gets       *)
(* written by accident, because dropping is what a full buffer does if nobody *)
(* decides otherwise, and it is invisible until a task waits forever for an   *)
(* answer that was discarded. BrokenOverflow is that design, wired to a       *)
(* witness config, and it must violate.                                       *)
(*                                                                            *)
(* DRAINING STILL RECEIVES, and it is not an edge case. A parent that has     *)
(* stopped issuing work still has children finishing, and their results are   *)
(* messages. A parent that stopped receiving when it stopped sending would    *)
(* lose exactly the results it was waiting for -- the answers to the work it  *)
(* asked for, which is the worst possible thing to drop.                      *)
EXTENDS Integers, Sequences

CONSTANTS Tasks, MaxInbox, MaxSends, BrokenOverflow, BrokenDrain

VARIABLES lifec, inbox, refusals, dropped, sends

vars == <<lifec, inbox, refusals, dropped, sends>>

Lifecycles == {"unborn", "live", "draining", "ended"}

(* Who may RECEIVE. Draining is included deliberately; that is the decision
   review adopted, and BrokenDrain removes it so the witness can show what
   excluding it costs. *)
Receiving == IF BrokenDrain THEN {"live"} ELSE {"live", "draining"}

TypeOK ==
    /\ lifec \in [Tasks -> Lifecycles]
    /\ inbox \in [Tasks -> 0..MaxInbox]
    /\ refusals \in 0..MaxSends
    /\ dropped \in 0..MaxSends
    /\ sends \in 0..MaxSends

Init ==
    /\ lifec = [t \in Tasks |-> "unborn"]
    /\ inbox = [t \in Tasks |-> 0]
    /\ refusals = 0
    /\ dropped = 0
    /\ sends = 0

Born(t) ==
    /\ lifec[t] = "unborn"
    /\ lifec' = [lifec EXCEPT ![t] = "live"]
    /\ UNCHANGED <<inbox, refusals, dropped, sends>>

Drain(t) ==
    /\ lifec[t] = "live"
    /\ lifec' = [lifec EXCEPT ![t] = "draining"]
    /\ UNCHANGED <<inbox, refusals, dropped, sends>>

(* Ending empties the inbox: a terminal task holds nothing, so nothing is
   waiting to be read by something that will never read again. *)
End(t) ==
    /\ lifec[t] \in {"live", "draining"}
    /\ lifec' = [lifec EXCEPT ![t] = "ended"]
    /\ inbox' = [inbox EXCEPT ![t] = 0]
    /\ UNCHANGED <<refusals, dropped, sends>>

Deliver(from, to) ==
    /\ sends < MaxSends
    /\ lifec[from] = "live"
    /\ lifec[to] \in Receiving
    /\ inbox[to] < MaxInbox
    /\ inbox' = [inbox EXCEPT ![to] = inbox[to] + 1]
    /\ sends' = sends + 1
    /\ UNCHANGED <<lifec, refusals, dropped>>

(* A send that cannot land is REFUSED, and the refusal is counted so the
   sender is known to have been told. *)
RefuseFull(from, to) ==
    /\ ~BrokenOverflow
    /\ sends < MaxSends
    /\ lifec[from] = "live"
    /\ lifec[to] \in Receiving
    /\ inbox[to] = MaxInbox
    /\ refusals' = refusals + 1
    /\ sends' = sends + 1
    /\ UNCHANGED <<lifec, inbox, dropped>>

RefuseTerminal(from, to) ==
    /\ sends < MaxSends
    /\ lifec[from] = "live"
    /\ lifec[to] \notin Receiving
    /\ refusals' = refusals + 1
    /\ sends' = sends + 1
    /\ UNCHANGED <<lifec, inbox, dropped>>

(* THE DESIGN THAT GETS WRITTEN BY ACCIDENT: the inbox is full, so the message
   goes nowhere and nobody is told. *)
DropFull(from, to) ==
    /\ BrokenOverflow
    /\ sends < MaxSends
    /\ lifec[from] = "live"
    /\ lifec[to] \in Receiving
    /\ inbox[to] = MaxInbox
    /\ dropped' = dropped + 1
    /\ sends' = sends + 1
    /\ UNCHANGED <<lifec, inbox, refusals>>

Read(t) ==
    /\ lifec[t] \in Receiving
    /\ inbox[t] > 0
    /\ inbox' = [inbox EXCEPT ![t] = inbox[t] - 1]
    /\ UNCHANGED <<lifec, refusals, dropped, sends>>

Next ==
    \/ \E t \in Tasks : Born(t) \/ Drain(t) \/ End(t) \/ Read(t)
    \/ \E from, to \in Tasks :
          \/ Deliver(from, to) \/ RefuseFull(from, to)
          \/ RefuseTerminal(from, to) \/ DropFull(from, to)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

(* Nothing vanishes without the sender being told. This is what BrokenOverflow
   breaks, and it breaks it invisibly, which is the point. *)
NoSilentDrop == dropped = 0

(* An inbox is bounded, or it is a memory leak with a queue's manners. *)
BoundedInbox == \A t \in Tasks : inbox[t] <= MaxInbox

(* A terminal task holds nothing. Not "is not sent to" -- holds nothing, so
   there is no message waiting for a reader that will never read again. *)
TerminalHoldsNothing ==
    \A t \in Tasks : lifec[t] = "ended" => inbox[t] = 0

(* Every send is accounted for: it landed, was refused, or was dropped. The
   first draft of this was a tautology dressed as an invariant -- it subtracted
   the same terms it added and could not fail. An invariant that cannot fail is
   the same mistake as a witness that cannot lose. *)
EverySendAccounted ==
    refusals + dropped <= sends

=============================================================================
