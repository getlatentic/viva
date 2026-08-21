# The control retention is measured against

**Status:** decided 2026-08-21. Amends `experiments/kc6/PROTOCOL.md`. Written
before any further retention data exists, which is the only time a
pre-registration is worth anything.

## Why the old baseline died

KC6's baseline was our own null: 90-plus task-runs, three framings, and no arm
spontaneously retained anything. Every retention number since has been read
against zero.

That baseline is no longer honest. `codex-rs/memories/` is a harness-triggered
retention pipeline in production. It fires when a root session starts, extracts
a structured memory per rollout under a DB lease, then consolidates under a
global lock — ranking by `usage_count` then `last_usage`, dropping anything
outside `max_unused_days`, syncing a git-baselined store, and spawning a
sub-agent to update `MEMORY.md` and `skills/`. Its consolidation prompt carries
our own graduation rule in as many words: create a skill when the procedure
repeats more than once.

So harness-owns-when, model-owns-what, route by shape, graduate on reuse, count
usage, prune what does not pay — six behaviours, all already shipped by someone
else. **Beating zero proves nothing we did not already know.**

## The decision

The control from now on is **this system with graduation disabled**: tier-1
notes and tier-2 code-carrying skills, injected into the prompt, use-counted,
and decayed when unused. The treatment adds the two things that are ours.

Not our null. Not a replication of Codex.

**Why not replicate Codex's pipeline as arm C.** It would be our
implementation of their design, and that makes both outcomes unreadable. A
negative result is attributable to a bad replication; a positive result is a
win over a strawman we built ourselves. Neither is evidence about Codex, and
neither is evidence about us. The published behaviour is the thing to match in
*properties*, not in code.

**Why our-system-minus-graduation is the right control.** It isolates exactly
the variable in question. Both arms retain. Both arms rank by use. Both arms
prune. The only difference is whether a procedure that has proven its reuse
becomes a *callable capability* that other capabilities can call — which is the
one claim `docs/harness-comparison.md` left standing.

**Why it is reachable with the resources we have.** The control is one
parameter: `*graduation-threshold*` set beyond reach. There is no second system
to build, no second implementation to keep faithful, and no way for the arms to
drift apart in anything but the variable under test. Every other difference
between them is a bug, not a confound.

## What the control still needs to be honest

The control must have the properties Codex's published design has, or we are
beating a weaker thing than exists in the world and saying so quietly.

| Codex ships | our control has it? |
|---|---|
| harness decides *when* to retain | yes — reflection fires on the harness's schedule |
| model decides *what* to retain | yes |
| routing by shape (note vs skill) | yes — `docs/retention-policy.md` |
| skills carry executable code | yes — tier 2 carries a snippet |
| ranking by usage count | yes — `note-use` / `uses-of`, built for #7 |
| **pruning what goes unused** | **no — this is #42** |

**So #42 is a prerequisite, not a backlog nicety.** Until retention decays, the
control keeps everything forever, which is *weaker* than the published
behaviour it stands in for, and any advantage the treatment shows is partly an
advantage over a control we handicapped. #42 must land before the first scored
run of #43.

## Where this project can differ at all

Two quantities, and the comparison names them because everything else is
settled:

1. **Composition** — a retained capability calling another retained capability
   by name. deepseek-harness built the substrate for this and rejected a
   structured `register_tool` verb precisely because a registration payload
   cannot express one capability depending on another. They never measured
   whether it pays. Codex cannot: its retained artefacts are text.
2. **Mid-task graduation** — a procedure becoming callable *while the corpus is
   still running*, so later tasks in the same run can call it. Codex
   consolidates between sessions.

Everything else in the retention story is now table stakes.

## Pre-registered thresholds

Restated here before any further retention data exists, per the house rule.

**Primary outcome:** total tokens per task, treatment vs control, summed over
requests. (This column recorded a literal zero until 2026-08-21; it is now
measured. Any earlier reading of it is void.)

**Secondary:** requests per task.

**Effect threshold: a 30% reduction in tokens per task.** Unchanged from KC6,
deliberately. The noise floor has not moved — S2c measured two identical sweeps
disagreeing on 6 of 25 cells, 24%, at temperature 0 with a fixed seed — and the
house rule is that the threshold never moves; N does. Lowering a pre-registered
threshold to meet the data is how a pre-registration becomes a rationalisation.

**Sampling:** 5 repeats per family per arm, spread reported, never a bare mean.
A single sample per cell cannot support a comparison at a 24% noise floor.

**Decision rule:** 6 families, one-sided sign test. Keep the claim only if all
six agree in direction *and* the pooled effect clears 30%. Five of six is not a
pass; it is the ambiguous zone, which allows exactly one pre-sized extension of
4 further families, decided at nine-of-ten (p = 0.011). No second extension.

**Kill criterion, as a number:** if fewer than six of six families favour the
treatment, or the pooled reduction is under 30%, **the composition claim is
dead and is written up as dead**, as KC6 was. A split decision is not an
ambiguous result awaiting more runs — an effect that inconsistent is not one to
build an architecture on.

**Guard — a cheaper wrong answer is not a win.** Task success must not fall.
If the treatment solves fewer tasks than the control anywhere in the battery,
the claim fails regardless of tokens. Registered here because it is the obvious
way to win this comparison dishonestly: a tool call that returns something
plausible costs less than the reasoning it replaced.

**Regime, stated in advance:** high use counts, expensive re-derivation, and
composition depth of at least two. Five cheap tasks measured install cost and
nothing else, which is how KC6 died. A family where re-derivation is a one-liner
cannot test this and must not be authored into the battery.

## Budget, measured rather than guessed

Spend to date is **$3.80 of the $7.00 ceiling**, priced conservatively at peak
rates by `experiments/kc6/budget.py`. **$3.20 remains.**

Per-corpus cost, measured from what has actually run:

| run | shape | cost (peak rates) |
|---|---|---|
| `tier3` | 8 variants, one arm, one repeat | $0.0403 |
| `dogfood` | five tasks, several runs | $0.2767 |
| `kc6` | the full battery | $3.4856 |

At the `tier3` rate, 2 arms × 6 families × 5 repeats is about **$2.40 at peak
rates and $1.20 off-peak**. Composition families are longer than the spans
corpus, so double it: **$2.40–$4.80 peak, $1.20–$2.40 off-peak.**

**That fits only off-peak** — which is already mandatory, and now has a second
reason. `budget.py` refuses at the ceiling rather than trusting anyone to
watch it.

## What this design cannot do, said out loud

It cannot detect a small effect. It cannot compare this project to Codex — no
result here licenses a claim about their system, only about the increment that
is ours. It cannot test transfer inferentially at n = 6. And it cannot rescue a
split decision with more runs.
