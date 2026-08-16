------------------------------ MODULE ReplayBarrier ------------------------------
(* The SUBSCRIBE-SINCE slow path from actor.lisp, checked exhaustively.       *)
(*                                                                            *)
(* One publisher assigns sequence numbers under the cell lock. A ring keeps   *)
(* the last RingSize events. A journal owner commits events to disk in order. *)
(* A subscriber arrives needing every event from 1, exactly once, in order,   *)
(* however fast the publisher runs meanwhile.                                 *)
(*                                                                            *)
(* Broken = FALSE models the shipped algorithm:                               *)
(*     1  under the lock: BARRIER = current sequence, register STAGING        *)
(*     2  journal sync: proceed once committed >= BARRIER                     *)
(*     3  read the file through BARRIER into the destination                  *)
(*     4  under the lock: drain staging, swap registration to destination     *)
(*                                                                            *)
(* Broken = TRUE models the old composition that the soak never caught:       *)
(*     freeze C = committed, read disk through C, then read the ring above C. *)
(* Everything that crossed from ring to disk during the read is in neither    *)
(* half. TLC finds that gap in seconds at RingSize = 2.                       *)
EXTENDS Integers, Sequences

CONSTANTS MaxSeq,    \* how far the publisher may run (model bound)
          RingSize,  \* +tail-limit+
          Broken     \* TRUE checks the pre-fix algorithm

VARIABLES seq,       \* last sequence assigned by the publisher
          committed, \* highest sequence the journal has confirmed on disk
          sphase,    \* subscriber phase
          barrier,   \* newest sequence the catch-up covers
          staging,   \* the staging mailbox: events published while catching up
          delivered  \* what the destination mailbox has received, in order

vars == <<seq, committed, sphase, barrier, staging, delivered>>

Phases == {"idle", "staged", "synced", "readdone", "live"}

Ring == {n \in 1..seq : n > seq - RingSize}

TypeOK ==
    /\ seq \in 0..MaxSeq
    /\ committed \in 0..MaxSeq
    /\ committed <= seq
    /\ sphase \in Phases
    /\ barrier \in 0..MaxSeq

Init ==
    /\ seq = 0
    /\ committed = 0
    /\ sphase = "idle"
    /\ barrier = 0
    /\ staging = <<>>
    /\ delivered = <<>>

------------------------------------------------------------------------------
(* The publisher: PUBLISH assigns the next sequence under the cell lock and   *)
(* delivers to whichever mailbox the subscriber has registered at that        *)
(* instant. Registration to STAGING or the destination happens under the      *)
(* same lock, so exactly one of these cases applies per event.                *)

(* The ring's no-evict-before-commit rule: publishing seq+1 displaces slot    *)
(* seq+1-RingSize, and displacing an uncommitted event is a DECLARED          *)
(* degradation, outside the exactness claim being checked here. So the model  *)
(* publisher waits for the displaced event to be committed, which makes any   *)
(* Contiguous violation TLC finds a SILENT loss: on disk, read by nobody.     *)
Publish ==
    /\ seq < MaxSeq
    /\ (seq + 1 <= RingSize \/ seq + 1 - RingSize <= committed)
    /\ seq' = seq + 1
    /\ IF ~Broken /\ sphase \in {"staged", "synced", "readdone"}
           THEN /\ staging' = Append(staging, seq + 1)
                /\ UNCHANGED delivered
       ELSE IF sphase = "live"
           THEN /\ delivered' = Append(delivered, seq + 1)
                /\ UNCHANGED staging
       ELSE UNCHANGED <<staging, delivered>>
    /\ UNCHANGED <<committed, sphase, barrier>>

(* The journal owner: commits strictly in order (FIFO mailbox, one owner).    *)
Commit ==
    /\ committed < seq
    /\ committed' = committed + 1
    /\ UNCHANGED <<seq, sphase, barrier, staging, delivered>>

------------------------------------------------------------------------------
(* The shipped algorithm.                                                     *)

Register ==
    /\ ~Broken
    /\ sphase = "idle"
    /\ barrier' = seq                 \* under the cell lock, with staging
    /\ sphase' = "staged"             \* registered in the same instant
    /\ UNCHANGED <<seq, committed, staging, delivered>>

(* JOURNAL-SYNC: the :sync marker is FIFO behind every append <= barrier,     *)
(* because those appends were posted while their publisher held the cell      *)
(* lock that BARRIER was read under. Signalled means committed >= barrier.    *)
Sync ==
    /\ ~Broken
    /\ sphase = "staged"
    /\ committed >= barrier
    /\ sphase' = "synced"
    /\ UNCHANGED <<seq, committed, barrier, staging, delivered>>

(* READ-JOURNAL (0, barrier]: everything <= barrier is on disk after Sync.    *)
ReadDisk ==
    /\ ~Broken
    /\ sphase = "synced"
    /\ delivered' = [i \in 1..barrier |-> i]
    /\ sphase' = "readdone"
    /\ UNCHANGED <<seq, committed, barrier, staging>>

(* Under the cell lock: drain staging into the destination, swap the          *)
(* registration. The publisher is excluded, so no event falls between the     *)
(* two registrations.                                                         *)
DrainSwap ==
    /\ ~Broken
    /\ sphase = "readdone"
    /\ delivered' = delivered \o staging
    /\ staging' = <<>>
    /\ sphase' = "live"
    /\ UNCHANGED <<seq, committed, barrier>>

------------------------------------------------------------------------------
(* The old composition, kept so TLC can exhibit the defect it had.            *)

RegisterOld ==
    /\ Broken
    /\ sphase = "idle"
    /\ barrier' = committed           \* froze the DISK boundary, not the
    /\ sphase' = "staged"             \* sequence, and registered nothing
    /\ UNCHANGED <<seq, committed, staging, delivered>>

ReadDiskOld ==
    /\ Broken
    /\ sphase = "staged"
    /\ delivered' = [i \in 1..barrier |-> i]
    /\ sphase' = "readdone"
    /\ UNCHANGED <<seq, committed, barrier, staging>>

(* Reacquire the lock and take whatever the ring still holds above barrier.   *)
Max(a, b) == IF a > b THEN a ELSE b

RingReadOld ==
    /\ Broken
    /\ sphase = "readdone"
    /\ LET lo == Max(barrier + 1, Max(seq - RingSize + 1, 1))
       IN delivered' = IF seq >= lo
                           THEN delivered \o [i \in 1..(seq - lo + 1) |-> lo + i - 1]
                           ELSE delivered
    /\ sphase' = "live"
    /\ UNCHANGED <<seq, committed, barrier, staging>>

------------------------------------------------------------------------------
Next ==
    \/ Publish \/ Commit
    \/ Register \/ Sync \/ ReadDisk \/ DrainSwap
    \/ RegisterOld \/ ReadDiskOld \/ RingReadOld

Fairness ==
    /\ WF_vars(Commit)
    /\ WF_vars(Register) /\ WF_vars(Sync)
    /\ WF_vars(ReadDisk) /\ WF_vars(DrainSwap)

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* THE invariant: the destination mailbox receives 1, 2, 3, ... -- every      *)
(* sequence exactly once, in order, no gaps, no duplicates -- at every        *)
(* instant, not merely at the end.                                            *)

Contiguous == \A i \in 1..Len(delivered) : delivered[i] = i

(* Liveness: the catch-up terminates and the subscriber ends up complete.     *)
EventuallyComplete == <>[](sphase = "live" /\ Len(delivered) = seq)

==============================================================================
