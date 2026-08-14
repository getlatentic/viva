# B10 — pre-registration

**Frozen before the first scored run. Nothing here may change once a scored run
has happened**; if something must change, the runs made under the old version are
discarded rather than reinterpreted.

This exists because B10's metrics are partly semantic — "work that only recreates
what was already known" is a judgement unless the instrument makes it a
measurement — and because [B7](smalltalk-probe.md) produced four confident claims
that a better instrument overturned. Each was caught by changing the instrument,
not by running more of the same measurement. Reconstruction tax and
state-authoring tax are both easy to measure badly.

---

## The question, and the stage this covers

Does captured live computation carry information that is expensive or lossy to
externalise as explicit durable state?

Three arms, run in order. **This pre-registration covers the SBCL-only stage,
A1 → A2.** Arm B is not designed here and must not be implemented until A1, A2
and the instrument are frozen and validated — otherwise, once Smalltalk's
behaviour is visible, it becomes very easy to redesign A2 or the metric around it,
which would destroy the cleanest part of the experiment.

| arm | what persists across the checkpoint |
|---|---|
| **A1** | naive reconstruction — goal, history, artifacts, current task |
| **A2** | explicit durable cognition — A1 plus authored reasoning state |
| **B** | captured continuation — stack, frame, locals, process *(not yet)* |

---

## What is frozen

### Tasks

**The 10 train-split tasks only.** The held-out split is fixed and stays unspent:
S1 fixed it before anything was tuned, and B10 must not be the thing that burns it.

| | |
|---|---|
| train (used) | T1, T4, T5, T7, T9, T11, T13, T14, T15, T17 |
| held-out (untouched) | T2, T3, T6, T8, T10, T12, T16 |

Families in the train set: `A-STATE` (T1, T13), `A-LIVE` (T4, T5, T15, T17),
`A-FLIGHT` (T7), `B-CAPABILITY` (T9), `M-CONFLICT` (T11), `CONTROL` (T14).

T14 is the control task — nothing is broken — and is retained deliberately. A
checkpoint on a task with no defect should show **near-zero reconstruction tax in
both arms**. If it does not, the instrument is measuring restart overhead rather
than lost cognition, and the run is invalid.

### Model

`DEEPSEEK_MODEL` via the configured DeepSeek endpoint, **temperature 0**,
`bench-limit` 12 requests, unchanged across arms.

*Assumption, flagged rather than resolved:* a frontier model is used because
`docs/README.md` reserves local models for "high-volume low-stakes roles" and
says arms that decide something get a frontier model — and B10 decides a
substrate question. B3 (cost model) is still open, so the spend is not bounded by
a measured estimate. If the owner would rather cap cost, the substitution to make
is the model, and it must be made **before** the first scored run, not after.

### Checkpoint rule — declared before any trace is seen

> **The checkpoint fires immediately after the 4th tool result is appended to the
> context, before the 5th request is issued. Exactly one checkpoint per run.**

Content-independent and deterministic. It is not "at a natural milestone" and not
"halfway", because both of those are chosen after seeing the trace, and
reconstruction tax varies enormously depending on whether the interruption lands
just after a decision or in the middle of a multi-step investigation. A fixed
ordinal is the least gameable rule available.

4 of 12 leaves 8 requests of runway, so a recovering agent has room to be slower
without simply hitting the cap.

### The paired control — the part that makes the metric a measurement

Not two independent runs compared. **One run to the checkpoint, then a fork into
two arms that share an identical world and an identical prefix.**

```
        one run, turns 1..4
                │
          checkpoint
                │
              fork()                    ← E1: 28-32 ms, full isolation
        ┌───────┴───────┐
   CONTROL          RECOVERY
   continue the     discard the agent's context,
   same context     rebuild it from A1 (or A2),
   uninterrupted    resume against the same image
        └───────┬───────┘
         compare POST-CHECKPOINT behaviour
```

The fork is not an optimisation here, it is the control: both arms inherit the
same live image, the same ledger, the same 4-turn prefix. Any difference after the
checkpoint is attributable to the resume mechanism and to nothing else.

**What the checkpoint destroys is the agent's context, not the image.** That is
the honest analogue of the thing under test: the agent's process dies, the world
it was working on persists, and the question is what resuming costs. Destroying
the image instead would measure something vivarium never does.

### A1 — naive reconstruction

Rebuilt from what the harness already has, with no cooperation from the agent:

- the task prompt (goal)
- the ledger's entries for this run — every definition installed, with previous
  source (artifacts, history)
- a statement that a previous attempt was interrupted

That is all. Notably the ledger already carries what was *done*; A1 tests whether
that is sufficient without what was *thought*.

### A2 — explicit durable cognition

A1, plus a structured record the agent is **required to author each turn**:

```lisp
(:current-subproblem  ...)   (:candidates        ...)
(:current-hypothesis  ...)   (:rejected          ...)   ; with reasons
(:observations        ...)   (:partial-results   ...)
(:next-action         ...)   (:unresolved-branches ...)
(:evaluation-state    ...)
```

Authoring it is not free, and that cost is the point: it is charged as
**state-authoring tax** and counted against A2 on every ordinary turn, not only
on the turn that recovers.

---

## Metrics

**Reconstruction tax** — work performed after recovery whose only purpose is to
recover information, decisions, intermediate results, or execution position
already available immediately before the checkpoint. Measured as the *difference*
between the recovery arm and its paired control, never by classifying operations
by eye:

```
reconstruction_tokens        reconstruction_tool_calls
reconstruction_wall_time     repeated_observations
repeated_experiments         repeated_failed_candidates
lost_hypotheses              wall_clock_delay

Reconstruction Tax Ratio = reconstruction work after restore
                           ─────────────────────────────────
                           total work after restore
```

"The agent re-read file X after restarting" is **not** reconstruction tax on its
own — it may have re-read X anyway. Only the paired difference counts.

**State-authoring tax** — the additional cost A2 pays on every turn to externalise
its cognition: tokens spent authoring state, added latency, and the harness code
that maintains and serialises it.

**Durability tax** — the number that decides the arm:

```
durability tax = state-authoring tax + checkpoint/recovery overhead
                                     + reconstruction tax
    subject to: task score does not regress
```

**The strongest A2 is not the one with the lowest reconstruction tax.** It is the
one minimising total durability tax without hurting score. An A2 that externalises
everything wins on recovery and loses on every ordinary turn; reporting only the
first half would manufacture a result.

---

## Validity checks, which are acceptance criteria and not preliminaries

1. **The instrument detects a tax that exists.** A1 must show a measurable
   reconstruction tax. If A1 shows none, the instrument is not sensitive enough to
   adjudicate anything and no A2 number means anything.
2. **The control task shows near-zero tax in both arms.** T14 has no defect; a
   large tax there means restart overhead is being counted as lost cognition.
3. **Paired runs are genuinely paired.** Same fork, same prefix, same seed, same
   model, same checkpoint ordinal — verified per run, not assumed.
4. **Contamination discards, never marks down.** `attempt.lisp` already detects
   commands reaching for the harness; a contaminated run is dropped from both arms
   of its pair, so a pair is never half-present.
5. **Arm B stays unbuilt** until 1–4 hold and A1/A2 are frozen.

## What would invalidate the whole thing

Choosing checkpoint locations after seeing traces; changing A2's representation
after seeing A2's results; comparing unpaired runs; reporting reconstruction tax
without state-authoring tax; or letting the held-out split into the loop.
