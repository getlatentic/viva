# Vivarium: a manifesto

Vivarium is a living organism for doing work. It runs as one long-lived
Common Lisp image that never needs to be turned off, does normal tasks,
learns from them, and modifies how it operates through one proven door,
keeping what earns its place and shedding what does not.

This document is the alignment point. Everything in it is either proven,
tested, or named as open, and it says which.

## The mission

> Build a general-purpose agent harness that can do normal work, learn from
> that work, modify how it operates, retain useful modifications, and
> eventually safely replace or undo parts of itself.

Stated once, in the roadmap, and quoted from there verbatim — an earlier
draft of this document carried a grander sentence that appears nowhere in the
record, and a manifesto that opens by quoting itself has already broken its
own rule.

Measured against itself, plainly:

```
do normal work                 BUILT      Pi parity, 12/12 fixtures
learn from that work           PARTIAL    skills and memory exist; nothing
                                          decides when to write one
modify how it operates         BUILT      mint, activate, run capability:
                                          live, proven, ledgered, and used
                                          by a real model
retain useful modifications    MECHANISM  promote exists; the POLICY does
                                          not, the agent must be told
safely replace or undo parts   PARTIAL    components revert; RECONCILE is
                                          open, and the organism's own
                                          tools are not components yet
```

## The ladder

Four capability levels, and where the spine's tags sit on them:

```
1  GENERAL AGENT HARNESS     built    phase1-substrate, kernel-v1
2  LIVE SELF-MODIFICATION    built    tasktree-v1, evolution-v1,
                                      the capability door
3  SELF-IMPROVEMENT          open     the retention policy: something
                                      that decides what is worth keeping
4  EVOLUTIONARY RUNTIME      later    everything a component, replaceable,
                                      reversible, reconciled
```

Experiments prove a capability; they are not the project. This ladder exists
because the project once drifted into perfecting a benchmark while the
harness could not edit a file, and the rule that came out of that is
permanent: the mission says apply it to real work.

## What Vivarium is not

It began Pi-like: a harness around a model, a loop, some tools. It is past
that now, and two boundaries keep it honest in the other direction.

It is not an orchestration framework. The concurrency kernel is deliberately
narrow: one organism, dozens of task agents, one supervisor, one journal
owner, one evolution owner, bounded mailboxes, explicit state machines, no
distribution. The moment it grows links, monitors, registries, clustering, or
fairness scheduling, it has become OTP rewritten in Lisp, and the kill
criteria fire.

It is not unconditional. Six kill criteria stand, and the decisive one is
number six: if live self-modification produces no measurable gain over
external skills and tools, SBCL loses its main justification and the
architecture question reopens. The experiment for that is pre-registered,
re-scoped to a build decision rather than a publication, and is the next
gate.

## The organism

The engine is a daemon holding a live SBCL image. Interfaces are subscribers,
never owners: clients attach — the CLI, the IPC, whatever speaks the protocol
next — and each sees the same sessions, the same event streams, the same task
tree.
Detach and the organism continues; reattach tomorrow and the history is
there, journaled and replayable with exactness that is proven, not assumed.
It is an operating system for work in the precise sense that turning it off
is an event, not a routine.

The organism is placeless; work happens at named sites. **This is ratified
design, not yet mechanism**: today a task inherits one working root whole,
and capabilities pin to the task, not to a place. The contract new work
builds to is the explicit attachment list — a task pointed at one folder or
several, its working set exactly the list it was given, never ambient
inheritance, so pointing a task somewhere is a grant and the grant dies with
the task. Siblings with different attachments are isolated by construction.
It enters through the door after the gate, like everything else.

## Agency: tasks, agents, and how they talk

The mapping is one primitive deep. A **task** is the unit of agency. An
**agent** is the worker loop serving a task's turns. A **sub-agent** is
nothing special: a task with a scoped parent. **Spawned independent work** is
nothing special either: a task with a detached lifecycle. One primitive,
two lifetime modes, and the tree's proven laws do the rest.

Communication, as it exists today, runs on four channels, each with an owner:

**Streams** are the broadcast channel. Every task publishes to its owning
session's stream; a subscriber that keeps draining observes everything, in
the journal's order, exactly once — proven at the replay barrier. Inboxes are
bounded, so a subscriber that stops draining is dropped, and the drop is
announced rather than silent. Degradation is a state, never a secret.

**Steering** is the channel into a running turn: text queued to the current
turn, read at the agent's next checkpoint. Clients steer; nothing prevents an
agent holding the right handle from steering a sibling, which makes it the
primitive that richer collaboration will be built from.

**Delegation** is the request channel: `delegate` blocks on a scoped child's
answer, `delegate-async` returns an operation instead. Parent asks, child
answers, the tree owns both lifetimes.

**Inheritance** is the capability channel: a child is born holding its
parent's activation pins, registry-visible, before its worker exists.

Multiple agents on one goal is already expressible without new machinery: a
parent task holds the site grants, its collaborators are scoped children
sharing the parent's attachments and stream, and the drain law guarantees the
parent cannot claim completion while any collaborator still works. What stays
single-writer is authority: one task, one owner of its turns, always.
Collaboration shares sites and streams, never authority.

What does not yet exist, and enters through the door before it is wired:
**peer messaging**, agent to agent, sub-agent to sub-agent, child back to
parent mid-turn. Its laws are already writable: a send names the tree-minted
identities of both ends, delivery happens only between live tasks and is
refused with a reason otherwise, payloads are immutable, every inbox is
bounded with a declared overflow action, and terminal tasks receive nothing.
That is a TaskTree v2 specification first, TLC second, table third, wiring
last, like every feature since the rule was made.

## The machines

The proven core is five state machines, at three exact strengths, said
per machine. The cell, the task, and the version carry TLC mirrors they
cannot drift from. The journal is a checked table whose one law is enforced
by identity rather than modeled. The component lifecycle is adopted contract,
its last stage still open. Every shipped machine is a pure transition
function generated from one declaration.

**The cell**, one session's lifecycle:

```
idle -> working(turn, queued) -> idle
working -> suspended -> working
working -> stopping(turn) -> flushing -> completed
stopping -> stuck                          deadline expired, stays registered
```

Its laws: one terminal event per turn; a stale completion changes nothing;
completion is proven durable before the session leaves the registry; stuck is
a state, not a hang.

**The task**, one unit of agency:

```
running -> cancelling -> draining(pending) -> completed | failed | cancelled
running -> draining(pending) -> terminal
```

Its laws: a parent's outcome parks in draining until its last scoped child
resolves; one parent forever; cancel propagates across scoped edges only, one
delivery at a time; fan-out is bounded and refused past the bound; a detached
child outlives completion and survives cancellation, both witnessed.

**The version**, one unit of self-modification, behind the door:

```
none -> candidate -> promoted -> retired      lineage moves forward
                  -> discarded                never promoted, nobody pinned
promoted -> retired, predecessor -> promoted  reversion, lineage steps back

task lifetime: unborn -> live -> ended        pins exist only inside it
door: a CONSTANT guarding activate and promote
```

Its laws: at most one promoted version per component; an unpromoted candidate
reaches a task only through that task's own pin; no live task resolves to a
discarded version; pins die with their task and inherit at spawn,
registry-visibly; a closed door is inert, and the guard is witnessed
load-bearing.

**The journal**, durability's owner:

```
available(gen) -> restarting(gen+1) -> available(gen+1)
```

Its law: a predecessor's late death touches nothing, because cleanup names
the generation it cleans.

**The component**, the Cordis clause. From Cordis, Vivarium adopts the
contract and rejects the comfort: every effect a component installs is paired
with its co-effect, the inverse that removes it, and unloading means running
the co-effects. The library itself was probed and declined, because it
reports a clean unload for every failure mode an agent-authored component
actually has, and reporting is not reconciling.

```
PROPOSE -> ISOLATE -> EVALUATE -> PROMOTE -> ACTIVATE -> OPERATE
        -> RETRACT -> DEACTIVATE -> RECONCILE

shipped:  everything left of RECONCILE
open:     RECONCILE, repairing what a reverted version already did
```

## Self-modification: the one door

Versions are first-class function objects, compiled inside the running image.
Every change passes through the evolution owner, and the vocabulary is law
because the machine enforces the distinctions: **activate** for this task
alone, **promote** for everyone durably, **revert** the lineage for everyone
touching no pin, **discard** what never earned promotion, refused while
anyone still runs it.

The door has a model-facing surface now: five small tools through which an
agent mints, activates, and runs compiled capability of its own, where a
capability is one function, one string in, one value out. A real model has
walked through it: wrote a converter, compiled it into the live image,
activated it for its own task, ran it three times correctly, for half a cent.
With the door closed, the same model created, was refused, did not thrash,
and fell back to ordinary tools, which is exactly what arm B exists to
measure.

Call sites reach components only through the activation context. Reaching
through `symbol-function` is promotion through the back door, and the suite
attacks that door to keep it shut.

## The proof discipline

The safety claim has three layers, and the claim is only ever made one layer
at a time.

**Proven.** Five machines, four TLC specifications, thirteen configurations
re-proven by one command, `spec/verify.sh`. Six of the thirteen are witnesses
expected to violate, and the runner fails if they stop violating, because a
witness that quietly goes green has stopped being evidence. The rule that a
race test must be able to lose, applied to the layer that claims to be
proven.

**Pinned.** Tables cannot drift from specs because they are one object;
coordinators cannot drift from tables because every attack breaks exactly one
law and is caught by exactly its guard.

**Contained.** Wiring is covered by the suite, attacks, and churn plateaus,
and this layer is where every integration bug has ever lived, across the
whole record, with not one touching a proven table. Instruments are code and
get the same adversarial treatment, a lesson bought twice.

The door rule: a feature enters through the proof or it does not enter. The
stopping rule: a concern blocks only with a TLC counterexample or a runtime
reproduction; an observed incident blocks until reproduction is honestly
exhausted, then routes with its evidence and a permanent tripwire.

## The spine

```
phase1-substrate   the lifecycle is exact and flat under churn
kernel-v1          the decisions are one checked object
tasktree-v1        agency is compositional; first feature born in the proof
evolution-v1       self-modification through one proven door, durably
```

State as of this writing: 1,216 tests green, thirteen spec configurations
agreeing, preflight green as one gate, churn plateau at 68,381 cycles with
flat heap, threads, and descriptors, and the first real-model runs anchored
in the ledger. Specs and self-tests re-verify on an independent machine;
suite counts, churn figures, and model runs are the organism's own reports.

## The seams

Cross-owner protocols get mechanisms, not conventions: inheritance is
registry-visible, ordering rides single-sender FIFO, replies leave the owner
after all effects, not from inside one. And hand-threaded context is where
fields vanish: `extra-tools` is hand-threaded at three constructor seams and
was lost at two of them in a single day — the CLI arming no tools while
direct construction worked, a worker unable to use the pins the proven table
faithfully copied to it. Both seams are pinned by tests now. The rule stands
armed, exactly at its letter: a third loss means the structural fix is
mandatory — one context object threaded whole, never a fourth manual line.

## What remains

The living tracker is `docs/BACKLOG.md` — lanes mirror this section's
sequencing, and moving an item between lanes is a decision with a commit.

**KC6, the gate.** Six families of five tasks drawn from frictions this
repository's own development actually produced, 225 runs, three arms,
thresholds raised to build-decision size: a 30 percent token reduction or a
0.20 solve-rate gain, because an architecture that wins by a hair has not
earned itself. Tens of dollars, authored in days, decided once.

**The retention policy, Level 3.** Promote is a mechanism; nothing decides
when a capability deserves it. That decision is the whole distance between a
mechanism and an organism, and it is the next artifact after the gate,
whichever way the gate goes: if capabilities win, the policy governs
capabilities; if they lose, it governs skills.

**RECONCILE.** The one substrate item permitted through the door meanwhile,
because it is a mission clause: a co-effect ledger and compensation
semantics, specified and checked before wired.

**Tools as components** is the stronger claim and stays sequenced behind the
gate's result.

Everything else waits, because the correct goal was never a perfect
substrate or an impressive framework. It is a long-lived organism with narrow
ownership, explicit identity, recoverable failure, observable degradation,
one door for changing itself, and the evidence that walking through that door
makes it better at the work.
