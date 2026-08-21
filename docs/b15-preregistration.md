# B15 — Composition: does a capability calling a capability beat a re-derived skill?

**Pre-registered 2026-08-21, before any data exists.** Control, thresholds and
kill criterion are fixed here and do not move afterwards. Issue #43.

## The claim, stated so it can lose

Reading four harnesses settled where this project is *not* distinct. Codex ships
harness-triggered retention with usage ranking and pruning. deepseek-harness
ships the live self-modification door and explicitly refuses to promote what it
mints. Abort in flight is Pi's too. What nobody holds is both halves:

> Codex has retention with no live execution. deepseek-harness has live
> execution with no retention, by decision. This project has both, which makes
> it the only place the composition claim can be tested: **does a capability
> that graduates mid-task, and can be called by another capability, beat a text
> skill re-derived each time?**

deepseek-harness rejected a structured `register_tool` verb for exactly this
reason — a registration payload cannot express one capability depending on
another — and chose a mount primitive where mounts relate through ordinary
`provide`/`inject`. **They built the composition substrate and never measured
whether it pays.** That measurement is available here and nowhere else.

## Arms

Both arms retain. This is what KC6 always meant by compiled-vs-text and it is
the correction #40 made: the comparison is *given retention happens*, not
retention against nothing.

| | control (**T**ext) | treatment (**C**omposed) |
|---|---|---|
| tier-1 notes | yes | yes |
| tier-2 code-carrying skills | yes | yes |
| use counting | yes | yes |
| decay of unused retentions (#42) | yes | yes |
| graduation to a callable tool | **disabled** | enabled at 3 runs |
| a tool resolving another tool by name | no | yes |

The control is `*graduation-threshold*` set beyond reach. One parameter, so the
arms cannot differ in anything but the variable under test — every other
difference between them is a bug, not a confound.

**"Composition" mechanically:** one registered tool naming another registered
tool in its `exec` or resolving it by name at run time, so the second tool's
work is reached through the first rather than re-derived inside it. Depth two
is the minimum that tests anything; depth one is just graduation.

## The regime, named before the families are authored

**High use counts, expensive re-derivation, composition depth of at least two.**

Five cheap tasks measured install cost and nothing else, which is how KC6 died,
and `experiments/tier3/FINDING.md` recorded the same thing from the other
direction: the first corpus was too easy, four solved and nothing retained,
because a one-liner is not code you would rewrite — it is code you would retype.

So a family qualifies only if:

1. the transformation costs real tokens to re-derive — nested access, unit
   handling, a decoy that punishes a careless parse
2. the same transformation is needed by **at least six** tasks in the family, so
   reuse is evident while the corpus is still running
3. at least one task needs **two** retained capabilities composed

A family that cannot meet all three is not authored into the battery. Authoring
one and then discovering it cannot test the claim is the failure this paragraph
exists to prevent.

**Amended 2026-08-21, before any B15 data — six may not be enough.** A clean
run of `experiments/tier3` (8 variants, one shape, policy on) wrote its skill
at task 3 and then called it **twice in the five tasks that could have**. The
counter reached 2, the threshold is 3, and **nothing graduated** — in a corpus
built specifically to reach tier 3. Measurement and caveats:
`docs/tier-2-reuse-signal.md`.

At a call rate near 40%, six tasks needing the transformation yields about two
or three calls, which is on the wrong side of the threshold as often as not. So:

- families are sized for the *call rate*, not the *need rate* — enough tasks
  that three calls are likely, not merely three needs
- **the treatment arm is checked for graduation before its numbers are read.**
  An arm that never graduated is a second control, and comparing two controls
  would produce a clean null that means nothing. If an arm did not graduate,
  that family is reported as not having tested the claim rather than as
  evidence against it.

This is registered here rather than discovered later, which is the difference
between a caveat and an excuse.

## Outcomes and thresholds

**Primary:** total tokens per task, summed over requests, treatment vs control.

> The `prompt` and `completion` columns of `results.tsv` held a literal `0` on
> every row until 2026-08-21. Any token figure from that file before then is
> void. The columns are now populated from the usage each reply reports —
> verified on live data: `prompt 21004 completion 1170`.

**Secondary:** requests per task.

**Effect threshold: 30% reduction in tokens per task.** Carried over from KC6
unchanged and deliberately. The noise floor has not moved — S2c measured two
identical sweeps disagreeing on 6 of 25 cells, 24%, at temperature 0 with a
fixed seed — and the house rule is that the threshold never moves; N does.

**Sampling:** 5 repeats per family per arm. Spread reported, never a bare mean.
A single sample per cell cannot support a comparison at a 24% noise floor.

**Decision:** 6 families, one-sided sign test. Keep the claim only if **all six
agree in direction** (p = 0.016) *and* the pooled effect clears 30%.

**The ambiguous zone, allowed once:** all six agree in direction but the effect
is under threshold → one pre-sized extension of 4 further families, authored
after the decision to extend and before any extension run, decided on the
combined set at **nine of ten** (p = 0.011). Eight of ten is p = 0.055 and
fails. No second extension; that is the infinite refinement loop wearing a lab
coat.

## The kill criterion, as a number

**If fewer than six of six families favour the treatment, or the pooled
reduction in tokens per task is under 30%, the composition claim is dead** and
is written up as dead, as KC6 was.

A split decision is not an ambiguous result awaiting more runs. An effect that
inconsistent is not one to build an architecture on.

**Guard — a cheaper wrong answer is not a win.** If the treatment solves fewer
tasks than the control anywhere in the battery, the claim fails regardless of
tokens. Registered because it is the obvious way to win this dishonestly: a
tool call returning something plausible costs less than the reasoning it
replaced.

**Guard — composition must actually happen.** If the treatment arm's tools are
never composed — depth stays at one across the battery — the run measured
graduation, not composition, and must be reported as such rather than as
evidence for this claim.

## Threats

**Arm mislabelling** — every run's ledger opens naming the arm, so the analysis
reads the arm from the run's own evidence rather than from a directory name.

**Prompt leakage** — the two arms' capability text is matched and reviewed side
by side before run one. The control must not be told it cannot graduate; it
must simply have no threshold it can reach.

**A lying manifest** — #41 refuses a `tool.json` whose declared parameters the
script cannot receive. Without it, a composed call fails inside a body and the
treatment arm pays a cost the control does not, which would look like the
opposite of an effect.

**Metric gaming** — hidden tests grade outcomes; the agent never sees graders.

## Budget

$3.80 of the $7.00 ceiling is spent; **$3.20 remains**. Measured per-corpus
cost: `tier3`, 8 variants, one arm, one repeat — **$0.0403** at peak rates.

2 arms × 6 families × 5 repeats at that rate is **$2.40 peak / $1.20 off-peak**.
Composition families are longer than the spans corpus, so budget double:
**$2.40–$4.80 off-peak-to-peak**, which fits **only off-peak** — already
mandatory, and now with a second reason. `budget.py` refuses at the ceiling.

**If the battery will not fit, N falls and the fact is reported.** The threshold
does not move to meet the money any more than it moves to meet the data.

## What this design cannot do, said out loud

It cannot detect a small effect. It cannot compare this project to Codex or to
deepseek-harness — no result licenses a claim about their systems, only about
the increment that is ours. It cannot test transfer inferentially at n = 6. And
it cannot rescue a split decision with more runs.
