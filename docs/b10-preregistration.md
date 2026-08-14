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

### Model, and a spend gate rather than a cheaper model

`DEEPSEEK_MODEL` via the configured DeepSeek endpoint, **temperature 0**,
`bench-limit` 12 requests, unchanged across arms. Frozen.

Temperature 0 is an experimental setting, not a determinism claim — see the noise
floor below. B10 measures a *treatment* effect, so sampling variance is something
to suppress, not to sample.

"B3 is not done" and "use a cheaper model" are different questions, and the second
does not follow from the first. The criterion is whether **B10 itself** has an
acceptable bounded maximum, which does not need B3's full cost model:

```
pessimistic request ceiling for the A1→A2 stage
  20 requests per pair    (4 shared prefix + 8 control + 8 recovery, at the cap)
× 5 pairs per task
× 10 train tasks
× 3 conditions            (sham, A1, A2)
= 3,000 requests, worst case

expected, at S2c's measured mean of 6.7 requests per attempt: ≈ 1,400
```

**The gate, executed before run 1 and not after:** run one *unscored* pilot pair,
read `assistant-message-usage` off the transcript for tokens per request, multiply
by 3,000, price at the account's current rate, compare to budget. Acceptable →
run. Not acceptable → substitute the model **before the first scored run**. A
model substitution after run 1 discards every run made before it.

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

**The ordinal is immutable per run.** When it produces a bad experimental
checkpoint the run is *recorded* as such, never relocated:

```
checkpoint_status = ineligible
reason            = completed_before_checkpoint   ; solved by tool call 3
                  | terminal_at_checkpoint        ; nothing cognitively left
```

Moving to "tool result #3 instead, just for this task" would reintroduce exactly
the researcher discretion the fixed ordinal exists to remove. If too many train
tasks turn out ineligible at ordinal 4, **the global rule changes and every task
moves with it, before scored execution** — never one task at a time.

### Repeats and the noise floor — S2c already measured this and it is not small

S2c re-measured all 17 tasks and found that **two identical sweeps disagreed on 6
of 25 cells — 24% — at temperature 0 with a fixed seed.** Hosted providers are not
deterministic. Its conclusion is binding here: *a single sample per cell cannot
support a comparison*, and `attempt-repeatedly` / `fraction-summary` exist for
exactly this.

So: **5 pairs per task per condition, and spread is reported, never a bare mean.**
The arms are not deterministic and must not be described as such — the fork fixes
the *prefix* exactly, and temperature 0 reduces post-fork divergence, but neither
eliminates it.

This changes what the sham test is for. It is not a checkbox expected to read
zero; it is **the measurement of the noise floor**, and a reconstruction tax that
does not exceed that floor is not a finding.

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

**A1 is exactly vivarium's existing ledger recovery semantics, and must not move
in either direction during implementation.** Not weakened into a strawman, and —
the likelier failure — not quietly enriched because B10 turns out to want some
field. The moment a field is added for B10's benefit, A1 stops being the baseline
(*what the project has today*) and becomes a B10-specific reconstruction, at which
point the A1 → A2 delta measures nothing. Deliberate externalisation belongs in
A2, which is what A2 is for.

```
A1  =  current vivarium recovery semantics        (fixed)
A2  =  A1 + authored cognition                    (the treatment)
```

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

## The validity ladder — acceptance criteria, not preliminaries

Each rung tests one thing, and each must clear before the next is trusted.

| rung | comparison | expected |
|---|---|---|
| **sham** | continue vs **continue** — fork twice, neither arm destroys context | Δ ≈ 0, and whatever is left **is the noise floor** |
| **T14** | continue vs recovery on a task with nothing broken | ≈ zero reconstruction tax |
| **A1** | continue vs naive recovery | a tax that **exceeds the sham floor** |
| **A2** | continue vs explicit-state recovery | that tax reduced, without raising durability tax |

The **sham** is the rung that was missing and it is the most important one. It
forks at the checkpoint and lets *both* branches continue uninterrupted, so it
tests whether forking and branch execution alone manufacture the apparent
treatment effect. Given S2c's measured 24% cell disagreement, it will not read
zero — and that is its value: **it establishes the floor every treatment effect
must clear to count as one.** A reconstruction tax inside the sham band is noise
with a story attached.

T14 remains, but as one rung rather than the whole check: it can only tell you
whether the instrument manufactures tax in a trivially easy condition.

Also holding throughout:

- **Paired runs are genuinely paired.** Same fork, same prefix, same model, same
  checkpoint ordinal — verified per run, not assumed.
- **Contamination discards, never marks down.** `attempt.lisp` already detects
  commands reaching for the harness; a contaminated run drops *both* arms of its
  pair, so a pair is never half-present.
- **Arm B stays unbuilt** until the sham, T14, A1 and A2 all behave as
  pre-registered. Not until A1 and A2 have *numbers* — until they behave.

## What would invalidate the whole thing

Choosing checkpoint locations after seeing traces; changing A2's representation
after seeing A2's results; comparing unpaired runs; reporting reconstruction tax
without state-authoring tax; or letting the held-out split into the loop.
