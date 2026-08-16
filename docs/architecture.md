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

Law 11 has a linearization point: sequence number, stored event, subscriber
delivery and any replay all happen in one critical section, so a client sees an
unbroken run of sequence numbers with nothing lost, repeated or reordered. That
is only affordable because **a subscriber handler must not block** — it enqueues
onto the client's outbound mailbox and returns, and one writer thread per client
owns the socket. Writing from the handler put frontend I/O inside execution
latency: a terminal that stopped reading stopped the turn that was publishing
to it.

Laws 3 and 4 apply to **cleanup**, which is where they are easiest to forget. A
teardown that clears globals unconditionally is a stale message with a different
shape: a stopped daemon's accept loop unwound into code that closed `*socket*`
and deleted `*socket-file*`, and by then those described the *next* daemon. It
retired its successor. Cleanup must name what it is cleaning up.

```
    stop this listener       (eq socket *socket*)  ->  teardown
    stop whatever is current                       ->  teardown
```

Descriptors are the other place identity hides. A failed write to a peer that
has hung up leaves bytes in an SBCL fd-stream, and those bytes reach whoever
holds that descriptor number next — measured as greetings arriving with the
front of a previous greeting in front of them, and never once when the same
clients read their greeting before hanging up. The daemon's output path
therefore has no stream buffer at all: serialise, send the octets, done.

And the close is a **completion protocol, not a timing decision**. The writer
signals a semaphore when it will never touch the socket again; the reader —
the connection's one lifecycle owner — closes only after that confirmation.
Both shortcuts were tried and both failed measurably: a timed join let the
close land mid-send (EBADF on a recycled descriptor number), and an untimed
one waited an hour and fifty minutes on a writer nothing was going to finish.
If confirmation never comes, the descriptor is deliberately leaked and loudly
counted — a leaked fd is a bounded cost; a corrupted stranger's connection is
not. `socket-close` closes the stream `socket-make-stream` cached, so "the
writer closes its socket" was cross-thread stream closure wearing
single-ownership's clothes.

### The journal: one owner, acknowledged writes

```
cells --(:append)--> JOURNAL OWNER --> one JSONL file per session
                          |
                   commits the watermark
```

One owner thread for the whole image — twenty sessions must not mean twenty
threads fsyncing twenty files. The in-memory tail is a **ring** of the last
4096 events (the list version copied 4096 elements under the cell lock per
streamed delta), and an event may leave memory only once the owner has
**acknowledged** it on disk: evicting first opened a window where a fast
producer and a slow disk left an event in neither place. Replay composes disk
`(seq, committed]` with ring `(committed, now]`; committed only grows, so the
two halves meet without a gap however far the ring moves during the read.

Failure is a state, not a silence. A journal that cannot write reports through
the coordinator as `session.error` and the session continues **explicitly
non-durable**; a ring forced to overwrite an uncommitted event declares the
same. Session close is a confirmed flush — the owner signals after everything
queued ahead, so a completed session's history is provably on disk or the gap
is printed. `*journal-root*` is configuration; tests point it at a temp
directory, having once written 26MB into the real home.

### The daemon is a generation

`daemon-instance` carries socket, path and OS-lock fd as one identity.
Nothing global is assigned until the whole instance is published in a single
locked transition, and `stop` during startup cancels the claim — so there is
no window where a stop reports success while a half-started daemon proceeds to
bind behind it. The accept loop and sweeper each check *their* generation is
still current, never "is any daemon up": the sweeper that looped on a bare
global left one sweeper per cycled daemon behind, a hundred and twenty of them
after one test.

### The kernel: the decision layer as one checked object

The cell lifecycle is a pure function in `src/daemon/kernel.lisp`:

```
    transition : State x Message -> State x Effects
```

written once as a `define-owner` table, executed by the coordinator, mirrored
action for action by `spec/CellLifecycle.tla`, and replayed by a self-test
whose traces are this project's actual past incidents -- the stale completion,
the resume resurrection, the flush-retained shutdown. The coordinator's
`handle` is mechanical: translate the mailbox message into the kernel
alphabet, call `cell-transition`, perform the returned effects. A state and
message the table does not know SIGNALS `unmatched-transition`, and policy
turns that into a published diagnostic: a lifecycle hole is a condition,
never a silence, never an improvisation.

What this bought on integration day: walking the runtime's real message set
against the delivered table found the table and the spec DISAGREEING about
resume-with-queued-prompts -- the table resumed into a working state with
nobody working, the spec resumed to idle with the queue stranded, both wrong,
each plausible alone. One object to check is the point.

The queue policy is uniform now: the journal has its high-water mark, the
prompt queue refuses past `+queue-limit+` with the refused turn named, and a
subscriber more than `+subscriber-capacity+` events behind is dropped with
the drop announced on the stream. An unbounded mailbox is not a complete
concurrency design; every boundary declares its capacity and its overload
action in the kernel's constants.

Phase 1.5 entered through this object, as the rule required. The task tree
was specified first — `spec/TaskTree.tla`, five invariants plus
terminal-is-forever over the full space, liveness over the complete smaller
one, and two witness configs whose *violations* are the demonstration: TLC
exhibits a detached child alive past its parent's terminal state, and alive
and uncancelled past its parent's cancellation — then mirrored clause for
clause as `define-owner tasktree`, and only then did the supervisor learn the
verbs. One supervisor owns the tree as its single writer; workers are
sub-agents of the owning session's agent — shared world, isolated
conversation, their own lane — reporting through the supervisor's mailbox
with the identity of the task they finished; tasks publish through the
session that owns their root, so watching a session is watching its tasks.

The tree's own laws, each adversarially broken and caught: a parent's outcome
PARKS in `:draining` until its last scoped child resolves — the same
lie-prevention `:flushing` does one level down; cancel is a request that
propagates one delivery at a time across scoped edges only, so a detached
child survives its parent's cancellation by construction; identities are
minted monotonically by the owner and never reused, which makes a late
completion for a finished task decidable forever; fan-out past
`+child-limit+` is refused with the parent named, and a refused spawn answers
its caller `NIL` rather than a timeout.

### The safety boundary, stated exactly

Three layers hold, and the discipline is to never claim one layer more:

```
PROVEN      no interleaving of the modeled alphabet violates a frozen
            invariant -- TLC, complete state spaces, witnesses proving the
            invariants violable rather than vacuous
PINNED      the Lisp tables cannot drift from the specs (one object), and
            the coordinators cannot drift from the tables (each attack
            breaks exactly one law and is caught by exactly its guard)
CONTAINED   mailboxes, threads, locks and wiring: 1,000+ tests, attack
            batches, churn plateaus -- evidence, not proof, and where every
            integration bug so far has actually lived
```

Beneath everything sit SBCL, the OS and the filesystem, where conditions and
restarts give recovery, never correctness. Each phase extends the guarantee
only by entering through the proof first.

Phase 2's door is open: `spec/Evolution.tla` (safety over the complete space,
liveness, and a witness whose violation demonstrates the isolation law) with
`src/daemon/evolution.lisp` as its `define-owner` mirror. The lifecycle laws:
at most one promoted version per component and it is the lineage's last;
promotion and reversion serialized through the one owner; a task's activation
is a pin invisible outside that task -- an unpromoted candidate reaches a
resolution only through the resolving task's own pin; deactivation is bounded
by task lifetime and moves no lineage; REVERTED moves the lineage back for
everyone and touches no pin. The guarantee is about the evolution LIFECYCLE;
what an evolved function does is validated and capability-bounded, never
proven. Wiring comes next and not before.

Hardening item one, unchanged: the journal owner's table is conformance-only
-- the one authority whose decision layer is not yet the checked object, and
the drift pattern that already bit once.

### The closure gate, and the stopping rule

Phase 1 closed with a frozen list of four defects -- the replay gap under
concurrent publication, journal-owner truth by `thread-alive-p`, deregistration
before durability, unprotected startup acquisition -- plus a fifth found while
testing the first: the journal's own mailbox was the last unbounded queue, and
a flat-out publisher exhausted the heap through it. Each got a deterministic
reproduction, a fix, and an attack showing the reproduction fails without it.

**The stopping rule, adopted so the loop terminates:** after this gate, a newly
imagined race is NOT a Phase 1 blocker. It becomes one only when at least one
holds:

```
it has a concrete reproduction
it violates a frozen invariant by direct code analysis
it appears in the soak, diagnostics, or real operation
the next phase depends directly on the unsafe path
```

Everything else goes to the hardening backlog. `Fixed` never meant `no
concurrency bug can exist` -- it means the ownership rules are explicit, known
violations reproduce and fail fixed, resources plateau under churn, failures
are contained and visible, and no known reproduced defect contradicts a core
invariant. The kernel seeks exactness; the organism seeks resilience; neither
substitutes for the other.

### Phase 1.5 thread discipline, decided now

A task is an **ownership domain, not a thread entitlement**. Sessions already
share one journal owner; task trees share bounded resources the same way:
a maximum active-task count, a maximum scoped-child depth, excess tasks
queued, topology changes serialized through the supervisor. SBCL threads are
native OS threads, not BEAM processes — twenty tasks must not mean sixty
permanent threads.

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
BUILT   client I/O isolated behind outbound mailboxes, absolute shutdown
        deadlines, startup owned by process state as well as an OS lock
BUILT   acknowledged journal, generation-scoped daemon, sealed actor API
SOAKED  614,048 session lifecycles over three hours: heap 64->65MB,
        threads 4->4, descriptors 14->14, journal queue never above zero,
        16,850 hostile disconnects contained and counted (docs/soak-*.log)
GATED   replay barrier exact under concurrent publication; journal owner a
        supervised generation that restarts and heals; deregistration follows
        confirmed durability; startup acquisition unwind-protected; the
        journal queue bounded by a high-water mark
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
