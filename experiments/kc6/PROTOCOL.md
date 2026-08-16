# KC6: does live self-modification earn the architecture?

Pre-registered protocol. Written before any run; thresholds set before any
data; changes after first data are amendments, logged, never silent edits.
The question this decides, from the project's own kill criterion six: if live
Lisp self-modification produces no measurable gain over external skills and
tools, SBCL loses its main justification.

This is the reviewed revision of `docs/kc6-protocol.md`. That draft was the
right shape and is preserved verbatim as the origin; verification against the
machinery it presupposes found seven things, listed in AMENDMENTS at the end,
and everything below already carries them. Two were structural — arm B had no
mechanism, and pre-check three was computing a join over a relation the ledger
did not contain — so the wiring landed with this document rather than after it.

## Hypothesis

An agent that can create, activate, and promote component versions through
the evolution owner during its own tasks completes recurring-friction task
families with a better learning curve and lower cost than the same agent with
the door closed, and than the same agent using externalized skills instead.

## Arms

**Arm A, organism.** Evolution enabled through the one door. The agent may
create-candidate, activate for its task, promote after evidence: exactly the
machinery `evolution-v1` shipped.

**Arm B, frozen.** Identical organism, door closed. `:activate` and `:promote`
are refused by the evolution table itself and the refusal is published as
`improvement.door-refused`. Isolates the door's overhead: A must beat B or the
machinery is pure tax.

`:create-candidate` remains open in arm B by pre-registration. Arm B pays the
same cost for the same attempt and receives no effect, which is precisely the
overhead being priced. The refusal text is unambiguous so a competent agent
stops rather than retrying; if the ledger shows arm B thrashing against the
door, that thrash is reported as part of the overhead and not netted out.

**Arm C, external skills.** No live compile. The agent may write and read
persistent text artifacts — skills, notes, snippets — between tasks in a
family, through `src/workspace/skills.lisp` and `remember`, the machinery the
adaptation battery already exercises. This is the criterion's named competitor
and the arm that decides the kill: external skills are what any framework
offers without a live image.

The arms are two switches, so the three configurations come out of them without
conflating any two:

```
--capabilities on  --door open     arm A, the organism
--capabilities on  --door closed   arm B, the same tools, refused
--capabilities off                 arm C, no live compile at all
```

A capability is `(lambda (input) ...)` — one string in, one value out. The
constraint is deliberate: a JSON schema can describe a string, and teaching a
model a second calling convention for arbitrary lambda lists would measure that
lesson rather than the machinery. The frictions this exists for — reshape this
format, parse this dialect, normalise this output — are string to string.

All arms share the base model, pinned to one provider version, same harness,
same budgets, temperature fixed at 0. Capability descriptions in the system
prompt are matched in length and specificity across arms so the door's
description cannot act as a free hint.

**Repeats, not seeds.** The pinned model is hosted, and hosted endpoints accept
a `seed` field and do not honour it — `agent-seed` is on the wire at
`src/core/client.lisp:73` and only llama.cpp respects it. Three repeats per
cell, and the secondary metric is run-to-run variance, which is what it
actually measures. The alternative — pinning the local model to keep
determinism — is refused on purpose: see the capability floor.

## Task battery

Families of sequential tasks sharing a friction, where a retained abstraction
plausibly pays: structured-output reshaping against a quirky format, repo
navigation with a recurring pattern, tool-output parsing variants, protocol
dialects. Within a family, tasks run in order so retention can matter. Tasks
are graded by hidden tests — `./check` exiting 0, as in the adaptation battery
— never by a judge who can see `improvement.*` events.

**Scale, fixed now: 20 families x 5 tasks x 3 arms x 3 repeats = 900 runs.**
Fifteen families are scored; **five are held out** and never seen during any
pilot, measuring transfer of promoted defaults. Families are ordered by a
shuffle fixed and committed before authoring finishes; if the cost cap forces a
cut, families are dropped whole from the end of that order, never by results.

**Authorship is a threat and is named here.** These families are authored by
the same agent the experiment tests, which can build the answer key into the
battery by choosing frictions whose abstraction it already has in mind. Three
mechanisms: the friction of each family is drawn from a real recurring cost in
this repository's own history rather than invented; hidden tests are written
against the task's specification before any arm runs; and the five held-out
families are authored last, from the same rule, and opened only for the final
analysis. A positive result carried only by non-held-out families is reported
as an overfit result, not a win.

## The five pre-checks, before a model runs

**0. Reachable by the entity under test.** `experiments/kc6/reachability.lisp`
asks three questions and now answers all three yes, having answered the first
two no when it was written:

- Does a model-visible tool reach the evolution owner? Armed, an agent sees
  fourteen tools rather than nine: `create_capability`, `activate_capability`,
  `call_capability`, `promote_capability`, `list_capabilities`.
- Does anything in the shipped organism resolve a component?
  `src/daemon/capability.lisp` does, which is what `call_capability` runs.
- Is the JSON the model is actually SENT well formed? Checked on the wire, not
  on the Lisp objects, because B14 concluded a model could not derive a
  predicate when the truth was that its tool advertised `args` as an array with
  no `items`. That check is proven able to fail by
  `reachability.lisp --self-test`, which feeds it four malformed shapes and one
  good one.

This runs FIRST in `preflight.sh` and stops the gate if it fails: pre-checks
one and three both pass against an organism no model can reach, because they
drive the Lisp wire and a model drives the tool surface.

**1. Lifecycle through the real wire.** A scripted agent, no LLM, traverses
create, activate, resolve, inherit, promote, revert, discard, and the ledger
shows the whole genealogy — `experiments/kc6/preflight.lisp`, plus
`spec/verify.sh` green and the evolution block of `tests/daemon.lisp`.

**2. Non-collapse.** Arm A driven by a never-evolve policy must match arm B
**within 5% on wall clock and 2% on tokens**, with solve rates equal within
repeat noise, on a pilot slice of 3 non-held-out families. Above that, the
machinery's mere presence is a material tax and is reported as one.

**3. Instrumentality.** In arm A pilots, versions the agent creates must
actually be resolved by later turns. Computed, not asserted:
`experiments/kc6/instrumentality.py` joins `improvement.activated` to the
`improvement.resolved` events that follow it in the ledger. Thresholds:
**at least 50% of created versions resolved at least once**, and **at least
one resolution in at least 80% of tasks where a version was created**. Below
either, the experiment would measure prompt placebo rather than machinery, and
must not proceed until the harness makes use reachable.

**4. Capability floor.** In the arm-A pilot the model must, at least once per
pilot family, produce a component version that both resolves and leaves the
family's hidden test passing. A model that cannot write a working component
turns KC6 into a measurement of that model's ceiling, and a kill criterion is
the worst possible place to accept a false negative. If the floor fails, the
pinned model is the finding, and the battery does not run until a model that
clears it is pinned.

## Metrics, pre-registered

**Primary.** Success rate by family position — the learning-curve change from
positions 1–2 to positions 4–5 — and **cost per solved task** in tokens and in
wall clock. Cost is per *solved* task on purpose: an arm that gets cheap by
giving up is not cheaper, and a mean over all attempts would score it as
though it were. Tokens are summed from each reply's recorded usage in the
transcript, added to the harness for this experiment.

**Secondary.** Reuse rate of retained versions across a family; transfer
success on held-out families resolving promoted defaults; revert rate;
regression count, meaning a promotion that lowers later-task success; variance
across repeats.

**Unit of analysis is the family, not the task.** Tasks within a family are
sequential and dependent by construction — that dependence is the phenomenon —
so treating 900 runs as 900 independent observations would inflate significance
by roughly the family length. Twenty paired observations per comparison.

## Decision rule, set now

Comparisons are paired by family. Test: two-sided Wilcoxon signed-rank at
**alpha = 0.05**.

Minimum effect that counts, chosen for practical significance before any data:
**a 20% reduction in tokens per solved task**, or **+0.15 absolute in
late-position solve rate**, in the same direction on both.

**Keep the architecture** if A beats C at that effect size and significance on
the held-out families, and A beats B on the same terms.

**Kill criterion six fires** if A fails to beat C after the full battery. The
honest conclusion is then that external skills capture the value without the
live image, and the roadmap's Elixir/external question reopens with data
instead of taste.

**The ambiguous zone**, allowed once: if effects are positive and consistent in
direction but under threshold, run one pre-sized extension of 10 further
families from the fixed shuffle, then decide on the combined set. No second
extension; that is the infinite refinement loop wearing a lab coat.

**The threshold never moves; N does.** If the pilot shows the noise floor makes
a 20% effect undetectable at 20 families, the battery is *enlarged* from the
fixed shuffle before any scored run. Lowering a pre-registered threshold to
meet the data is how a pre-registration becomes a rationalisation.

## Threats and their mechanisms

**Prompt leakage between arms** — matched capability text, reviewed side by
side before run one.

**Arm mislabelling** — every run's own ledger opens with `improvement.door`
naming the arm, so the analysis reads the arm from the run's evidence rather
than from a directory name.

**Overfit versions** — held-out families are the check that a promoted default
is an abstraction rather than a memorised answer.

**Metric gaming** — hidden tests grade outcomes; the agent never sees graders.

**Provider drift** — model version pinned; any forced migration restarts the
affected repeats, and the restart is logged as an amendment.

**Analysis drift** — every run journals to the ledger, and the analysis is a
program over the ledger, reconstructible exactly the way lineage already is.

**Instrument failure passing as a result** — every pre-check above has a
threshold that can fail. A pre-check that cannot fail is not a check, and
pre-check three could not fail before the ledger recorded use at all.

## Cost, and what is measured versus bounded

Bounded by the harness, exactly: `--limit 30` model requests per task-run, 900
task-runs, so **at most 27,000 model requests** for the full battery.

**Measured anchors**, from two live runs of one toy task on the pinned model,
the same prompt in both arms:

```
arm A (door open)      5 requests   6 tool calls   17,257 tokens   $0.0053
arm B (door closed)   10 requests  10 tool calls   57,384 tokens   $0.0183
```

Arm A compiled a converter, activated it, ran it three times, and stopped. Arm
B compiled the same converter, was refused, verified once that nothing
resolved, and fell back to `awk` — getting the field order wrong on the first
attempt and fixing it on the second. That is the door's overhead appearing in
the direction the protocol expects, and it is **n=1 on a toy task**: an anchor
for projection, not a result, and not the pilot.

Fixed per-request prompt overhead, measured: **1,870 tokens for arm C, 2,526
for arms A and B**, the difference being the five capability schemas. A and B
are therefore *exactly* matched on prompt surface, which is the comparison that
isolates the door. A against C carries 656 tokens of inherent asymmetry, since
arm C cannot be given tools it is defined by not having; that is reported
rather than corrected.

Projected from those anchors, the full battery is of the order of 30M tokens
and **tens of dollars**, not hundreds. The cap is still fixed by a measured
pilot on the real families — these tasks are toys and a repo-navigation family
will cost more per request — and stated in dollars and tokens in `RESULTS.md`
before run one. The run stops at the cap.

**One ledger per run** is a requirement, not a convention: the analysis is a
program over a single run's ledger and `instrumentality.py` refuses a file
holding two arms rather than blending them. `--journal-dir` gives each run its
own, and is mandatory for every battery run.

## Artifacts

`experiments/kc6/PROTOCOL.md`, this file, committed before run one.
`experiments/kc6/instrumentality.py`, pre-check three as a program.
`experiments/kc6/results/` holding one journal per run and the analysis
program. A `RESULTS.md` whose verdict section quotes the decision rule verbatim
and fills in only the numbers.

## Amendments

Logged, per this protocol's own rule. All seven came from verifying the
original draft against the machinery before judging it.

1. **Arm B had no mechanism.** Nothing in the organism could refuse activation
   or promotion. Added as a guard in the evolution table, mirrored by
   `CONSTANT Door` in `spec/Evolution.tla`, with `ClosedDoorIsInert` proving
   nothing a closed run creates is ever resolved, and `EvolutionWitnessDoor`
   proving that guard load-bearing by violating the law in 33 states when it is
   removed. Refusing at the tool boundary was considered and rejected: it is
   the second door the no-back-door law forbids, and arm B's entire validity is
   that no path reaches promotion.

2. **Pre-check three was uncomputable.** The ledger held seven `improvement.*`
   names, all decisions, none of them use; `resolve-component` published
   nothing. The join from `improvement.activated` to "subsequent component
   resolutions" ran over a relation that did not exist, so the check that
   exists to catch a placebo result was itself unable to fail. Added
   `improvement.resolved`, bounded to first use per task and version, ordered
   through the owner's mailbox so a resolution can never be recorded before the
   activation that caused it.

3. **Three thresholds were named but never stated** — effect size,
   significance, latency budget — and the ambiguous-zone clause cannot be
   evaluated without them. All now numeric, with the rule that N moves and the
   threshold does not.

4. **"Seeds fixed per run" is false for a hosted model.** Renamed to repeats,
   determinism claim dropped, and the reason recorded.

5. **The primary metric was not recorded.** `results.tsv` carried requests and
   tool calls, not tokens. Usage was already in every transcript; the harness
   now sums it, and reports cost per *solved* task.

6. **Authorship bias was unnamed.** The agent under test authors the battery.
   Three mechanisms added, and the held-out families are authored last.

7. **The capability floor did not exist.** A model too weak to write a working
   component would produce a false negative on a kill criterion — the most
   expensive possible error here. Added as pre-check four.

8. **Arm A is not reachable by a model, and pre-check one could not tell.**
   Found by asking what tools a workspace agent actually receives, through the
   real constructor rather than by reading the code: nine, none of which reach
   evolution, and `call-component` has no caller in `src/`. Pre-check one
   passes anyway because it drives the Lisp wire with a scripted agent — the
   same gap this project has paid for before, when a tool passing a Lisp unit
   test was being advertised to the model with a malformed schema. Added as
   pre-check zero, which runs first and stops the gate. **No battery may run
   while it fails**, and no result obtained while it fails means anything.

9. **The surface it demanded now exists**, chosen deliberately rather than by
   whichever wiring was easiest: five tools through which an agent mints,
   keeps and runs compiled capability of its own, in
   `src/daemon/capability.lisp`. Tools-as-components — the agent replacing its
   own `grep` or `edit` — is the stronger claim and the named follow-on;
   adding it later does not invalidate a result obtained here. Pre-check zero
   passes, and the gate is green end to end.
