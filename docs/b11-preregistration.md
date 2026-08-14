# B11 — pre-registration

**Frozen before the first scored run.** Shorter than
[B10's](b10-preregistration.md) because the instrument already exists and is
validated: same quiescent turn-4 fork, same paired control, same repeat and
spread discipline. Only the arms change.

## The claim

> For agentic repair, accumulated conversational context carries enough
> irrelevant exploratory history that deliberate compression improves
> performance.

Stated so it can fail. It came out of B10 stage 1 as an *incidental* observation
— an agent restarted from a compact ledger recap finished in **4.6 turns against
6.5** carrying its full transcript, at equal score, with per-turn context
differing by only ~10%, so fewer turns rather than cheaper ones. One point,
observed on tasks chosen for a different property, with the arm never varied or
optimised. That is a reason to run an experiment, not a result.

## Four arms, one variable

**The sham is retained**, and dropping it was a mistake in the first draft of
this document. Three arms would have confounded the thing being measured:

```
FULL vs DISTILLED  =  transcript-vs-summary  +  continue-vs-restart
```

and B10 measured that second term as large — on one pair the restart channel
alone moved score by 0.4 in both directions, and on another it moved tokens by
+2,703 with no cognition lost at all. Comparing a restarting arm against a
continuing one throws away B10's best methodological lesson.

```
                identical, quiescent turn-4 state
                              │
        ┌──────────────┬──────┴───────┬──────────────┐
        │              │              │              │
      FULL           SHAM         DISTILLED        LEDGER
   keep the       restart, then   restart with   restart from
   transcript,    restore the     a structured   the ledger
   continue       identical       summary        recap alone
                  transcript
```

- **FULL** — B10's `control`. What every harness does today.
- **SHAM** — B10's `sham`, unchanged: the machinery is rebuilt, the transcript is
  handed back. Restart exercised, cognition retained.
- **DISTILLED** — hypotheses, conclusions and unresolved work, exploratory noise
  removed. **Harness-produced by one model call** — not agent-authored, which
  isolates *"is the raw transcript worth its tokens"* from *"should the agent
  author its own state"* (B10's A2, a different question).
- **LEDGER** — B10's `recovery` arm unchanged: authoritative external facts and
  actions, nothing else.

### Two families of contrast, named separately

They answer different questions and must not be mixed in one claim.

**Primary — causal.** Taken against SHAM, so the restart sits on both sides and
cancels. These say what *distillation* does:

```
restart / plumbing effect     =  SHAM      − FULL
effect of distillation        =  DISTILLED − SHAM
effect of discarding it       =  LEDGER    − SHAM
distilled cognition beyond
  authoritative facts         =  DISTILLED − LEDGER
```

**Secondary — practical.** Taken against FULL, which is what a harness does
today. These say whether the *whole procedure* — summarise, restart, continue —
is worth adopting:

```
is compress-and-restart worth it  =  DISTILLED − FULL
is ledger-restart worth it        =  LEDGER    − FULL
```

A secondary contrast may contain restart effects and cannot carry a causal
claim. A primary contrast is causally clean but does not tell you whether to
change the harness. Report both; never substitute one for the other.

### The summariser is frozen too

Fixed before the first run and not tuned between runs: **model, temperature,
prompt, output schema, maximum output length, and input boundary.**

> **DISTILLED may only see information available before the fork.** No
> post-checkpoint results, no reference fix, no evaluator output, no case
> definitions.

The summariser call is **charged to DISTILLED's budget**, so what is reported is

```
net efficiency gain = post-checkpoint savings − summarisation cost
```

Otherwise the experiment would be measuring free compression.

**Score is reported before efficiency, always.** The B10 observation is only
interesting if score holds; a cheaper arm that solves less is not a finding.

## What is frozen

| | |
|---|---|
| model | `openai/gpt-oss-120b` via OpenRouter, temperature 0 |
| checkpoint | turn 4, quiescent, one per run — B10's rule unchanged |
| branch budget | 8 requests after the fork |
| repeats | 5 pairs per task, spread reported, never a bare mean |
| summariser | same model, same temperature, one call, cost charged to DISTILLED |

**Tasks: not inherited from B10.** Family D was built to be long and was then
shown not to be path-dependent; reusing it alone would risk measuring three tasks
again. B11 runs on a spread across the *existing* families — `A-STATE`, `A-LIVE`,
`A-FLIGHT`, `B-CAPABILITY`, `M-CONFLICT` — plus family D, so the result is about
agentic repair rather than about one family's shape.

## The generalisation gate — which is not a validity gate

The first draft of this document called "at least one task must show FULL winning"
an instrument-validity criterion. That was wrong, and wrong in a way B10's own
discipline forbids: **it would require reality to produce a result favourable to
FULL before the experiment counted as working.** If FULL never wins, the
instrument may be perfectly sound and the finding may simply be true.

So it is a gate on *what may be claimed*, not on whether the measurement is valid:

```
if neither FULL nor SHAM ever beats DISTILLED or LEDGER:
    valid   →  "on this workload, retaining the raw transcript
                showed no observed benefit"
    forbidden →  "raw transcripts are unnecessary for agentic repair"
```

The result stands either way; only its scope narrows.

## The outcome worth watching for

Not LEDGER winning. The most consequential pattern would be the **middle** arm,
and it decomposes into three claims of increasing strength rather than one:

```
score        DISTILLED ≥ SHAM  and  DISTILLED > LEDGER
causal cost  DISTILLED < SHAM      after charging summarisation
practical    DISTILLED < FULL
```

```
DIST < SHAM       →  compression itself helps
DIST < FULL       →  the whole compress-and-restart procedure beats
                     ordinary continuation
DIST > LEDGER
  on score        →  useful cognitive information exists beyond the
                     authoritative external facts
```

Each can hold without the others. `DIST < SHAM` with `DIST > FULL` would mean
compression helps but not enough to pay for the restart it requires — worth
knowing, and not the same finding. Together they would say: *useful cognition
exists, and the raw trajectory is the wrong representation of it.* That is a much stronger architectural finding than
"compression saves tokens", and it feeds every open story —

- **B10 / Smalltalk** — full continuation may be excessive.
- **B8 / BEAM** — explicit state becomes more plausible.
- **B12 / Cordis** — component-local state could be externalised into a
  longer-lived cognitive dependency, which is exactly the escape hatch §7.3 names.
- **vivarium** — the ledger stays authoritative while distilled cognition becomes
  a separate, explicitly **non-authoritative** working-memory layer.

Recorded in advance so that finding it later is a prediction confirmed rather
than a story told afterwards.

## Reading order

1. **Score first, against SHAM** — the treatment control. If DISTILLED or LEDGER
   lose score *to SHAM*, stop; efficiency is moot. A score difference against
   FULL is reported too, but it may contain restart effects and cannot end the
   experiment on its own.
2. **Then `SHAM − FULL`**, which bounds what any other contrast can mean.
3. **Then the generalisation gate**, to fix the scope of the claim.
4. **Then efficiency**, causal first (`DIST − SHAM`, net of summarisation) and
   practical second (`DIST − FULL`), with spread. Two runs of B10's identical configuration
   flipped the sign of its headline quantity, and S2c measured 24% cell
   disagreement at temperature 0 with a fixed seed. A mean without its range is
   not a result here.
