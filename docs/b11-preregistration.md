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

## Three arms, one variable

Forked from an identical quiescent turn-4 state, exactly as B10:

```
                identical, quiescent turn-4 state
                              │
              ┌───────────────┼───────────────┐
              │               │               │
            FULL          DISTILLED         LEDGER
        keep the whole   restart with a   restart from the
        transcript and   structured       ledger recap
        continue         summary          alone
```

- **FULL** is B10's `control`: same context object, keep going. What every
  harness does today.
- **DISTILLED** replaces the transcript with hypotheses, conclusions and
  unresolved work, with the exploratory noise removed. **Harness-produced, by one
  model call over the transcript** — not agent-authored. That deliberately
  isolates *"is the raw transcript worth its tokens"* from *"should the agent
  author its own state"*, which is B10's A2 and is not this experiment. The
  summariser call is **counted against DISTILLED's budget**; a compression that
  costs more than it saves has not improved anything.
- **LEDGER** is B10's `recovery` arm unchanged: the authoritative external facts
  and actions, nothing else.

Quantities:

```
distillation benefit   =  DISTILLED − FULL
compression floor      =  LEDGER − FULL
does structure pay     =  DISTILLED − LEDGER
```

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

## The validity check that decides whether the result means anything

The mirror image of B10's failure. B10 mistook length for path-dependence twice;
the corresponding error here is that these tasks may simply be ones where the
transcript adds nothing, in which case B11 measures the task set.

> **At least one task must show FULL beating both other arms.** If none does, the
> transcript never demonstrably helps anywhere in the set, and "removing it is
> free" is a statement about these tasks and not about agentic repair.

That is an acceptance criterion, not a footnote. If it fails, the honest report
is *"no task in this set rewards carrying the transcript"* — which is still worth
knowing, and is not the claim above.

## Reading order

1. **Score first.** If DISTILLED or LEDGER lose score, stop; efficiency is moot.
2. **Then the FULL-wins check.** If no task rewards the transcript, the rest is
   about the task set.
3. **Then efficiency**, with spread. Two runs of B10's identical configuration
   flipped the sign of its headline quantity, and S2c measured 24% cell
   disagreement at temperature 0 with a fixed seed. A mean without its range is
   not a result here.
