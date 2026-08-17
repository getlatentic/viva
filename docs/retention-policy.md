# The retention policy — Level 3, v1

The mission's gap, measured before built: *promote exists; the policy does
not — the agent must be told.* KC6's three checkpoint firings turned that
line from assumption into data: **90+ task-runs across two framings and an
invitation, and no arm spontaneously invested in any retention mechanism**
(text moved to epsilon under invitation; compile never moved at all). That
null is this policy's baseline. The policy exists when the organism retains
without a human saying so, and it beats the baseline when its investments
are nonzero where investment pays.

## The split: the harness owns WHEN, reflection owns WHAT

```
task turn ends
      -> policy trigger (harness-owned, deterministic)
      -> one bounded reflection turn (model-owned, same conversation)
      -> retention through the EXISTING doors only
         remember          facts and procedures     (text)
         create/promote    reusable transformations (compiled, via the
                           evolution owner's proven table)
```

The organism decides *when* the question is asked; the reflection turn
decides *what* is worth keeping. This mirrors the concurrency law the whole
substrate is built on — owners decide, workers compute — applied one level
up: the policy is an owner of *attention*, never of artifacts. It writes
nothing itself and holds no new authority.

## The laws

1. **Through existing doors only.** Reflection retains via `remember` and
   the capability tools — surfaces that already carry their own proofs,
   guards, and ledgers. The policy adds no writer, no new authority, no
   bypass. A retention the evolution table would refuse is refused.
2. **Bounded.** A reflection turn gets a fixed request budget (default 6)
   added to the agent's limit. It cannot consume the next task's budget and
   cannot run unbounded.
3. **Same conversation, after the work.** Reflection continues the task's
   own context (`:reset nil`), so it sees the actual friction rather than a
   reconstruction — and a cancellation that landed during the work is still
   in force during reflection.
4. **Declining is a valid outcome.** "Nothing to retain" is a success path,
   not a failure. The policy's value is asking the question at the right
   time, not forcing a yes.
5. **Ledgered like everything else.** Capability retention lands in the
   `improvement.*` ledger by construction; text retention lands in
   MEMORY.md. The investment rate is measurable per run with the same
   instrument KC6 already uses (`investment.py`).

## v1's trigger: always-ask, at task end

The simplest policy that can beat a zero baseline: after every completed
task turn, one reflection turn, always. No friction detection, no
thresholds — those are v2 refinements that need v1's data to be designed
honestly (which signals actually precede retention that later pays?).

## The v1 reflection prompt

Names both channels and their division of labor, demands parsimony, and
makes declining explicit. The compliance concern that ruled KC6's arms does
not apply here: an experiment must not instruct the mechanism it measures,
but a policy's whole job is to direct retention.

## Evaluation

- **Baseline**: the KC6 spontaneity null (RESULTS.md) — zero investment in
  90+ uninstructed runs on the same families.
- **Smoke**: one KC6 cell with reflection enabled must show nonzero,
  sensible investment for the cost of one extra bounded turn per task.
- **The real evaluation**: harder families, already filed in the backlog as
  the Level 3 evaluation — spontaneity restored at the trigger level (the
  policy fires mechanically; whether the *model* retains under it is the
  measured quantity), task cost high enough that retention can pay inside
  five tasks.
- **KC6 re-posed**: once the policy exists, the criterion's question
  returns cleanly — arms A and C *both* under the policy, so the comparison
  is compiled-vs-text given retention happens, which is what the kill
  criterion always meant.

## What v1 is not

Not friction detection (v2, needs v1 data). Not auto-extraction without the
model (the reflection turn IS the selector). Not a new authority (law 1).
Not a scheduler — reflection rides the task's own worker and lifecycle.
