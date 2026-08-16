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

**Scale, fixed now: 6 families x 5 tasks, arms A and C at 3 repeats each,
arm B at 3 repeats on families 3, 1, 4 — bound mechanically as the first
three scored families in the committed battery order (3, 1, 4, 2, 6, 5), so
the choice cannot follow the pilot. 225 runs.** Cost: 13.5M tokens and $6.65
uncached-at-peak at the measured per-run anchor; the shape projections in the
cost section bracket heavier families up to $45, and the caps are sized to
the bracket, not the anchor.

Twenty families was never buying significance. It was buying the power to
detect a SMALL effect, and **a build decision does not need a small effect**:
if live self-modification wins only by a hair, the architecture has not earned
itself. Paired by family with a directional hypothesis — the criterion asks
whether self-modification *helps* — the one-sided sign test reaches p = 0.031
at five families and p = 0.016 at six. Five is the floor; six is five plus one
family of slack.

Arm B carries fewer runs on purpose. It controls a nuisance parameter — the
door's overhead — while A against C is the comparison that decides the kill, so
the runs go where the decision is.

Two of the six families are held out. **Held out means held out of authoring
iteration and of pilots — never out of the analysis.** All six families run in
the battery and all six enter the primary sign test: n = 6 IS the six, and a
reading where the primary ran on four would make significance unreachable by
construction (four agreeing gives p = 0.0625). What the held-out pair is
excluded from is the pilot slice and authoring-time knowledge — authored last,
after the scored four are frozen, their sandboxes opened only when the battery
runs. **At this size transfer is descriptive, not inferential**, and is
reported as an observation rather than a test. That is the honest cost of the
smaller battery and it is stated rather than discovered in the analysis.

The binding constraint here was never the bill: 900 runs is about $27 at these
rates. It is the authoring — 100 tasks with hidden tests is weeks of work that
is not the mission — and the drift that comes with it. This project has drifted
into perfecting a benchmark once already.

**The six families, drawn from this session's own record.** Every one is a
friction that actually recurred while building the machinery under test, which
is why they are cheap to author honestly and hard to rig: the commits show them
happening before anyone chose them as tasks.

```
1  paren balance in a Lisp edit        broken twice; a depth-printing probe fixed it
2  usage totals out of JSONL           the same parse written four times
3  what tools does an agent SEE        answerable only through the real constructor
4  TLC output -> holds or violates     needed a config-to-expectation table
5  a symbol's definition and callers   repeated greps across packages
6  a version id out of tool prose      parsed the word `version` instead of the number
```

Each family is five tasks over the same friction with different particulars, so
a retained abstraction can pay from task two onward. Hidden tests are written
against each task's specification before any arm runs.

**Authorship is a threat and is named here.** These families are authored by
the same agent the experiment tests, which can build the answer key into the
battery by choosing frictions whose abstraction it already has in mind. Three
mechanisms: the friction of each family is drawn from a real recurring cost in
this repository's own history rather than invented; hidden tests are written
against the task's specification before any arm runs; and the two held-out
families are authored last, from the same rule, after the scored four are
frozen. A positive result carried only by non-held-out families is reported as
an overfit result, not a win.

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
repeat noise, on a pilot slice of the same mechanically bound three
families arm B runs on (3, 1, 4). Above that, the
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
pinned model is the finding, and the battery does not run. Amendment 13
pins `deepseek-v4-flash` exclusively — there is no substitution model. A
floor failure on Flash is a reported result and a user decision, never a
silent reach for Pro.

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
so treating 225 runs as 225 independent observations would inflate
significance by roughly the family length. Six paired observations for A
against C; three for the arm-B control.

## Decision rule, set now

Comparisons are paired by family. Test: **one-sided sign test at n = 6,
alpha = 0.05**, which requires all six families to agree in direction — p =
0.016 when they do. The hypothesis is directional by construction: the
criterion asks whether self-modification helps, not whether it differs.

Minimum effect that counts, chosen for practical significance before any data,
and deliberately large because a build decision needs a large effect: **a 30%
reduction in tokens per solved task**, or **+0.20 absolute in late-position
solve rate**, in the same direction on both.

**Keep the architecture** if A beats C at that effect size with all six
families agreeing, and A passes the arm-B control. The control is a
consistency claim, not a significance claim — n = 3 cannot reach 0.05 and is
not asked to, so "A beats B on the same terms" was impossible as written: on
all three of arm B's bound families, A at least matches B on the primary
metrics and no family shows B better by the effect size. The door's overhead
is controlled, not adjudicated.

**Kill criterion six fires** if A fails to beat C. The honest conclusion is
then that external skills capture the value without the live image, and the
roadmap's Elixir/external question reopens with data instead of taste.

**What this size cannot do, said out loud.** It cannot detect a small effect,
it cannot test transfer inferentially, and a split decision — some families
one way, some the other — is not an ambiguous result to be resolved by more
runs. It is the answer: an effect that inconsistent is not one to build an
architecture on.

**The ambiguous zone**, allowed once: if all six families agree in direction
but the effect is under threshold, run one pre-sized extension of 4 further
families, then decide on the combined set with the same one-sided sign test
at n = 10: **keep only if at least nine of ten families agree** (p = 0.011);
eight of ten is p = 0.055 and fails. Extension families are authored after
the decision to extend but before any extension run, under the same three
authorship mechanisms. No second extension; that is the infinite refinement
loop wearing a lab coat.

**The threshold never moves; N does.** If the pilot shows the noise floor
makes the 30% effect undetectable at six families, the battery is *enlarged* —
more families authored under the same mechanisms — before any scored run. Lowering a pre-registered threshold to
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

Bounded by the harness, exactly: `--limit 30` model requests per task-run,
225 task-runs, so **at most 6,750 model requests** for the full battery, and
at most 2,700 for the 90-run pilot slice.

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

**Cache behaviour is the thing that decides this cost, and it is measured.**
The conversation prefix is stable across a run, so each request misses only on
what was appended since the last one:

```
arm A   5 requests   13,440 hit   2,991 miss     826 out    82% hit rate
arm B  10 requests   49,024 hit   5,033 miss   3,327 out    91% hit rate
```

Cache-miss tokens are therefore roughly flat per run and track content READ,
not request count — doubling the requests took misses from 3.0k to 5.0k while
total tokens went from 17k to 57k. Multiplying total tokens by a miss price
overstates the bill by an order of magnitude.

Projected over the 225 runs, three shapes of family task:

```
          req  end ctx   tok/run     total tok    miss tok
light      10    8,000    56,800    12,780,000   2,430,000
medium     18   16,000   174,240    39,204,000   4,230,000
heavy      28   28,000   439,040    98,784,000   6,930,000
```

**The cap, fixed now: 120M total tokens and 9M cache-miss tokens for the full
battery, and 20M total for the pilot slice.** Amendment 12 tightened these
from caps sized to the 900-run draft — a cap four times looser than its
design is not a cap, and shrinking one before any data is safe in exactly the
way loosening one is not.

**The budget: $7.00, hard, in dollars, metered — amendment 13.** The
worst-case bracket exceeds $7 several times over, so no schedule can promise
compliance; only a meter between runs can. `experiments/kc6/budget.py` prices
every recorded reply at Flash rates — cache hit, cache miss, output — and the
runner consults it before each run: a non-zero exit stops the battery. Every
ambiguity in the meter resolves against the spender: peak rates are assumed
unless the runner knows it is off-peak, and an entry without cache accounting
is priced as all miss. The token caps above and the dollar meter both stand;
whichever binds first stops the run.

**Scheduling is off-peak, mandatorily**: outside 01:00–04:00 and 06:00–10:00
UTC. It halves the worst case for nothing. Expected all-in spend at measured
cache behaviour, off-peak: **$1.78–$4.09** across the three shapes, pilot
included; the $7 is the ceiling, not the estimate.

**Truncation priority, if the meter binds.** The order of spending protects
the kill decision: (1) the pilot, sub-capped at $1.50 of the seven; (2) arms
A and C, family by family in the committed battery order (3, 1, 4, 2, 6, 5)
— the primary comparison; (3) arm B on its bound three, last. If the meter
binds during (2), the current family's A and C cells complete, remaining
families drop whole from the end of the order, and the primary sign test
proceeds at n >= 5 — five is the pre-registered floor; below five there is no
decision, only a report. If the meter binds during (3), the kill side of the
decision rule is unaffected — it needs no arm B — and a keep verdict becomes
**keep, control pending**: provisional until the remaining arm-B runs are
funded and pass. Whichever binds first stops the
run. The cap is a limit rather than a prediction — the heavy column fits inside
it — and the pilot still measures the real per-run figure before the battery
starts, but no run waits on that measurement to be safe.

**Priced at DeepSeek V4 published rates, on `deepseek-v4-flash`** — the model
these runs used. Off-peak is half of peak, and peak is only 01:00-04:00 and
06:00-10:00 UTC, so a battery scheduled outside those windows halves its bill
for nothing:

```
shape      total tok        miss   off-peak     peak   no cache
light     12,780,000   2,430,000      $1.02    $2.04      $6.18
medium    39,204,000   4,230,000      $1.92    $3.83     $18.25
heavy     98,784,000   6,930,000      $3.32    $6.64     $45.02
pilot     15,681,600   1,692,000      $0.77    $1.53      $7.30
```

`deepseek-v4-pro` is disallowed by amendment 13. Its bracket is retained
only to show what the pin refuses: roughly three times every figure — about
$10 off-peak at the heavy end, $135 peak and uncached.

**THE CACHE IS NOT GUARANTEED, and the `no cache` column is the planning
number.** DeepSeek's context cache is best-effort prefix matching, not a
contract. Within a run the 82-91% hit rate measured above is structural — the
prefix is append-only and requests are seconds apart — but it would break if
anything mutated the prefix per request, so nothing may be injected there.
Across runs it is already worthless: the first request of both live runs cached
**256 of 2,833 tokens**, because the working directory appears early in the
system prompt and every run has a different sandbox. Moving the varying parts
of the prompt after the stable ones would recover roughly 2.3M miss tokens
across the battery, worth about fifty cents on Flash — a tidy fix, not a lever,
and recorded here so it is not mistaken for one.

The cap above is stated in TOKENS on purpose. Tokens do not move with the hit
rate; only the bill does.

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

13. **The $7 budget and the Flash pin, on the user's directive.** The
   worst-case bracket ($45 heavy, uncached, peak) exceeds the budget several
   times over, so the budget is a metered hard stop, not a projection:
   `budget.py` prices every reply conservatively (peak assumed, missing
   cache accounting priced as all miss), self-tested to refuse and to
   approve, and the runner stops on its word. Off-peak scheduling is
   mandatory. The truncation priority protects the kill decision: pilot
   sub-capped, then A and C in battery order, then B — with the primary
   proceeding at n >= 5 if families must drop, and a keep verdict without a
   completed control marked provisional. `deepseek-v4-flash` is the only
   model allowed to spend; the pin is a preflight gate that fails on any
   other value, proven in both directions, and a capability-floor failure on
   Flash is a finding, never a reach for Pro.

12. **The 900-run draft's last survivors, and the last open freedoms, on
   review's sweep.** Five stale numbers, four caught by review and a fifth
   found applying it: the unit-of-analysis paragraph argued from 900 runs
   and twenty paired observations where the design is 225 and six; the
   request bound was 27,000 against a design bounded at 6,750; the token
   projection and the caps were sized to 900 runs, leaving the pre-registered
   cap four times looser than the battery it capped — recomputed at 225, caps
   tightened to 120M total / 9M miss; and the threshold-never-moves paragraph
   itself still said "a 20% effect at 20 families" where the rule is 30% at
   six. Two freedoms closed: arm B's families and the pilot slice are bound
   mechanically to the first three scored families in the committed battery
   order (3, 1, 4), and the combined-set test is named — nine of ten at
   p = 0.011, eight of ten fails. One impossibility repaired: "A beats B on
   the same terms" asked six families to agree about an arm that runs on
   three; the arm-B control is now stated at the strength n = 3 carries —
   consistency, not significance. All before family two exists and before
   any pilot run.

11. **"Held out" made unambiguous before family one, on review's catch.** The
   re-scoped text said the held-out pair was "opened only for the final
   analysis," which permits a reading where the primary sign test runs on
   four families — and four cannot reach 0.05 at all (p = 0.0625). The
   intended design is now stated: all six families enter the battery and the
   primary test; held-out excludes only pilots and authoring-time knowledge.
   A stale "five held-out families" from the 20-family draft was corrected in
   the same pass. Exactly the class of ambiguity that becomes a post-hoc
   argument once results exist, which is why it is closed while there are
   none.

10. **Re-scoped to a build decision, not a publication.** 900 runs became 225,
   20 families became 6, and the test became a one-sided sign test at the size
   where significance is still reachable. The bill was never the constraint —
   900 runs is about $27 — the authoring was, and so was the drift: this
   project has already spent a phase perfecting a benchmark while the harness
   could not edit a file. What the smaller battery gives up is stated in the
   decision rule rather than discovered in the analysis: no small effects, no
   inferential transfer, and a split result is an answer rather than a reason
   to run more.

9. **The surface it demanded now exists**, chosen deliberately rather than by
   whichever wiring was easiest: five tools through which an agent mints,
   keeps and runs compiled capability of its own, in
   `src/daemon/capability.lisp`. Tools-as-components — the agent replacing its
   own `grep` or `edit` — is the stronger claim and the named follow-on;
   adding it later does not invalidate a result obtained here. Pre-check zero
   passes, and the gate is green end to end.
