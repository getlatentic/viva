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
attempts.**

Six because the sequence's premise is that impact discovery spans several
distinct live locations — the definition, its callers, the instances, the values
those produced — and a median of 1–2 would mean the evidence sits in one place
and there is nothing to abstract. Frozen now, before any oracle result exists.

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

## Capability amortisation, recorded from Gate 3 onward

Frozen now because it becomes the central quantity in B15, and a metric invented
after seeing results is not a measurement.

```
creation cost        tokens to write the capability
adoption cost        tokens to make it usable, per arm's own mechanism
per-episode savings  burden and tokens saved once it is in use
BREAK-EVEN EPISODE   ceil(creation / per-episode savings)
total sequence gain  over the training sequence
held-out gain        over the held-out sequence
```

A capability costing 8,000 tokens and saving 1,500 per episode breaks even at
episode 6. **That is the quantity longitudinal self-improvement is actually
about**, and it is what gives HYBRID a concrete reason to exist rather than an
attractive-sounding one:

```
LIVE          creation 8k   adoption ~immediate   benefit starts THIS episode
EXTERNALISED  creation 8k   artifact cost small   benefit starts NEXT episode
HYBRID        creation 8k   both                  benefit this episode AND
                                                  inherited by the next
```

Each arm's adoption cost is measured **from the mechanism it actually uses**.
B11's +2,989 priced restart-and-reconstruct-context and is not this arm's price
tag.

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
