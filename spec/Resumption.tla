----------------------------- MODULE Resumption -----------------------------
(* A prompt's way through a daemon that can die at any step, and the turn it   *)
(* becomes. Mirrors ACCEPT (src/daemon/actor.lisp), RESTORE-INTO and           *)
(* RESUME-WORK, and RESUME-TURN / SETTLE-UNANSWERED                            *)
(* (src/workspace/resumption.lisp).                                            *)
(*                                                                            *)
(* DURABLE is what survives a crash: the live marker (accepted, seen, running) *)
(* and the transcript (intent, result). VOLATILE is the process: what has      *)
(* arrived on the socket, replies not yet delivered, a worker, a call that ran *)
(* and whose result is not yet written. A crash clears the volatile half.      *)
(*                                                                            *)
(* Each turn makes two calls: READ, recorded harmless to repeat, and WRITE,    *)
(* recorded not. CURRENT is the tools' class in the running build, and WRITE   *)
(* may be declared harmless by a later one.                                    *)
EXTENDS Naturals

CONSTANTS Requests, MaxCrashes,
          AckBeforeWrite,     \* witness: acknowledged, then written down
          DedupeInMemory,     \* witness: request ids remembered in memory only
          RerunUnanswered,    \* witness: every call left without a result runs again
          TrustCurrentPolicy  \* witness: the tool's class now decides alone

Calls == {"read", "write"}
Recorded == [c \in Calls |-> IF c = "read" THEN "safe" ELSE "unsafe"]

VARIABLES
    up, crashes,
    pending, told,                          \* the client
    accepted, seen, running, intent, result, \* durable
    inbox, replies, owed, memSeen, working, ran, \* volatile
    current,                                \* the tools' class in this build
    turnsFor, executions, done              \* history

vars == <<up, crashes, pending, told, accepted, seen, running, intent, result,
          inbox, replies, owed, memSeen, working, ran, current,
          turnsFor, executions, done>>

TypeOK ==
    /\ up \in BOOLEAN /\ crashes \in 0..MaxCrashes
    /\ pending \subseteq Requests /\ told \subseteq Requests
    /\ accepted \subseteq Requests /\ seen \subseteq Requests
    /\ running \in Requests \cup {"none"}
    /\ intent \in [Requests -> [Calls -> BOOLEAN]]
    /\ result \in [Requests -> [Calls -> BOOLEAN]]
    /\ inbox \subseteq Requests /\ replies \subseteq Requests
    /\ owed \subseteq Requests /\ memSeen \subseteq Requests
    /\ working \in BOOLEAN
    /\ ran \in [Requests -> [Calls -> BOOLEAN]]
    /\ current \in [Calls -> {"safe", "unsafe"}]
    /\ turnsFor \in [Requests -> 0..3]
    /\ executions \in [Requests -> [Calls -> 0..3]]
    /\ done \subseteq Requests

No == [r \in Requests |-> [c \in Calls |-> FALSE]]
Zero == [r \in Requests |-> [c \in Calls |-> 0]]

Init ==
    /\ up = TRUE /\ crashes = 0
    /\ pending = Requests /\ told = {}
    /\ accepted = {} /\ seen = {} /\ running = "none"
    /\ intent = No /\ result = No
    /\ inbox = {} /\ replies = {} /\ owed = {} /\ memSeen = {}
    /\ working = FALSE /\ ran = No
    /\ current = Recorded
    /\ turnsFor = [r \in Requests |-> 0]
    /\ executions = Zero
    /\ done = {}

------------------------------------------------------------------------------
(* The client sends whatever it has not had confirmed, again after every       *)
(* reconnect, under the same request id.                                       *)
Send(r) ==
    /\ up /\ r \in pending /\ r \notin inbox
    /\ inbox' = inbox \cup {r}
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, intent,
                   result, replies, owed, memSeen, working, ran, current,
                   turnsFor, executions, done>>

(* ACCEPT. A request already seen is answered with the turn it became. A new  *)
(* one is written down, then answered; the witness answers first.             *)
Handle(r) ==
    /\ up /\ r \in inbox
    /\ inbox' = inbox \ {r}
    /\ replies' = replies \cup {r}
    /\ LET known == IF DedupeInMemory THEN memSeen ELSE seen IN
       IF r \in known
         THEN UNCHANGED <<accepted, seen, owed, memSeen, turnsFor>>
         ELSE /\ memSeen' = memSeen \cup {r}
              /\ turnsFor' = [turnsFor EXCEPT ![r] = @ + 1]
              /\ IF AckBeforeWrite
                   THEN /\ owed' = owed \cup {r}
                        /\ UNCHANGED <<accepted, seen>>
                   ELSE /\ accepted' = accepted \cup {r}
                        /\ seen' = seen \cup {r}
                        /\ UNCHANGED owed
    /\ UNCHANGED <<up, crashes, pending, told, running, intent, result,
                   working, ran, current, executions, done>>

WriteOwed(r) ==
    /\ up /\ r \in owed
    /\ owed' = owed \ {r}
    /\ accepted' = accepted \cup {r}
    /\ seen' = seen \cup {r}
    /\ UNCHANGED <<up, crashes, pending, told, running, intent, result, inbox,
                   replies, memSeen, working, ran, current, turnsFor,
                   executions, done>>

Confirm(r) ==
    /\ up /\ r \in replies
    /\ replies' = replies \ {r}
    /\ pending' = pending \ {r}
    /\ told' = told \cup {r}
    /\ UNCHANGED <<up, crashes, accepted, seen, running, intent, result, inbox,
                   owed, memSeen, working, ran, current, turnsFor,
                   executions, done>>

------------------------------------------------------------------------------
(* The turn: BEGIN-TURN, an intent before each call, the call, its result.    *)
Start(r) ==
    /\ up /\ ~working /\ running = "none"
    /\ r \in accepted /\ r \notin done
    /\ running' = r
    /\ working' = TRUE
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, intent, result,
                   inbox, replies, owed, memSeen, ran, current, turnsFor,
                   executions, done>>

Intend(c) ==
    /\ up /\ working /\ running # "none"
    /\ ~intent[running][c]
    /\ intent' = [intent EXCEPT ![running][c] = TRUE]
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, result,
                   inbox, replies, owed, memSeen, working, ran, current,
                   turnsFor, executions, done>>

Execute(c) ==
    /\ up /\ working /\ running # "none"
    /\ intent[running][c] /\ ~result[running][c] /\ ~ran[running][c]
    /\ executions[running][c] = 0
    /\ executions' = [executions EXCEPT ![running][c] = @ + 1]
    /\ ran' = [ran EXCEPT ![running][c] = TRUE]
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, intent,
                   result, inbox, replies, owed, memSeen, working, current,
                   turnsFor, done>>

WriteResult(c) ==
    /\ up /\ running # "none" /\ ran[running][c]
    /\ result' = [result EXCEPT ![running][c] = TRUE]
    /\ ran' = [ran EXCEPT ![running][c] = FALSE]
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, intent,
                   inbox, replies, owed, memSeen, working, current, turnsFor,
                   executions, done>>

Finish ==
    /\ up /\ working /\ running # "none"
    /\ \A c \in Calls : intent[running][c] /\ result[running][c]
    /\ done' = done \cup {running}
    /\ accepted' = accepted \ {running}
    /\ running' = "none"
    /\ working' = FALSE
    /\ UNCHANGED <<up, crashes, pending, told, seen, intent, result, inbox,
                   replies, owed, memSeen, ran, current, turnsFor, executions>>

------------------------------------------------------------------------------
(* The process dies. The marker and the transcript stay; nothing else does.   *)
Crash ==
    /\ up /\ crashes < MaxCrashes
    /\ up' = FALSE
    /\ crashes' = crashes + 1
    /\ inbox' = {} /\ replies' = {} /\ owed' = {} /\ memSeen' = {}
    /\ working' = FALSE /\ ran' = No
    /\ UNCHANGED <<pending, told, accepted, seen, running, intent, result,
                   current, turnsFor, executions, done>>

Restart ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<crashes, pending, told, accepted, seen, running, intent,
                   result, inbox, replies, owed, memSeen, working, ran, current,
                   turnsFor, executions, done>>

(* A later build declares WRITE harmless. Between crashes, as an upgrade is.  *)
Reclassify ==
    /\ ~up /\ current["write"] = "unsafe"
    /\ current' = [current EXCEPT !["write"] = "safe"]
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, intent,
                   result, inbox, replies, owed, memSeen, working, ran,
                   turnsFor, executions, done>>

(* RESUME-TURN: the marker says a turn was running and no worker runs it.     *)
(* Every call with an intent and no result is run again when that is safe,   *)
(* and answered as interrupted otherwise; then the turn carries on.           *)
Rerun(c) ==
    IF RerunUnanswered THEN TRUE
    ELSE IF TrustCurrentPolicy THEN current[c] = "safe"
    ELSE Recorded[c] = "safe" /\ current[c] = "safe"

Resume ==
    /\ up /\ ~working /\ running # "none"
    /\ LET r == running
           cut == {c \in Calls : intent[r][c] /\ ~result[r][c]}
           again == {c \in cut : Rerun(c)} IN
       /\ executions' = [executions EXCEPT ![r] =
                           [c \in Calls |-> IF c \in again THEN @[c] + 1 ELSE @[c]]]
       /\ ran' = [ran EXCEPT ![r] = [c \in Calls |-> c \in again]]
       /\ result' = [result EXCEPT ![r] =
                       [c \in Calls |-> IF c \in cut \ again THEN TRUE ELSE @[c]]]
    /\ working' = TRUE
    /\ UNCHANGED <<up, crashes, pending, told, accepted, seen, running, intent,
                   inbox, replies, owed, memSeen, current, turnsFor, done>>

------------------------------------------------------------------------------
Next ==
    \/ \E r \in Requests : Send(r) \/ Handle(r) \/ WriteOwed(r) \/ Confirm(r) \/ Start(r)
    \/ \E c \in Calls : Intend(c) \/ Execute(c) \/ WriteResult(c)
    \/ Finish \/ Crash \/ Restart \/ Reclassify \/ Resume

Fairness ==
    /\ \A r \in Requests : WF_vars(Send(r)) /\ WF_vars(Handle(r))
                           /\ WF_vars(WriteOwed(r)) /\ WF_vars(Confirm(r))
                           /\ WF_vars(Start(r))
    /\ \A c \in Calls : WF_vars(Intend(c)) /\ WF_vars(Execute(c)) /\ WF_vars(WriteResult(c))
    /\ WF_vars(Finish) /\ WF_vars(Restart) /\ WF_vars(Resume)

Spec == Init /\ [][Next]_vars /\ Fairness

------------------------------------------------------------------------------
(* An acknowledged prompt is written down or finished, whatever crashes.      *)
AcknowledgedSurvives == \A r \in told : r \in accepted \cup done

(* A request becomes one turn, however often it is sent.                      *)
OneTurnPerRequest == \A r \in Requests : turnsFor[r] <= 1

(* A call not recorded harmless runs at most once, across every crash.        *)
UnsafeAtMostOnce == \A r \in Requests : executions[r]["write"] <= 1

(* A finished turn left no call without a result: no provider accepts that.   *)
NothingLeftUnanswered ==
    \A r \in done : \A c \in Calls : intent[r][c] => result[r][c]

(* Every prompt the client sends is eventually run to the end.               *)
EverySentPromptRuns == \A r \in Requests : <>(r \in done)

==============================================================================
