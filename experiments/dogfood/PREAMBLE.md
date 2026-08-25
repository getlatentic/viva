# Does retention pay on real work?

Pre-registered. Written before any task runs; thresholds fixed before any
data; a negative result gets written the way the kill was.

## The question, and what is no longer being asked

KC6 settled compiled-versus-text and fired. This does not reopen it. There
is **one arm**: the organism with the retention policy on. The question is
narrower and more basic:

> Left alone on real, recurring work, does the policy accumulate artifacts
> that are worth keeping, that later tasks actually use, and that make the
> work cheaper?

Four claims, each separately falsifiable: **retention happens**, **what it
retains is good**, **what it keeps gets reused**, **reuse pays**.

## An honest amendment to "a week"

Issue #12 says a week of viva's own development. A week is wall-clock
and cannot be compressed into a session, and "whatever development happened
this week" is not a measurable unit — real feature work mostly does not
recur, and retention has nothing to pay off against.

So the unit is **jobs that demonstrably recur**, and the corpus is drawn from
this session's own record: five jobs done by hand repeatedly while building
KC6 and Sprint 1, each with receipts in the transcript and the git log.

```
1  spend so far, from a directory of JSONL transcripts     done 6+ times
2  is the proven layer still green, from TLC output        done 5+ times
3  what tools does a constructed agent actually see        done 3 times
4  summarise a suite run: counts, and any failure          done 10+ times
5  which board issues are open, by sprint                  done 4 times
```

Five variants each, different particulars, same friction — the KC6 family
shape, because it is the shape that lets retention pay inside a short run.
The advantage over the KC6 families is that these are jobs a person actually
needed done, so an artifact retained here has value after the measurement.

**The authorship confound, named.** I choose the corpus and I know which
artifacts would help. Mitigations: every job is one whose repetition is
already in the record rather than invented; no task prompt hints at
retaining anything; and the review that judges artifacts is written down
before the artifacts exist (below).

## Thresholds, fixed now

Measured over 25 tasks, interleaved by shape so retention can pay within and
across shapes.

**1. Retention happens.** At least one artifact retained per five tasks.
Below that, the policy is inert on real work — and that is the finding, the
way the spontaneity null was.

**2. What it retains is good.** At review, each artifact is judged cold
against three questions, and **at least half must be KEPT**:

- does it state something true and non-obvious about this repository?
- would it save a future task real work, rather than restating a task?
- is it free of task-specific answers — does it transfer?

Anything failing one is deleted, with the reason recorded. Below half kept,
the policy retains noise, which is worse than retaining nothing because
noise loads into every later prompt.

**3. What is kept gets reused.** At least **30%** of kept artifacts are used
at least once by a later task — a skill loaded and drawn on, or a tool
called. Below that they are decorative.

**4. Reuse pays.** Late tasks of a shape (variants 4–5) cost at least **20%**
fewer tokens than early ones (variants 1–2) of that same shape. Solve rate
is measured but is not the primary signal: KC6 saturated at 100% everywhere
and cost carried the whole decision.

## What would say it does not pay

Any of these is a negative result and is written plainly, not explained away:

- nothing retained → the policy is inert outside a prompt that invites it
- retained but mostly deleted at review → it retains noise
- kept but unused → the artifacts are decorative
- used but no cost reduction → reuse does not pay at this task size

A split — some shapes paying, others not — is reported as a split and the
pattern named, not averaged into a win.

## Cost, and the cap

Meter stands at **$3.49 of the $7.00** hard budget. This corpus is 25 tasks
at roughly 10–30k tokens each, so **$0.30–0.90 expected**, and the run stops
at the global cap like everything else. Flash only, off-peak preferred, the
same gates the KC6 runner already enforces.

## Artifacts

`experiments/dogfood/jobs/` the five shapes, five variants each, with
checkable answers. `experiments/dogfood/results/` one journal per run.
`RESULTS.md` with the verdict, quoting these thresholds and filling in only
the numbers — and the artifact review in full, kept and deleted alike.
