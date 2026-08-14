# B14 — pre-registration

**Frozen before the first gate runs.** Same discipline as
[B10](b10-preregistration.md) and [B11](b11-preregistration.md): the numbers that
decide the outcome are written down before any of them is observed.

B14 builds an instrument, so what it can get wrong is different from what an
experiment can get wrong. An experiment reports a false effect. **An instrument
manufactures one and then reports it forever.**

## B14.0 is frozen

[`src/image/inspect.lisp`](../src/image/inspect.lisp) is measurement apparatus,
not a convenience. It is closed to additions for the duration of B14.

The reason is the silent-truncation defect found while exercising it: a `step` of
`"1 status"` descended once and dropped the rest, so a request for two things
returned one and said nothing. **If the primitive quietly does more work than its
contract claims, every estimate of what abstraction is worth becomes invalid** —
the baseline looks cheaper than it is, and the oracle's compression looks smaller
than it is.

No convenience additions once B14.1 begins. A gate that fails is a result about
the sequence, not a request to strengthen the tool.

## The two harness regimes, kept apart

```
B14         restricted inspection  ->  repeated observation has real cost
                                   ->  a persistent abstraction may pay

E5          arbitrary eval         ->  one-shot programs collapse that cost
                                   ->  the improvement target must instead be
                                       something needing persistence over time
```

These are different hypotheses about what the base harness should be. B14 does
not settle E5 and must not be read as having done so. **If E5 later wins, B14 is
not retroactively wrong** — it measured self-improvement under a restricted-tool
regime, and E5 would have established that vivarium's optimal base harness
removes that particular opportunity. Both are results.

## Three gates, sequential and hard

A gate that fails stops the story. It does not get relaxed.

### Gate 1 — sufficiency

CONTROL solves representative repairs with `read_definition`,
`find_definitions`, `inspect_value`, `install`, `rollback`, `bash` and **no
oracle capability**.

The criterion is *not* efficiency. It is that the required information is
observable and the repair achievable. A task CONTROL cannot solve is discarded,
because a capability that turns impossible into possible manufactures the result
rather than measuring it.

### Gate 2 — inconvenience

The most important gate, and raw call count is the wrong measure of it. Five
inspections inside one model request may cost less than three that each need
their own reasoning cycle. **The bottleneck under test is investigative
interaction, not API calls.**

```
OBSERVATION BURDEN  =  inspect_value calls
                    +  investigation-only requests
```

where an **investigation-only request** is one whose tool calls are all read-only
— `inspect_value`, `read_definition`, `find_definitions`, `bash` — and which
installs or rolls back nothing. It is a turn spent finding out rather than
changing.

**Frozen threshold: median observation burden ≥ 6 across solved CONTROL
attempts, at a solve rate ≥ 0.6.**

Six because the sequence's premise is that impact discovery spans several
distinct live locations — the definition, its callers, the instances, the values
those produced — and a median of 1–2 would mean the evidence sits in one place
and there is nothing to abstract. Frozen now, before any oracle result exists.

### Both numbers are reported, and neither substitutes for the other

A median computed over successes alone is survivorship-biased, and **an unsolved
attempt is never recorded as burden 0** — it is not a cheap solve, it is not a
solve. So two figures, always together:

```
solve rate                 correct repairs / attempts
observation burden | solved   median over the correct ones only
```

**Frozen: `solved` means every case passes.** Partial credit is not a solve, so
that this cannot be argued about after the numbers exist.

**Frozen: solve rate ≥ 0.6** — a correct repair in at least 3 of 5 repeats. Below
that, the median is computed over a minority of lucky runs and the *possible* leg
of the shape has not been established at all.

The two together are what distinguish the wanted shape from the failure that
looks like it:

```
wanted    possible + repetitive + expensive
failure   expensive because the agent is lost
```

High burden at a low solve rate is confusion, not a reusable bottleneck. It fails
Gate 1 before Gate 2 gets to see it.

### Gate 3 — compression ceiling

Hand-written `impact_map` consumes **the same observable information at a better
abstraction level**. This is a constraint on the oracle, not a note:

```
CONTROL   ask A, ask B, ask C, correlate
ORACLE    impact_map -> A, B and C already correlated

FORBIDDEN ORACLE   privileged runtime facts CONTROL could never retrieve
```

Required, all of them:

| | frozen requirement |
|---|---|
| score | `score_oracle ≥ score_control` — not worse |
| burden | median observation burden **≥ 40% lower** |
| cost | requests **or** tokens materially lower, same direction |
| transfer | the held-out sequence preserves the gain, sign-consistent |

**If Gate 3 fails, B15 does not run.** There would be no known improvement for
the agent to discover, and any arm that appeared to improve would be measuring
something else.

## Two separate accounts: the ceiling, and the economics

Keeping these apart is what stops B14 from handing B15 an unrealistically cheap
estimate of self-improvement.

**B14 measures a ceiling only.** The hand-written `impact_map` establishes what
recurring gain is *available*:

```
available reusable gain  =  CONTROL recurring cost  -  ORACLE recurring cost
```

**The human authoring cost of `impact_map` does not enter this, and does not
enter B15's economics either.** An engineer writing the oracle with full
knowledge of the sequence is not a model of an agent discovering it, and charging
the agent that price — or crediting it that discount — would measure neither.

**B15 measures the economics, with the agent's own costs.** What a self-improving
agent actually pays:

```
agent improvement cost  =  reasoning that notices the pattern
                        +  tool or skill design
                        +  implementation
                        +  testing and evaluation
                        +  adoption

BREAK-EVEN EPISODE      =  ceil( agent improvement cost
                                 / recurring per-episode saving )
```

Per capability, recorded: agent improvement cost, adoption cost measured from the
arm's own mechanism, per-episode savings, break-even episode, total sequence
gain, held-out gain.

A capability costing the agent 8,000 tokens and saving 1,500 per episode breaks
even at episode 6. **That is the quantity longitudinal self-improvement is
actually about**, and it is what gives HYBRID a concrete reason to exist rather
than an attractive-sounding one:

```
LIVE          creation 8k   adoption ~immediate   benefit starts THIS episode
EXTERNALISED  creation 8k   artifact cost small   benefit starts NEXT episode
HYBRID        creation 8k   both                  benefit this episode AND
                                                  inherited by the next
```

Each arm's adoption cost is measured **from the mechanism it actually uses**.
B11's +2,989 priced restart-and-reconstruct-context and is not this arm's price
tag.

## Reading order, frozen before the run

**Do not inspect individual trajectories before reading the aggregate verdict**,
unless the run failed operationally. Reading them first makes it far too easy to
explain a median of 4 away — *the model found a clever shortcut on these three
runs* — and **a shortcut is evidence that the task failed the gate**, not an
excuse for the number.

```
1. operational validity   all intended runs completed, no contamination,
                          no tool failures
2. Gate 1                 solve rate
3. Gate 2                 the frozen verdict, as returned
4. only then              trajectories, to understand WHY it passed or failed
```

### What a pass does and does not license

A solve rate of 0.9 at a median burden of 8 establishes exactly one thing:

> E24 contains a reliably solvable repeated observational burden.

It does **not** establish that `impact_map` is useful. That is Gate 3's job, and
Gate 3 can still fail on a task that passed Gate 2 — nine observations that do
not compress into a reusable abstraction are nine observations, not a ceiling.

## Amendment 1 — the baseline did not know what it could do

**First Gate 1 run: 0 of 5 solved. Retained, not discarded.** Operationally
clean — 5 completed, 0 errored, 0 contaminated — so it is a result about the
baseline rather than a broken measurement.

Every attempt scored exactly 0.6667, which is precisely the **no-repair** score
measured before the run. The world was left unchanged five times. The tool calls
say why:

```
inspect_value calls per attempt   0, 0, 1, 0, 1
recurring shape                   find_definitions -> read_definition -> install
attempt 1                         eleven consecutive installs, hit the cap
```

`inspect_value` had been added to the tool set while `*system-prompt*` still
described a world of reading source and installing replacements. **Stated as
narrowly as it was measured:**

> On E24, exposing `inspect_value` in the tool set was insufficient to make the
> agent use live-state evidence while the system prompt continued to frame the
> task as source repair.

Not the broad claim that registering a tool never confers a capability.

**This is a baseline defect, not the effect B14 is trying to measure.** CONTROL
must understand the capabilities it starts with, so the generic prompt gains one
paragraph describing the execution model — that source and live state are both
evidence, that a correct definition can coexist with stale values, and that the
inspection tools are for that case. It names no variable, no defect and no
strategy; a prompt saying which values to compare would be an answer key.

Applies to **every arm equally**. Earlier task-set numbers were taken under the
old prompt and are not comparable to runs after this amendment.

### Feasibility, checked before paying for the rerun

A reference fix proving an omniscient repair exists is not evidence the *agent*
can get there. So a legal diagnostic path was constructed using only permitted
`inspect_value` operations, with no privileged knowledge in any query:

```
find_definitions ""    -> *NEGOTIATED* and *QUOTES* both surface
inspect *QUOTES*       -> 20 quotes at once, all four fields visible
inspect a quote        -> (:ID 4 :WEIGHT 5 :ZONE :REMOTE :COST 75)
inspect *NEGOTIATED*   -> "24 entries, keys include 0 17 34 51 68 85 102 119"
inspect SHIPPING-COST  -> 27 for (5 :REMOTE), against the stored 75
```

**7 observations against a 16-request budget.** Nothing requires walking quotes
one at a time, so CONTROL is operationally capable and not merely theoretically
so — which also means the oracle ceiling, when Gate 3 measures it, will not be an
artifact of an impossible baseline.

### Sequence before the rerun

```
failed Gate 1 run     retained as a capability-discoverability finding
      |
prompt amendment      generic, live-state, no answer key
      |
per-case scores       so the next diagnosis needs no pre-run inference
      |
feasibility proven    7 of 16 -- DONE
      |
rerun Gate 1          from scratch
      |
only if reliably solved -> Gate 2, at the unchanged frozen thresholds
```

**Neither frozen threshold moves.** The amendment changes what CONTROL knows
about itself, not what counts as a pass.

## Order

```
B14.1   gate 1 -> gate 2 -> gate 3        on representative repairs
          all three pass?
              |
              +-- no  -> redesign the sequence, or stop. Report which gate.
              |
              +-- yes -> B14.2  E1-E5 and the held-out pair
                         B14.3  hand-write impact_map
                         B14.4  ceiling and transfer over the full sequence
                         B15    the agent discovers and retains it itself
```

## The flat baseline, stated correctly

Task costs need not be numerically identical. What must be ruled out is **learning
across episodes without persistent mutation**. Episodes differ in difficulty, so a
fixed order makes ordering look like learning.

One task pool, **multiple seeded permutations**, fresh conversational context per
episode, no persistent mutation — then test whether **episode index predicts
decreasing cost after controlling for task identity**. A task-1-to-task-5 plot is
not that test.
