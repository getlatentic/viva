------------------------------ MODULE Recovery ------------------------------
(* A session outliving the daemon that was running it.                        *)
(*                                                                            *)
(* It does now. A live marker says which sessions were open; each comes back  *)
(* as a resume of its own transcript under its own id, which is the ordinary  *)
(* path and not a special one. Before this, the journal and the transcript     *)
(* were durable and the CELL was not: when the daemon stopped, every live      *)
(* session went with it, and a person reconstructed one by hand from the       *)
(* picker -- as a NEW session that happened to hold the same conversation.     *)
(*                                                                            *)
(* Two hazards stand between that and durable sessions, and neither is         *)
(* reachable by a test, because both need a crash at one exact instant.        *)
(*                                                                            *)
(* ORDERING. An event that is told to a client before it is written down is    *)
(* lost if the daemon dies in between -- and lost in the worst direction: the  *)
(* client SAW it, so after recovery the record is behind what a person read.   *)
(* ORDERED = TRUE models writing first.                                        *)
(*                                                                            *)
(* THE DAEMON IS ORDERED = FALSE TODAY, and on purpose. REMEMBER-EVENT posts   *)
(* the write to the journal thread and PUBLISH hands the event to subscribers  *)
(* in the same critical section, because blocking every session on a slow disk *)
(* is the worse trade for a thing meant to stay live. So this witness is not a *)
(* hypothetical: it is the current window, and the model says how wide the     *)
(* promise can be. Closing it means committing before delivering, and paying   *)
(* a disk write per event to do it.                                            *)
(*                                                                            *)
(* IDENTITY. A session was named by an in-memory counter, `s1`, `s2`, which    *)
(* restarted at zero with the daemon. Rehydrating cells under that naming      *)
(* would have been worse than losing them: every client holding `s1` would go  *)
(* on addressing `s1`, and `s1` would be a different conversation. DURABLE =   *)
(* TRUE is the arrangement now: the cell is named by its transcript, which no  *)
(* restart can mint again. DURABLE = FALSE is the witness that says why.       *)
EXTENDS Integers, Sequences

CONSTANTS Events,     \* events one conversation produces (model bound)
          Restarts,   \* how many times the daemon is allowed to die
          Ordered,    \* TRUE writes an event down before telling anyone
          Durable     \* TRUE names a session by its record, not by a counter

VARIABLES journal,    \* what survives a crash
          delivered,  \* what a client has been told, and cannot un-see
          made,       \* events this conversation has produced
          up,         \* the daemon is running
          epoch,      \* how many times it has been restarted
          counter,    \* the in-memory id counter, which restarts at zero
          bound       \* every <<name, conversation>> ever handed out

vars == <<journal, delivered, made, up, epoch, counter, bound>>

(* A conversation is told apart by when it was opened. A name is what a       *)
(* client addresses it by, and is the same thing only when it is durable.     *)
Conversation(era, n) == <<era, n>>
Name(era, n) == IF Durable THEN <<era, n>> ELSE <<0, n>>

TypeOK ==
    /\ journal \in Seq(Nat)
    /\ delivered \in Seq(Nat)
    /\ made \in 0..Events
    /\ up \in BOOLEAN
    /\ epoch \in 0..Restarts
    /\ counter \in 0..Events

Init ==
    /\ journal = << >>
    /\ delivered = << >>
    /\ made = 0
    /\ up = TRUE
    /\ epoch = 0
    /\ counter = 0
    /\ bound = {}

(* Opening a session mints a name and binds it to this conversation. *)
Open ==
    /\ up
    /\ counter < Events
    /\ LET next == counter + 1
       IN /\ counter' = next
          /\ bound' = bound \cup {<<Name(epoch, next), Conversation(epoch, next)>>}
    /\ UNCHANGED <<journal, delivered, made, up, epoch>>

Produce ==
    /\ up
    /\ counter > 0
    /\ made < Events
    /\ made' = made + 1
    /\ UNCHANGED <<journal, delivered, up, epoch, counter, bound>>

(* Writing it down. Only ever appends, and never twice. *)
Record ==
    /\ up
    /\ made > Len(journal)
    /\ journal' = Append(journal, Len(journal) + 1)
    /\ UNCHANGED <<delivered, made, up, epoch, counter, bound>>

(* Telling a client. Under ORDERED it may only say what is already written. *)
Tell ==
    /\ up
    /\ made > Len(delivered)
    /\ Ordered => Len(journal) > Len(delivered)
    /\ delivered' = Append(delivered, Len(delivered) + 1)
    /\ UNCHANGED <<journal, made, up, epoch, counter, bound>>

(* The lid closes on a flat battery, or the power goes. Whatever was not     *)
(* written down was never anywhere but memory. What a person already read is *)
(* not undone by the machine stopping.                                       *)
Crash ==
    /\ up
    /\ epoch < Restarts
    /\ up' = FALSE
    /\ UNCHANGED <<journal, delivered, made, epoch, counter, bound>>

Restart ==
    /\ ~up
    /\ up' = TRUE
    /\ epoch' = epoch + 1
    /\ counter' = 0          \* in memory, and memory is what was lost
    /\ made' = 0
    /\ UNCHANGED <<journal, delivered, bound>>

Next == Open \/ Produce \/ Record \/ Tell \/ Crash \/ Restart

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

(* WHAT A PERSON READ IS IN THE RECORD. Not the other way round: the journal  *)
(* running ahead of the screen is ordinary, and is what recovery is for.      *)
NothingLost == Len(delivered) =< Len(journal)

(* A NAME MEANS ONE CONVERSATION, FOREVER. Reusing `s1` for a new session     *)
(* after a restart does not lose a session -- it silently points every client  *)
(* holding that name at somebody else's.                                      *)
OneMeaning ==
    \A first, second \in bound : first[1] = second[1] => first[2] = second[2]

=============================================================================
