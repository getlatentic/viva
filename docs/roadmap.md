# Vivarium — four capability levels

> **The architecture is frozen.** See [architecture.md](architecture.md): one
> long-lived SBCL organism, sessions as mailbox actors, a structured event model,
> JSON-RPC over local IPC with stdio as an adapter, and a Rust/Ratatui client.
> Self-modification is a property of a process that persists, not something
> bolted onto a command that does not.

**The mission, stated once:** build a general-purpose agent harness that can do
normal work, learn from that work, modify how it operates, retain useful
modifications, and eventually safely replace or undo parts of itself.

Experiments prove a capability. **They are not the project.** This document
exists because the project drifted into perfecting a six-account Lisp benchmark
while the harness still could not edit a file.

```
       +--------------------------+
       | 1. GENERAL AGENT HARNESS |   tasks, files, shell, tools,
       |                          |   memory, skills
       +------------+-------------+
                    |
       +------------v-------------+
       | 2. LIVE SELF-MODIFICATION|   change itself because the current
       |                          |   work demands it
       +------------+-------------+
                    |
       +------------v-------------+
       | 3. SELF-IMPROVEMENT      |   retain and generalise what improves
       |                          |   future work
       +------------+-------------+
                    |
       +------------v-------------+
       | 4. EVOLUTIONARY RUNTIME  |   components, replacement, rollback,
       |                          |   reconciliation
       +--------------------------+
```

## Level 1 — a capable ordinary harness. **Built.** See [level-1.md](level-1.md).

Vivarium had to first be useful the way Pi is useful: point it at real work and
it does the work.

```
image      read_definition, install, rollback, find_definitions,
           inspect_value, call_function        -- a live Lisp image
workspace  read, write, edit, ls, find, grep, bash, remember
           + skills, durable instructions, extensions, sessions
run as     a Lisp library, an interactive shell, or a JSONL IPC server
```

Replicated from Pi rather than invented, down to the tool names and the output
limits, so that comparing the two compares harnesses and not context budgets.

**Measured against Pi**, four fixtures whose failing test must actually pass
afterwards, three repeats, same model, same starting tree:

```
pi         12/12      8s/task
vivarium   12/12     10s/task     (the 2s is SBCL booting per `vivarium do`)
```

Parity is the whole point. Beating Pi on four fixtures would prove nothing;
failing to match it would have meant Level 1 was not real.

Level 1 is not self-improvement. It is the baseline organism, and it now exists.

## Phase 1.5 — compositional agency. **Built, through the proof.**

TASK is the unit of agency: one primitive, where a sub-agent is a task with a
scoped parent and spawned work is a task with a detached lifecycle. The
lifecycle was TLC-verified in `spec/TaskTree.tla` before the supervisor
existed, the table (`src/daemon/tasktree.lisp`) mirrors the spec through the
same `define-owner` as the session kernel, and the supervisor
(`src/daemon/supervisor.lisp`) wires its effects to real sub-agent threads.
`task.spawn` / `task.list` / `task.cancel` over RPC; task events on the
owning session's stream.

## Phase 2 — the evolution lifecycle. **Wired, through the proof.**

Versions are first-class function objects compiled in the running image;
components resolve through a task's activation context, never through
`symbol-function`; promotion, reversion, discard and inheritance are the
evolution owner performing `evolution-transition`, whose laws were
TLC-verified -- twice, the second time after independent review proved three
holes against the tagged model -- before any of this existed. The
`improvement.*` events, declared in the vocabulary long before anything could
emit them, are live on session streams and in the durable ledger.

**Kill criterion six is pre-registered.** `experiments/kc6/PROTOCOL.md` fixes
three arms, four pre-checks, the metrics and the decision rule before any model
runs. Two of its arms did not exist when it was written. Arm B needed a door in
the organism, so the door is a guard in the evolution table with
`ClosedDoorIsInert` proving that a closed run resolves nothing it creates, and
a witness proving that guard load-bearing. Its instrumentality check joined
activations to uses over a relation the ledger did not contain, so
`improvement.resolved` now records first use per task and version. Pre-checks
one and three run as one gate:

```
./experiments/kc6/preflight.sh
```

Then pre-check zero asked the question none of the others could, and answered
it no: **no model-visible tool reached the evolution owner, and nothing in
src/ resolved a component at all.** A workspace agent saw nine tools and the
proven lifecycle was a lifecycle for versions of things nobody called. So the
door has a model-facing surface now -- five tools in `src/daemon/capability.lisp`
through which an agent mints, keeps and runs compiled capability of its own,
where a capability is `(lambda (input) ...)`, one string in and one value out.
The arm is two switches, `--capabilities on|off` and `--door open|closed`.

Tools-as-components -- the agent replacing its own `grep` for its own task --
is the stronger claim and the named follow-on. It does not invalidate a result
obtained here.

**Re-scoped to a gate, deliberately.** 225 runs, 13.5M tokens, $6.65 at the
worst case where the cache never hits. Six families of five tasks, drawn from
frictions this repository's own development actually produced, because a build
decision needs a large effect and not a small one: paired by family with a
directional hypothesis, six families agreeing gives p = 0.016, and five is the
floor at which significance is reachable at all. Twenty families was buying
the power to detect a hair, and an architecture that wins by a hair has not
earned itself.

The bill was never the constraint -- 900 runs is about $27. The authoring was,
and so was the drift. **This document exists because the project drifted into
perfecting a benchmark while the harness could not edit a file, and a 100-task
battery with hidden tests is that same drift wearing a lab coat.**

### Against the mission, stated plainly

```
do normal work                      BUILT     Pi parity, level-1.md
learn from that work                PARTIAL   skills and memory exist; nothing
                                              decides when to write one --
                                              measured: 90 runs, two framings,
                                              zero spontaneous investment
                                              (experiments/kc6/RESULTS.md)
modify how it operates              BUILT     create/activate/call capability,
                                              live, proven, ledgered, and used
                                              by a real model
retain useful modifications         MECHANISM promote exists; the POLICY does
                                              not -- the agent must be told.
                                              Now data, not assumption: see
                                              the KC6 spontaneity null
safely replace or undo parts        PARTIAL   components revert; the organism's
                                              own tools are not components yet
```

Two of those five are the honest next work, and neither is more substrate.
**A retention policy** -- something that decides when a capability is worth
promoting, rather than a human saying so -- is the whole of Level 3 and the
gap between a mechanism and an organism. **Applying it to real work** is the
other: this harness has only ever been pointed at fixtures and benchmark
repos, and the mission says apply it to tasks. The KC6 families come from this
repository's own frictions for exactly that reason -- it is the first time the
organism is measured on work that actually happened.

## Level 2 — live self-modification, for the current task

The agent is working and finds its own capabilities inadequate, so it changes
itself and carries on.

```
WORK -> encounter friction -> modify self -> continue with the modified self
```

Human analogue: *"I have done this by hand three times, I am writing a script."*

Not only tools. A new helper, a new tool, debugging instrumentation, an index, a
procedure, a modified instruction, a change to the loop's own behaviour, a
different context strategy.

**Mechanism status: built, in both worlds.** In the image, `install_definition`
+ `call_function` do create-and-use and `register_tool` elevates a helper into
the model's own vocabulary. In the workspace, the `skillsmith` extension's
`write_skill` creates a skill and reloads resources in the same call, so it is
in the agent's own system prompt on the next request — demonstrated end to end
against a real model in [level-1.md](level-1.md).

The workspace version is the stronger form: its artifact outlives the process by
construction, so it is already half of Level 3.

F1 exists to answer **one narrow engineering question** and nothing more:

> Can an agent notice repeated friction during an ordinary task, create a
> helper, and use it immediately?

That is all F1 is for. It is not the benchmark the project is built around, and
once the mechanism is shown to work the answer is banked and the work moves on.

## Level 3 — self-improvement, for future tasks

```
experience -> reflection -> selection or generalisation -> persistent change
           -> fresh context -> changed future behaviour
```

Two ways in, and they need different machinery:

```
RETAIN   I built something useful while working. Keep it.
DISTIL   I built nothing, but I learned something worth encoding.
```

This is the point at which the phrase *self-improving agent* is earned — not
because the system can rewrite itself, but because **performance at t+1 depends
beneficially on experience at t**.

## Level 4 — reversible, compositional evolution

Accumulation creates a problem that does not exist before it:

```
version N works -> modification A -> B -> C -> performance deteriorates
which change caused it? can I remove only that one? what depended on it?
```

Then every self-modification has to be a component with identity, code, state,
dependencies, owned effects, provenance, evaluation history and an inverse. This
is where [B12's Cordis findings](cordis-probe.md), Smalltalk's live replacement
and vivarium's own selection and provenance fit together — **and it is later.**

## The object that replaces "skill vs tool vs prompt vs harness"

Those are implementation surfaces, and arguing about which one an improvement
*is* has already cost this project a full experiment design. The fundamental
object is the **improvement** itself:

```lisp
(improvement
  :kind       :procedure | :function | :tool | :memory | :harness-patch | ...
  :origin     episode-17
  :created-by :agent
  :scope      :repository
  :artifact   ...
  :evidence   ...
  :status     :active | :superseded | :retracted
  :depends-on ...
  :benefit    ...)
```

Which gives the evolutionary model directly, and makes Level 4 a natural
extension rather than a new architecture:

```
experience -> candidate improvement -> activate -> observe consequences
           -> retain / promote -> supersede -> retract

fork candidate A and B -> evaluate -> select -> promote winner -> roll back loser
```

## How the experiments are demoted

Three narrow checks are enough to exercise the architecture:

1. **Notice friction, build a helper, use it now.** — F1, level 2.
2. **Decide the helper is worth keeping, and benefit from it on another task.** —
   level 3, retention.
3. **Extract a procedural lesson from a task where nothing was built.** —
   level 3, distillation.

Then validation moves to **real work**: give vivarium a repository and a run of
tasks — debug failing tests, implement a feature, investigate a performance
problem, refactor a subsystem, debug another failure — and watch whether it
organically grows scripts, repo-specific helpers, inspection functions, search
utilities, skills, procedures, memory, tests and instrumentation.

The question that actually matters:

> **Is vivarium on task 20 measurably better adapted to this environment than
> vivarium on task 1?**

No synthetic Lisp puzzle answers that, and no amount of adversarial polish on one
makes it closer.

## What survives from the benchmark work

The adversarial discipline, which is now a permanent rule for any task claiming
to measure self-improvement:

> Enumerate the ways an agent could collapse the intended work into a cheaper
> path, and demonstrate experimentally that each unintended path is closed before
> running a model. Prove **reachability**, **non-collapse**, and
> **instrumentality** — the last by ablating the improvement and confirming the
> task result still stands.

Keep the discipline. Stop letting one task dictate the architecture.
