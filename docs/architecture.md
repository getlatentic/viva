# Vivarium — the frozen architecture

Decided 2026-08-15. **Not to be revisited.** Everything below is the shape to
build against; the parts not yet built are named as such rather than argued
about again.

The rule the whole design turns on:

```
terminal lifetime  !=  vivarium lifetime
task lifetime      !=  vivarium lifetime
RPC lifetime       !=  vivarium lifetime
```

Vivarium is a **long-lived organism**, and self-modification is a property of
that process rather than something bolted onto a short-lived CLI. A harness that
exits after each task can only ever pretend to evolve.

```
                         VIVARIUMD
               persistent Common Lisp / SBCL
                         organism
                            |
        +-------------------+--------------------+
        |                   |                    |
   agent runtime        session runtime      future evolution
   model loop           tasks/events         versions/branches
   tools                workers              improvements
   conditions           persistence          rollback
        |                   |                    |
        +-------------------+--------------------+
                            |
                    VIVARIUM PROTOCOL
                    JSON-RPC + events
                            |
              +-------------+-------------+
              |                           |
        INTERACTIVE                  NON-INTERACTIVE
       Rust / Ratatui                  RPC clients
       + Crossterm                         |
              |                    CLI / IDE / CI /
              |                    Python / agents
          `vivarium`
```

`vivarium` finds a running `vivariumd`, starts one if absent, connects, and
opens the interactive client. **Closing the client leaves the organism alive.**
`vivarium attach [session]` comes back to it.

## Frozen decisions

| | |
|---|---|
| **core** | SBCL, one persistent long-lived process |
| **concurrency** | `sb-thread` + `sb-concurrency` mailboxes. No second async runtime. |
| **failure model** | conditions and **restarts**, scoped to a task or session |
| **sessions** | long-lived inside the organism; one concrete durable event store |
| **events** | structured, frontend-neutral; the core never renders |
| **protocol** | JSON-RPC-style requests plus server notifications |
| **transport** | persistent local IPC; stdio is an *adapter*, not the owner |
| **interactive** | Rust + Ratatui + Crossterm, dumb relative to the organism |
| **non-interactive** | RPC directly; one-shot CLI as a convenience wrapper |
| **GUI** | later, React over the same protocol and events |

## Concurrency: a mailbox per session, and work off the coordinator

The invariant is **one authoritative serialization point per session** — not one
thread doing everything. Those are easy to confuse and the difference is the
whole control plane:

```
                 SESSION CELL
   +---------------------------------------+
   |  state, mailbox, event log            |   coordinator: never blocks
   |  steering queue, abort flag, gate     |
   +------------------+--------------------+
                      | starts, then goes back to receiving
                      v
                 TURN WORKER                    blocking work: model, tools
              model -> tools -> model
                      |
             checkpoints between steps
```

Every state change happens on the coordinator, including the ones the worker
asks for by posting `:finished` back rather than mutating the cell from
underneath. But the coordinator does not perform the turn, and for one commit it
did: `harness:ask` ran on the session's own thread, so nothing could be received
until the turn was over. Steer, cancel and suspend all existed, were all
delivered, and every one of them meant *after the thing you wanted to interrupt
has finished*.

Messages a session accepts: `:user-message` `:finished` `:cancel` `:suspend`
`:resume` `:steer` `:shutdown`. A prompt arriving mid-turn is queued, not run
beside the turn it arrived during.

Control is **cooperative**, observed at `agent:checkpoint` and nowhere else.
SB-THREAD's own manual reserves `interrupt-thread` for interactive debugging,
and an asynchronous unwind arriving in the middle of a file write leaves state
no restart can reason about. Suspension is an `sb-concurrency:gate`, because the
question a held run asks is *may I proceed*, not *has something happened* — a
waiter arriving after a condition variable's notification waits forever, and
that race is exactly the shape of a resume landing before the run reaches its
checkpoint.

Cancellation is asked about at one place, the run's single exit, rather than
wherever it was noticed. A run can stop through a checkpoint, an aborted stream
or a turn declining to take another, and `turn.cancelled` was emitted at the
first of those — so the event existed, was documented, and never fired in the
usual case, which is a cancel arriving during a request because that is where
the time goes.

### Lifecycle invariants

Stated so they can be attacked, and each is attacked in `tests/daemon.lisp` by
reverting the implementation and confirming the test fails:

```
A TURN HAS EXACTLY ONE TERMINAL OUTCOME
    turn.completed | turn.cancelled | turn.failed -- one, per turn.started

SESSION.COMPLETED => NOTHING THE SESSION OWNS CAN STILL CHANGE THE WORLD
    no worker running, no file to be written, no provider call outstanding

A SESSION IS FINDABLE UNTIL ITS WORK HAS STOPPED
    deregistration follows quiescence, never the shutdown request
```

The second is not tidiness. Once a session's own work can install code, a
lifecycle model that says *finished* while a worker is still unwinding is not
imprecise — it is false, and everything built on top of it inherits the lie.

A shutting-down session therefore keeps receiving until its turn reports, and a
session whose turn never reports becomes `:stuck`: it stays in the registry,
publishes `session.error`, and does not claim to have completed. An earlier
version published `session.completed` with an `unquiesced` flag, which is the
same as saying *the invariant holds, except when this says it doesn't*. An
event name must not need a flag denying what it means.

A turn that reported both cancelled *and* completed shipped, and its test
asserted both as correct. Invariants get written down first now.

### The concurrency laws

> **Parallelism in work. Serialization in authority.**

Many things may compute at once; the right to *change* something belongs to one
owner. Sessions run concurrently, turns run on their own threads, tools run in
parallel batches — and every state transition still happens on one thread that
owns it. When the task supervisor and the evolution owner arrive, they are the
same idea again: topology has one writer, the promoted lineage has one writer.


Every actor added from here — tasks, sub-agents, the evolution coordinator —
follows these. They are worth more than another dozen race-specific fixes,
because they turn a whole class of bug into a code-review violation.

```
 1  ONE OWNER PER MUTABLE AUTHORITY
 2  WORKERS COMPUTE; OWNERS TRANSITION STATE
 3  EVERY ASYNCHRONOUS OPERATION HAS AN IDENTITY
 4  STALE MESSAGES ARE HARMLESS
 5  MAILBOXES CROSS OWNERSHIP BOUNDARIES
 6  COOPERATIVE CANCELLATION ONLY
 7  GATES FOR SUSPENSION
 8  CONDITIONS AND RESTARTS FOR RECOVERY
 9  DYNAMIC TASK CONTEXT IS EXPLICITLY REBOUND IN NEW THREADS
10  GLOBAL PROMOTION IS SERIALIZED
11  EVENTS HAVE ONE LINEARIZED HISTORY
12  THREAD LIVENESS IS DIAGNOSTIC, NEVER BUSINESS STATE
```

Law 12 is the one that has already cost most. `busy-p` asked
`bt:thread-alive-p`, which SBCL's own manual says may be stale before it
returns — but the deeper mistake was letting a lifecycle depend on whether an
OS thread had finished exiting. A worker that posted its completion and exited
read as *not busy*; a prompt arriving in that window started a second turn, and
the first turn's completion — still in the mailbox — then cleared the second
turn's identity and published a terminal event for work that was still running.
Busy now means *there is a turn whose outcome the coordinator has not consumed*.

Laws 3 and 4 are the general form. A turn has an id; its completion carries it;
control messages may name one and are ignored when they name a turn that has
ended. You do not make concurrency perfectly timed — you make mistimed messages
unable to corrupt current state.

Law 9 is not optional bookkeeping: SBCL threads do **not** inherit their
parent's dynamic bindings, so a `*activation-context*` bound around a
`make-thread` is not seen inside it. The child sees the global value. Every
worker and every spawned task must rebind explicitly, which makes inheritance a
decision rather than ambient state — the same reason `call-in-tool-context`
exists for parallel tool batches.

Law 11 has a linearization point: sequence number, stored event and subscriber
snapshot are decided in one critical section, so `subscribe-since` gives a
barrier with nothing lost and nothing repeated. Ordering across that barrier is
the reader's job via `seq`; replaying under the lock would let a client that
stopped reading its socket stall the session.

### Recovery: conditions offer, policy chooses

Failure is not a return value travelling up through every layer. The place
something fails knows what happened and which continuations are coherent; it
does not know whether retrying is affordable or whether this provider has been
failing all morning. So a boundary offers restarts and something further out
chooses.

```
     model request                        tool call
     -------------                        ---------
     model-unavailable                    tool-unusable
       retry                                retry
       use-model                            use-result
           |                                    |
           +------------ agent:recover ---------+
                          the policy
```

`handler-bind`, not `handler-case`: choosing means invoking a restart with the
failed computation still on the stack and able to resume. Unwinding first
destroys the only thing worth having.

Whether a fault is an `error` is a statement about what happens when nobody
handles it, and the two differ: an unreachable model ends the turn, an unusable
tool becomes the tool's result and the run carries on. Making both errors put
`tool-unusable` in reach of every outer `handler-case` for `error` — including
the test suite's — which turned a signal whose point is that execution
continues into a failure.

Declining is a real answer. A policy that always finds something to try is a
loop that never ends: falling back to another model whenever the attempt count
is high enough makes the previous model the fallback, and two dead providers
hand the run back and forth forever. Measured, when written that way: 1001
attempts.

Two conditions and four restarts, not a hierarchy. The shapes have not repeated
yet, and a taxonomy invented before the second real case is a seam with nothing
behind it.

`sb-sys:with-deadline` bounds a whole model exchange, which an HTTP read
timeout does not — it bounds each read, and a connection trickling one byte
every few minutes never trips it. A deadline that fires is just another
unreachable provider, so the same policy retries it.

### Choosing primitives

> Before introducing a new runtime abstraction, ask whether Common Lisp or SBCL
> already provides a stronger primitive whose semantics fit the organism.

```
task-local configuration   dynamic bindings      not dependency plumbing
live capability            COMPILE + funcallable not a plugin loader
recovery                   conditions/restarts   not Result plumbing
coordination               mailbox/gate/thread   not an async framework
evolving object shape      CLOS redefinition     not a migration framework
self-description           Lisp introspection    not a metadata registry
```

The failure mode this guards against is Vivarium becoming a TypeScript
architecture written in parentheses.

## Deferred and suspended operations

The distinction that a previous note got wrong, recorded so it is not got wrong
again:

- **Harness-level** defer, suspend, resume and await are *native Vivarium
  functionality*. Threads, semaphores and mailboxes; the provider does not enter
  into it. Built — see `src/workspace/operation.lisp`.
- **Durable provider-side** jobs mean submitting work, losing the process
  entirely, and later asking whether job 48291 finished. That needs an
  identifier the provider issued and will still honour. **This alone is
  blocked**, and only for providers that offer no such API.

## Conditions and restarts as a runtime feature

Where Vivarium should be better for being Lisp rather than merely written in it.
Not every exceptional state collapses to "caught, returned failed":

```
MODEL-REQUEST-FAILED          SELF-MODIFICATION-FAILED
  retry                         rollback
  use-alternate-model           retry-compilation
  suspend-task                  leave-candidate-inactive
  abort-turn                    abort-task
```

A self-modifying organism especially needs this: a fault must not imply process
death.

## Live continuity is not the same as durability

```
LIVE CONTINUITY     the SBCL process stays running, definitions evolve in place
DURABILITY          important state survives process or machine failure
```

Vivarium wants both. The live image is the organism; the event log, persistent
improvements, provenance and periodic checkpoints are its inheritance and
recovery record. One concrete session store, and **no storage abstraction until
a second real backend exists** — then extract the protocol from two
implementations rather than from imagination.

## The road past Pi

Pi's harness model is now covered independently. What remains is not Pi's.

**Phase 2 — self-modification, task-scoped.** Install a function, use it
immediately. Then prompt, tool vocabulary, procedures, harness definitions. But
no mutation is global by default:

```
search/v1        current default

task-42
   |
   creates search/v2
   |
   activates search/v2 HERE ONLY

works    -> promote      -> future tasks inherit
does not -> discard      -> system stays on v1
```

That separates *self-modify for this task* from *self-modify for the future*.

**Phase 3 — a versioned organism.** Changing live code must not destroy the
previous generation:

```
foo/v1  foo/v2  foo/v3
created | candidate | active-for-task | promoted | retired

Task A -> v2      Task B -> v1      Default -> v1
evaluate, promote, Default -> v2
```

More general than Erlang's old/current generations, keeping the useful idea that
replacing live code need not immediately destroy what it replaced.

**Phase 4 — compositional evolution.** Only once versioning exists. An
improvement becomes a component with id, version, code, state, dependencies,
owned effects, provenance, evaluations and a lifecycle: install, activate,
deactivate, replace, promote, rollback — and eventually remove, unwinding its
owned effects, notifying dependents, reconciling the actual world. This is where
[B12's Cordis findings](cordis-probe.md) become useful, and the reason that
probe measured what it did: Cordis reports a clean unload for a faithful, an
incomplete, an out-of-band and a disguised inverse alike, so only reconciliation
catches all three failures.

## What is built, and what is not

```
BUILT   files, search, shell, skills, templates, memory, extensions with
        decision points, session tree with lanes and branch summaries,
        compaction, resume, records, operations, delegation, three entry points
BUILT   the daemon: sessions as long-lived actors behind a local socket,
        surviving the clients that started them, replayable from sequence 0
BUILT   the control plane: steer, cancel, suspend and resume reaching a turn
        that is still running, cooperatively, at checkpoints, with an exact
        lifecycle model and its invariants adversarially tested
BUILT   identity and ownership: turn ids on every asynchronous message, stale
        messages harmless, one linearized event history, an OS-held daemon lock
BUILT   recovery: restarts at the model and tool boundaries, policy on the
        agent, bounded, with a deadline around the whole exchange
NEXT    phase 1.5 -- compositional agency: TASK as the unit, scoped children
        for sub-agents, detached children for spawned work, a supervisor
        owning topology, task-to-task messaging, isolated conversations
THEN    phase 2 -- versions as function objects, task-local activation through
        a dynamic activation context, subtree inheritance, promotion
THEN    Rust/Ratatui client over the same protocol
THEN    phases 3 and 4 above
```

Phase 1.5 comes first because *task-local* has no referent until tasks exist.
One primitive, not five: a sub-agent is a task with a scoped parent, spawned
work is a task with a detached lifecycle. `Agent`/`SubAgent`/`BackgroundAgent`
as separate runtime concepts would be three names for one thing.

Context isolation is nearly free here and costs Pi a subprocess: separate task
conversations inside one image give isolated cognition over a shared runtime —
same code, tools, registries; different transcripts.

The standard for leaving a layer alone:

> Not *it works*. The architecture has converged, its invariants are explicit,
> adversarial attempts to violate them fail, and there is no evidence for a
> better design.

`improvement.deactivated` and `improvement.reverted` are separate names in the
event vocabulary and must stay separate. Deactivation ends a candidate's
activation for one task or session; reversion moves the promoted lineage back
for everyone. Collapsing them loses the distinction that makes task-scoped
self-modification safe to try.
