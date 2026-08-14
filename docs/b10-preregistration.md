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

**`openai/gpt-oss-120b` via OpenRouter**, temperature 0, unchanged across arms.
Frozen.

Temperature 0 is an experimental setting, not a determinism claim — see the noise
floor below. B10 measures a *treatment* effect, so sampling variance is something
to suppress, not to sample.

Three reasons this is the right model rather than a cheaper substitute for a
better one:

1. **B3 already settled the cost question and I had it backwards.** Its note reads
   "OpenRouter's gpt-oss-120b is cheap enough to ignore; DeepSeek is not, for a
   full sweep." The spend gate below was built to bound the wrong model.
2. **It is one of S2c's two calibration models**, so B10 inherits a measured
   per-task baseline over all 17 tasks rather than starting blind — including what
   "score does not regress" means numerically, per task.
3. **The repo's own rule points here.** `docs/README.md` reserves frontier models
   for arms that decide something and says a model *held constant across arms* is
   fine for "does harness B beat harness A". B10's comparison is A1 against A2,
   both on SBCL, model held constant — that is squarely the second case. Reading
   B10 as "decides a substrate question" and reaching for a frontier model
   confused the *stakes* of the conclusion with the *shape* of the comparison.

**Measured train-split baseline (gpt-oss-120b, S2c).** Any A1 or A2 run whose score
falls materially below its task's cell here is a regression, not a result:

| T1 | T4 | T5 | T7 | T9 | T11 | T13 | T14 | T15 | T17 |
|---|---|---|---|---|---|---|---|---|---|
| 1.00 | 1.00 | 0.94 | 0.83 | 1.00 | 1.00 | 1.00 | 1.00 | 0.67 | 1.00 |

Fallback if cost ever does bite: `gpt-oss-20b` on the local llama-server, which
additionally offers real seed control. Not chosen now, because it has no S2c
baseline and a 20B model risks floor effects on T15 and T7.

The spend arithmetic below is retained because staging is still right, but it is
now a sanity check rather than a gate:

**Fork three ways, and make the third branch do work.** An earlier version had the
sham as `CONTROL vs CONTROL'` — continue twice — which measures fork and sampling
noise but *not* the cost of restarting. That conflates two different things inside
a single delta. The sham should exercise the restart machinery while **retaining**
cognition:

```
                identical, quiescent turn-4 state
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              C               S               A1
           CONTROL          SHAM           RECOVERY
              │               │               │
        keep context    restart the      destroy context,
        and continue    machinery, but   rebuild from the
                        keep cognition   ledger, resume
```

which decomposes the effect into three quantities instead of one ambiguous delta:

```
restart / plumbing cost  =  S − C
reconstruction tax       =  A1 − S      ← the quantity B10 exists to measure
total recovery effect    =  A1 − C
```

**If A1 is slower than control but indistinguishable from the sham, the
measurement was of restart machinery and not of lost cognition.** That is the
failure the two-way version could not have detected. For A2 later, substitute A2
for A1 and retain both C and S.

All three come off the *same* prefix, so the floor is measured on exactly the runs
it calibrates, on every pair rather than on a handful of separate ones.

A2 cannot share A1's prefix — the agent authors state from turn 1, so A2's whole
run differs, which is the state-authoring tax. It forks two ways.

```
STAGE 1   A1 + sham, three-way fork
          4 prefix + 2.7 × 3 branches ≈ 12 requests/pair   × 5 pairs × 10 tasks
          ≈ 605 expected          (1,400 at the 12-request cap)

STAGE 2   A2, two-way fork — AUTHORISED ONLY IF STAGE 1 CLEARS THE LADDER
          4 prefix + 2.7 × 2 branches ≈ 9.4 requests/pair  × 5 pairs × 10 tasks
          ≈ 470 expected            (1,000 at the cap)
```

Expected figures use S2c's measured mean of 6.7 requests per attempt over 102
attempts, which also recorded that "models stop well short of the request budget
rather than exhausting it" — so the cap is a bound, not a forecast.

**Spend is staged, not authorised up front.** If stage 1 shows no A1 tax above the
sham floor, A2 is pointless and stage 2 is never bought. Only stage 1 is
authorised now.

Still run the *unscored* pilot pair and read `assistant-message-usage` off the
transcript before run 1 — not to authorise the spend, which B3 already did, but
because it is the cheapest possible check that the harness produces a usable
transcript at all.

**The eligibility probe.** S2c persisted only its aggregate table, not its
trajectories, so the turn-count distribution has to be measured rather than
recovered. One *unscored* pass over the 10 train tasks, recording turns to
completion and `assistant-message-usage`, feeds the formula above and doubles as
the transcript sanity check. Unscored and content-blind: it reads lengths and
token counts, never what the agent did.

The per-branch budget is 8 post-checkpoint requests, well above the ~2.7 typically
used, so a recovery arm that needs longer is measured rather than censored by the
cap.

### Checkpoint rule — declared before any trace is seen

> **The checkpoint fires immediately after the Nth assistant turn completes —
> when `bench-requests` reaches N — before the (N+1)th request is issued.
> Exactly one checkpoint per run.**

**Corrected before any run, from "the 4th tool result" to a turn ordinal.**
`execute-batch` runs every tool call in a turn, so one request can produce several
tool results: "the 4th tool result" lands inside request 1 or 2 when the model
batches and inside request 4 when it does not. That makes the checkpoint position
a function of the model's batching behaviour — precisely the content-dependence a
fixed ordinal exists to remove — and it is not comparable to S2c's mean of 6.7,
which counts requests. A turn ordinal fires at `should-stop-after-turn`, an
existing hook, and is counted by an existing counter.

Content-independent and mechanically enforceable. It is not "at a natural
milestone" and not "halfway", because both are chosen after seeing the trace, and
reconstruction tax varies enormously depending on whether the interruption lands
just after a decision or mid-investigation.

**N is set by a formula declared here, before the probe that feeds it runs:**

```
N = clamp(floor(median turns to completion / 2), 2, 4)
```

measured over one unscored pass of the 10 train tasks. The formula fixes the
choice in advance; the probe only supplies the number. Choosing N after inspecting
run *lengths* is legitimate — choosing it after inspecting run *content* is not,
and this cannot do the latter because content is never consulted.

Why a formula rather than the flat 4 first written: S2c measured a mean of 6.7
turns, so an ordinal of 4 leaves ~2.7 turns of typical work — thin runway, and a
high `completed_before_checkpoint` rate on the tasks gpt-oss-120b solves at 1.00.
The midpoint balances "enough cognition accumulated to lose" against "enough
runway left to observe the loss".

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

### The checkpoint is a quiescent boundary, not a counter reaching 4

`should-stop-after-turn` firing is necessary but not sufficient. The fork happens
only when all of this holds:

```
model request 4 returns
        ↓
every batched tool call completes          ← execute-batch runs them in parallel
        ↓
every tool result is appended to context
        ↓
every side effect is committed
        ↓
the ledger is flushed
        ↓
no request 5 has started
        ↓
                    FORK HERE
```

> **Invariant: at the checkpoint there are no in-flight tools, no partially
> committed ledger operations, no model request in progress, and no shared
> external connection state.**

The fourth clause was added after the first stage-1 run returned 90 memory faults
and zero usable branches. Dexador pools connections, so the parent held live TLS
sockets that satisfied all three original clauses — the request had finished and
the socket was parked for reuse — and three children using the same descriptors
faulted inside the TLS layer. The pool is cleared in the *parent* before forking
rather than in each child: a child closing an inherited socket sends a FIN on a
connection the parent still believes it owns.

Without it B10 measures replay and transaction semantics rather than cognition
loss — forking mid-batch would hand one child a half-applied world, and the
resulting delta would be a fact about the harness's crash-consistency.

### The paired control — the part that makes the metric a measurement

Not two independent runs compared. **One run to the checkpoint, then a fork into
arms that share an identical world and an identical prefix.**

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

**A2's control branch has already paid it before the fork.** By turn 4 an A2 run
has been externalising hypotheses, rejected candidates and next actions for four
turns, so its prefix costs more than A1's prefix does. Comparing only
`A1 recovery` against `A2 recovery` and concluding A2 wins because it resumes
cheaply would ignore the four turns it already spent buying that. The comparison
must be:

```
total durability tax = pre-checkpoint state-authoring tax
                     + checkpoint / restart cost
                     + post-checkpoint reconstruction tax
```

which is why A2 is measured against its *own* C and S, and why the prefix token
count is recorded per arm rather than assumed shared.

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

| rung | quantity | expected |
|---|---|---|
| **sham** | `S − C` — restart machinery exercised, cognition retained | small; whatever it is **is the plumbing cost**, and it is not cognition loss |
| **A1** | `A1 − S` — the same restart, cognition destroyed | a tax that **exceeds `S − C`**, or B10 measured plumbing |
| **total** | `A1 − C` | should reconcile: `(S−C) + (A1−S)` |
| **A2** | `A2 − S` | that tax reduced, without raising total durability tax |

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

---

## Pre-run probe result (2026-08-11) — and the problem it found

`experiments/b10-eligibility.lisp`, gpt-oss-120b, one unscored attempt per train
task, content-blind:

| task | T1 | T4 | T5 | T7 | T9 | T11 | T13 | T14 | T15 | T17 |
|---|---|---|---|---|---|---|---|---|---|---|
| **turns** | 5 | 5 | **2** | 5 | 4 | **10** | **2** | 4 | 4 | 5 |

```
median 4.5  →  N = clamp(floor(4.5 / 2), 2, 4) = 2
tokens 38,100 over 10 attempts = 3,810 per attempt, 828 per turn
ineligible at N=2 (complete in ≤ 2 turns): T5, T13
```

**Cost is confirmed a non-issue.** Stage 1's ~605 requests at 828 tokens/turn is
roughly 500k tokens. B3's "cheap enough to ignore" holds, measured rather than
assumed, and the spend gate can be retired.

**But the formula returned N = 2, and that is not a tuning problem.** Two things
the probe establishes that the design assumed otherwise:

1. **Runs are much shorter than S2c's 6.7.** Median 4.5, mean 4.6 on the train
   split. S2c's figure spans all 17 tasks and both models; the harder held-out
   tasks were carrying it.
2. **At 4–5 turns there is very little in-flight cognition to lose.** A checkpoint
   at turn 2 leaves the agent barely started, so a near-floor reconstruction tax
   would be an artefact of run length rather than evidence that explicit state is
   sufficient. Checkpointing at 3 leaves ~1.5 turns of runway instead.

**This is a validity threat, not a parameter.** The task set was built for S1 —
can a harness let an agent repair a live image — and short decisive runs are a
*virtue* there. B10 asks what interrupting an agent mid-thought costs, which needs
runs with enough accumulated state to lose. Those are different requirements and
the set was optimised for the first.

Note where the long runs are: T11 at 10 turns is the only train task with real
depth, and the set's hardest task by S2c's own measurement is **T12 — three
independent defects, neither model reliably fixing all three — which is in the
held-out split and must stay unspent.** The tasks best suited to B10 are largely
the ones B10 is not allowed to touch.

**Resolved by commissioning family D** — three train-split tasks built so that a
run accumulates in-flight state before any plausible checkpoint. See the second
probe below.

## AMENDMENT 1 (2026-08-11) — population changed before any treatment data

Recorded as an amendment rather than folded in silently. The first probe
established, *before any scored fork*, that the original train split could not
identify the effect B10 exists to measure: 4.5-turn runs leave nothing in flight
to lose. Changing the design at that point is what a pre-registration is for; the
thing it forbids is changing it after seeing treatment results, and there are
none.

What changed: the population is family D (T18–T20), not the whole train split.
What did not change: the formula, the clamp, the metrics, the paired design.

**Statistical consequence, and it is a real cost.** T18–T20 were *constructed for
depth* and then *observed* to run 9/12/12 turns. That makes them
instrument-development tasks, not pristine confirmation tasks — they can
establish whether the instrument can see reconstruction tax at all, and they
cannot carry the confirmatory claim on their own, because their depth was
selected for.

```
T18–T20   develop and validate the instrument; establish A1 → A2 behaviour
T21       held out; confirmation of direction
```

That makes **T21 more important than it looked when it was added as a census
formality.** One held-out task is thin for a general claim, but it is enough to
stop B10's first result being circular. If B10 eventually makes a strong general
claim, *that* is when independent depth tasks get built — not now, because
building them now with the effect unknown risks selecting for it.

## Second probe (2026-08-11), after family D was added

| task | T1 | T4 | T5 | T7 | T9 | T11 | T13 | T14 | T15 | T17 | **T18** | **T19** | **T20** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **turns** | 4 | 5 | 2 | 5 | 4 | 7 | 2 | 3 | 8 | 5 | **9** | **12** | **12** |

```
73,844 tokens over 13 attempts = 5,680 per attempt, 947 per turn
```

The depth tasks do what they were built to do: 9, 12 and 12 turns against 2–8 for
the originals. **But the formula's answer depends on which population it is
applied to**, and after the scope change there are two candidates:

```
whole train split (13 tasks)   median 5    →  N = clamp(floor(5/2),  2, 4) = 2
family D only     (3 tasks)    median 12   →  N = clamp(floor(12/2), 2, 4) = 4
```

Ten short tasks outvote three long ones, so the whole-split median says almost
nothing about the runs B10 would actually interrupt.

**B10's population is family D, and N = 4.** This is not the formula being
re-chosen after seeing its output — the population was decided when the depth
tasks were commissioned, *before* this probe ran, precisely because the first
probe established the original tasks are too short to interrupt meaningfully.
Running B10 on tasks already known to be unsuitable would contradict that
decision. The formula is unchanged and is applied to the population B10 uses.

Two things recorded rather than fixed:

- **The clamp's upper bound is now binding.** `[2, 4]` was chosen when runs were
  assumed to be ~6.7 turns, where 4 is roughly the midpoint. On a 12-turn run the
  unclamped value would be 6, and 4 is a third of the way in rather than half.
  The clamp stays because it was declared in advance; that it now binds is a fact
  about the range, not a licence to widen it.
- **Three tasks is thin.** Mitigated by 5 pairs each — 15 pairs, and the sham
  rides on every one — and by T21, held out, for confirming anything found.
