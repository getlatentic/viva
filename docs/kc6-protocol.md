# KC6: does live self-modification earn the architecture?

> **This is the origin draft, kept for the record. The live protocol is
> `experiments/kc6/PROTOCOL.md`**, which carries seven amendments found by
> verifying this one against the machinery it presupposes -- two of them
> structural, since arm B had no mechanism and pre-check three was computing a
> join over a relation the ledger did not contain. The amendments are listed
> at the end of that file. Nothing here has been edited.

Pre-registered protocol. Written before any run; thresholds set before any
data; changes after first data are amendments, logged, never silent edits.
The question this decides, from the project's own kill criterion six: if live
Lisp self-modification produces no measurable gain over external skills and
tools, SBCL loses its main justification.

## Hypothesis

An agent that can create, activate, and promote component versions through
the evolution owner during its own tasks completes recurring-friction task
families with a better learning curve and lower cost than the same agent with
the door closed, and than the same agent using externalized skills instead.

## Arms

Arm A, organism: evolution enabled through the one door. The agent may
create-candidate, activate for its task, promote after evidence, exactly the
machinery evolution-v1 shipped.

Arm B, frozen: identical organism, door closed (activate and promote refuse,
by configuration, with the refusal published). Isolates the door's overhead:
A must beat B or the machinery is pure tax.

Arm C, external skills: no live compile. The agent may write and read
persistent text artifacts (skills, notes, snippets) between tasks in a family.
This is the criterion's named competitor and the arm that decides the kill:
external skills are what any framework offers without a live image.

All arms share the base model, pinned to one provider version, same harness,
same budgets, temperature and seeds fixed per run. Capability descriptions in
the system prompt are matched in length and specificity across arms so the
door's description cannot act as a free hint.

## Task battery

Families of sequential tasks sharing a friction, where a retained abstraction
plausibly pays: structured-output reshaping against a quirky format, repo
navigation with a recurring pattern, tool-output parsing variants, protocol
dialects. Within a family, tasks run in order so retention can matter. A
held-out set of families measures transfer of promoted defaults. Tasks are
graded by hidden tests, never by a judge who can see improvement.* events.

Scale, fixed now: 20 families x 5 tasks x 3 arms x 3 seeds. Cost cap stated
before the first run; if the cap forces a cut, families are dropped whole,
by pre-shuffled order, never by results.

## The three pre-checks, before a model runs

Reachability: a scripted agent, no LLM, traverses create, activate, resolve,
inherit, promote, revert through the real wire, and the ledger shows the
whole genealogy. This is the wiring's existing test, re-run as preflight.

Non-collapse: arm A driven by a never-evolve policy matches arm B within
noise on a pilot slice. Proves the machinery's presence alone does not tax
outcomes beyond a stated latency budget.

Instrumentality: in arm A pilots, versions the agent creates are actually
resolved by later turns, measured by joining improvement.activated to
subsequent component resolutions in the ledger. If created versions are never
used, the experiment would measure prompt placebo, not machinery, and must
not proceed until the harness makes use reachable.

## Metrics, pre-registered

Primary: success rate by family position (the learning-curve slope from task
1 to task 5), and cost per solved task in tokens and wall clock.

Secondary: reuse rate of retained versions across a family, transfer success
on held-out families resolving promoted defaults, revert rate, regression
count (a promotion that lowers later-task success), variance across seeds.

## Decision rule, set now

Keep the architecture if A beats C on the primary metrics on held-out
families with a pre-chosen effect size, and A beats B, both at the
pre-registered significance threshold. Kill criterion six fires if A fails to
beat C after the full battery: the honest conclusion is that external skills
capture the value without the live image, and the roadmap's Elixir/external
question reopens. One ambiguous zone is allowed: if effects are positive but
under threshold, run one pre-sized extension, then decide. No second
extension; that is the infinite refinement loop wearing a lab coat.

## Threats and their mechanisms

Prompt leakage between arms: matched capability text, reviewed side by side
before run one. Overfit versions: held-out families are the check that a
promoted default is an abstraction, not a memorized answer. Metric gaming:
hidden tests grade outcomes; the agent never sees graders. Provider drift:
model version pinned; any forced migration restarts the affected seeds.
Analysis drift: every run journals to the ledger, and the analysis is a
program over the ledger, reconstructible the way lineage already is.

## Artifacts

experiments/kc6/PROTOCOL.md, this file, committed before run one.
experiments/kc6/results/ holding one journal per run and the analysis
program. A RESULTS.md whose verdict section quotes the decision rule verbatim
and fills in only the numbers.
