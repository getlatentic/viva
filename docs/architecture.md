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
        that is still running, cooperatively, at checkpoints
NEXT    phase 2 -- candidate versions, task-local activation, promotion
THEN    Rust/Ratatui client over the same protocol
THEN    phases 3 and 4 above
```

`improvement.deactivated` and `improvement.reverted` are separate names in the
event vocabulary and must stay separate. Deactivation ends a candidate's
activation for one task or session; reversion moves the promoted lineage back
for everyone. Collapsing them loses the distinction that makes task-scoped
self-modification safe to try.
