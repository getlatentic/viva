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

## Concurrency: a mailbox per session

```
                    runtime
                       |
          +------------+------------+
          |            |            |
      session A    session B    session C
       mailbox      mailbox      mailbox
          |            |            |
          +------- worker pool -----+
                       |
                model / tools / IO
```

`sb-concurrency:mailbox` is a blocking queue over SBCL's lock-free queue — the
natural primitive here. A slight Erlang flavour without pretending Common Lisp
is Erlang.

Messages a session accepts: `:user-message` `:model-completed` `:tool-completed`
`:cancel` `:suspend` `:resume` `:steer`.

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
NEXT    the daemon: sessions as long-lived actors behind a local socket
THEN    Rust/Ratatui client over the same protocol
THEN    phases 2, 3, 4 above
```
