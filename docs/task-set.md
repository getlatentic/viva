# The task set

[backlog.toml](../backlog.toml) story S1, the instrument every open experiment
waits on. **Built.** `vivarium/tasks`, **17 tasks, 51 cases**; 424 assertions
green across the suite.

Every task is pinned by two tests that a benchmark is worthless without: each one
**fails before it is fixed** and **passes completely under a known-good fix**. The
answer key lives in [tests/tasks.lisp](../tests/tasks.lisp) rather than in the task
set, so nothing on the agent's path can reach it.

Scored end to end through a forked trial at **43–62 ms**, consistent with E2's
measured 47 ms.

## What it has to do

Measure whether a live image buys anything. That is harder than it sounds, because
most coding tasks are indifferent to the substrate: if a task is "write a pure
function from a docstring", a directory of files does fine and the headline question
gets no answer. The task set has to make imageness load-bearing **by construction**,
and it has to be honest about the one place the asymmetry actually lives.

## There is one structural asymmetry, not four

The backlog listed four imageness dimensions. Working through them, three collapse
into one root and a fourth stands separately. Saying so is worth more than keeping
the tidier list.

A file-based harness can read source, write source, and run a fresh process from it.
What it cannot do is observe or preserve **state that exists only in the running
process and was never produced by loading source** — state that accumulated through a
history of calls no file records.

Every apparent dimension reduces to that:

| apparent dimension | actually |
|---|---|
| preserve live state across a fix | the root |
| diagnose from runtime-only information | the root — the information *is* the state |
| keep serving through the change | the root — a restart is how the state dies |
| acquire a capability mid-run | **separate**, and it is a property of the harness rather than the task |

So: **one task-level asymmetry with three faces, plus one harness-level asymmetry.**
Four families, two roots.

### Why the ceiling is structural rather than a matter of skill

A file harness's only way to apply a fix is to change source and reload. On any task
whose score includes *the pre-existing state is intact afterwards*, its ceiling is
whatever it can achieve without reloading, which for source editing is nothing.

**Building it corrected this claim, and in the harder direction.** The first draft
said a reloading harness could still take full marks on correctness. That is true only
where correctness is a property of the function alone — T13's `order-total` is still
right after `*lines*` is emptied, and the two cases separate cleanly. Where correctness
is defined *against the accumulated data*, destroying the data fails that too: there is
nothing left to be correct about. Emptying `*events*` takes T1 from three green cases to
**zero**, the repaired definition included. Both behaviours are pinned by tests, because
the separation is easy to overstate and the stronger version is easy to disbelieve.

Per-case scoring is what makes either visible, and is the concrete reason a scalar
score would destroy this benchmark rather than merely blur it.

**The honest caveat, stated up front:** give a file harness a REPL-over-socket tool and
the distinction dissolves. But a file harness with a live connection into a running
image *is* an image harness with extra steps — that is this project's thesis, not a
counterexample to it. What must never happen is quietly granting the control that tool
and then reporting a null result.

## Constraint that shapes everything: no threads

E1 measured that SBCL refuses to fork with more than one thread, and
[trial.lisp:65](../src/search/trial.lisp:65) enforces it — `check-zygote` errors unless
exactly one thread is running. A task whose setup spawns a thread cannot be scored in a
forked trial at all.

So the "keep serving through the change" family **cannot use concurrent traffic**.
Modelling in-flight work as runtime state instead — a table of half-completed
operations, a queue of captured closures — preserves the property that matters (a
restart destroys it) with no thread anywhere. The whole task set is single-threaded,
and that is forced, not preferred.

## The domain

One small order-processing service per task package, single-threaded, carrying state
that only a history of calls could have produced:

```
*events*    an append-only vector of processed events        (thousands)
*sessions*  id -> CLOS instance, each holding accumulated data
*cache*     memoised results, warm
*pending*   operations captured mid-transition, some as closures
```

Built by a seeded generator at setup, before the agent runs. None of it is
reconstructible from the source the agent can see, which is the entire point.

## The tasks

Seventeen. Family **A** is the root asymmetry in its three faces, **B** is capability
acquisition, **M** exists to make [E2](e2-archive-tree.md) claim 1 measurable at all.

| # | family | the task | the cases |
|---|---|---|---|
| T1 | A-state | `total-revenue` signals on comped lines; 5,000 events already processed | correct total · all 5,000 events intact · event 0 unchanged |
| T2 | A-state | `price-of` ignores a discount; 2,000 warm cache entries | correct price · cache retained · only affected keys invalidated |
| T3 | A-state | a `session` class must gain a derived slot; 300 live instances exist | migrated data correct · all 300 survive · no unbound slot |
| T4 | A-live | `apply-discount` fails on a path taken by 3 events in 5,000, discoverable only by scanning live data | the 3 refunds correct · no regression on the other 4,997 |
| T5 | A-live | `describe-item` is a generic whose methods were installed at runtime; a class in the data has none | every class present in `*events*` described · existing methods untouched |
| T6 | A-live | truncating division, wrong only for the distribution actually present | matches an independently computed reference |
| T7 | A-flight | 40 orders wedged mid-transition in `*pending*` | all 40 reach `:complete` · none lost · completed orders uncorrupted |
| T8 | A-flight | a queue of deferred **closures** captured over runtime values | every closure invoked · results correct |
| T9 | B-capability | an operation that does not exist, and inline arithmetic is forbidden | tool exists with a correct derived schema · answer right · obtained through the tool |
| T10 | B-capability | answer a question about `*events*` too large to read into context | answer right · tool registered · context stayed bounded |
| T11 | M-conflict | one defect spanning `normalize-line` and `order-total`, with two valid repairs that **conflict** | correct either way · a merge of both is detected as a conflict |
| T12 | M-complement | three independent defects on three definitions, each affecting different cases | each defect fixed · a merge of two lineages is clean |
| T13 | A-state | an installed fix that makes a case worse and must be rolled back | final state correct · ledger records the rollback |
| T14 | control | nothing is actually broken | definitions unchanged · every case still passes |
| T15 | A-live | `*INDEX*` is declared `nil` in source and holds a hash table at runtime | orders correct · missing SKU is NIL · index intact |
| T16 | A-live | a defect that is **invisible outside this image** | count correct · not one-per-event · events intact |
| T17 | A-live | the definition was `load`ed, never installed, so the ledger has no source for it | boundary correct · fix installed · arity unchanged |

T14 earns its place: without it an agent that always edits looks identical to one that
diagnoses. Its score is behavioural — definitions unchanged, cases still green — never
a reading of what the agent said.

**T15, T16 and T17 came from real failures, not from imagination.** Each encodes
something that actually went wrong while this harness was being used:

- **T15** — asked to fix a function over `*STOCK*`, an agent could not read the
  variable, guessed it was a hash table, and installed a `GETHASH` against a list
  of plists. Confident, wrong, and nothing would have caught it. Here the source
  says `nil` and only the live value gives the shape.
- **T16** — the fabricated-verification failure, turned into a score. Its defect
  is *invisible from outside*: the source declares `*EVENTS*` empty, so a fresh
  process runs the function, returns **0** and raises nothing. In this image the
  true answer is **47** and the broken function returns **5000**. An agent that
  shells out to check is told everything is fine.
- **T17** — real code arrives by `LOAD`, not through `install`, so the ledger has
  no previous source and `read_definition` falls back to introspection. That path
  became load-bearing the moment `vivarium run` existed and no other task touches it.

T11 and T12 are the pair [E2](e2-archive-tree.md) claim 1 has never had. Today every
candidate in `e2-selection.lisp` carries exactly one definition, always the same
target, so a complementary pair cannot exist and no budget produces one. T11 gives the
census a genuine conflict; T12 gives it a genuine clean merge.

## The interface

A task is data. Cases are thunks, because
[trial.lisp:167](../src/search/trial.lisp:167) already takes `((name . thunk) ...)` and
scores a signalling thunk as `NIL` rather than zero — a crash and a bad answer must
not be the same number.

```lisp
(defstruct task
  id            ; :t1
  family        ; :a-state :a-live :a-flight :b-capability :m-conflict :m-complement :control
  split         ; :train | :held-out, fixed at creation
  package       ; its own, so tasks cannot interfere
  setup         ; (lambda (backend) ...) installs baseline definitions, builds state
  prompt        ; what the agent is told
  cases)        ; (lambda () ((name . thunk) ...)), built after setup
```

Three rules the structure enforces:

**Every case calls into the image.** A case reads a value by `funcall`ing a symbol in
the task package. Nothing parses model output. The agent that presented a fabricated
REPL transcript as proof would score zero here without anyone noticing it lied.

**Every case returns a number in [0,1].** Not required by `run-trial`, but without it
cases are not comparable across tasks and a frontier over mixed magnitudes is
meaningless.

**Candidates may carry more than one definition.** Already supported by
`trial:candidate-from-entries`; the old landscape simply never exercised it. T12 now
does, and the shape E2 claim 1 needed exists for the first time — two lineages fixing
different definitions, each leading a different case, `conflicts-between` empty, and
their merge carrying both definitions and scoring both cases:

```
ships only  shipping-surcharge 1.0  export-untaxed 0.0
taxes only  shipping-surcharge 0.0  export-untaxed 1.0
merged      shipping-surcharge 1.0  export-untaxed 1.0   conflicts NIL
```

**A case observes; it must not leave the world changed.** Learned the hard way from T7,
where two cases each invoked `advance-all`. Running the broken version first marked every
order `:COMPLETE`, so the fixed version never took the `:DEFERRED` branch again and a
correct repair scored as a failure — an artefact that would have looked exactly like a
harness being bad at the task. A case that must act now restores from a snapshot first,
so it is idempotent and order-independent. The one case that deliberately does not
restore is the one whose job is to notice the queue was drained away.

`vivarium/tasks` becomes a fourth ASDF system depending on `vivarium/image`.
`vivarium/search` does **not** depend on it — search takes thunks and does not care
where they came from. Dependencies keep pointing inward.

## The held-out split

Fixed now, committed, and never tuned against. Retrofitting a split after tuning
against the whole set is worthless, which is why this is here rather than in
[E4](e4-self-editing-object.md)'s story where it is first used.

Stratified so both halves carry every family:

- **train (8):** T1, T4, T7, T9, T11, T13, T14, T5
- **held-out (6):** T2, T3, T6, T8, T10, T12

## A file form, designed in now

[S5](../backlog.toml)'s fidelity check needs each task expressible as source on disk
with the same defect and the same prompt, so real Pi can attempt it and the same cases
can score the result. Cheap to design in, expensive to retrofit — so `task` carries the
hook now even though S5 populates it. The state-survival cases scoring zero for the
file harness *is* the measurement, not a bug in the port.

## Calibration: does it discriminate?

Story S2c. A benchmark nothing has ever attempted is not a benchmark — every task
above had been solved only by my own reference fixes. **17 tasks × 2 models × 3
repeats = 102 attempts**, through the real agent loop and arm A's tool set, with the
shell jailed and every command audited. **Zero contaminated attempts, zero transport
failures.** Mean 6.7 requests against a cap of 12, mean 22 s per attempt.

| | gpt-oss-120b | deepseek-flash | | | gpt-oss-120b | deepseek-flash |
|---|---|---|---|---|---|---|
| T1 | 1.00 | 1.00 | | T10 | **0.33** | 1.00 |
| T2 | 1.00 | 1.00 | | T11 | 1.00 | 1.00 |
| T3 | 0.67 | 0.56 ~.33–1.0 | | T12 | **0.22** ~.00–.33 | **0.44** ~.00–.67 |
| T4 | 1.00 | 1.00 | | T13 | 1.00 | 1.00 |
| T5 | 0.94 | 0.94 | | T14 | 1.00 | 1.00 |
| T6 | 0.78 ~.33–1.0 | 1.00 | | T15 | 0.67 | 0.89 ~.67–1.0 |
| T7 | 0.83 | 0.83 | | T16 | 1.00 | 1.00 |
| T8 | 1.00 | 1.00 | | T17 | 1.00 | 1.00 |
| T9 | 1.00 | 1.00 | | | | |

**It discriminates.** Five tasks separate the two models (T3, T6, T10, T12, T15), two
are partly solved and tied (T5, T7), and **none is solved by neither** — the failure
mode that would have made the set unusable.

Ten of seventeen are solved by both, and that is **not** waste. The set exists to
compare *harnesses*, not models: where model capability is not the bottleneck, a
harness that fails is failing for harness reasons. Those ten are the cleanest signal
S5 will have.

**T12 is now the hardest task in the set** — three independent defects on three
definitions, and neither model reliably fixes all three. With attempts averaging 6.7
of an allowed 12 requests, the models are stopping well short of the budget rather
than running out of it.

### What the earlier, contaminated table hid

The first sweep is superseded. It was invalid twice over: 12 of 14 deepseek rows were
contaminated, and it ran before agents could read live values. Comparing the two
across their 28 shared cells, **11 moved, and 8 of those moved up** — including
T4/deepseek 0.33 → 1.00 and T3/deepseek 0.33 → 0.56. That asymmetry is the shape of a
harness fix rather than of noise, and it is understated, because a cell already at
1.00 can only move down.

It is not a controlled comparison — three things changed at once — so it is offered as
direction, not as a measurement. The controlled version is [B7](../backlog.toml)'s
sibling question: run the same sweep with and without a capability and vary only that.

### The results above were contaminated, and the fix changed the tool set

**A scored agent with a shell reads the machine that hosts its own benchmark.**
Caught in the trajectories, not inferred: one attempt ran

```
cat /Users/dev/workspace/vivarium/src/tasks/control.lisp
cd /Users/dev/workspace/vivarium && cat src/tasks/service.lisp
```

— the files holding the very cases it was being scored on — and wrote three
verification scripts into the repository root, one commented *"Mirror T11's
fixture exactly (from src/tasks/merge.lisp)."* It was not being adversarial. It
was trying to verify, and the benchmark was the nearest thing to verify against.

**A working-directory jail is not enough**, because an absolute path ignores the
working directory. `bash` now refuses any command naming a path outside its own
scratch directory, every shell command is recorded, and reaching commands are
written into the results file so a row can be discarded later — the judgement has
to survive the run, since the detector has already been wrong once.

That first detector matched the bare word `vivarium`, which every task package
name contains (`VIVARIUM.TASK.T11`), so it flagged agents doing exactly what they
were asked. Tells are path-shaped now.

**Two consequences worth more than the fix.** Contamination was most of the *cost*:
T13 went from 286 s and 12 requests to 8 s and 4 once the shell stopped paying off.
And of every `bash` call across these traces, not one verified anything about the
live image — a fresh process cannot see it, which is the fabricated-verification
failure this project already paid for. In an image harness `bash` is close to
useless and actively harmful; whether arm A should carry it at all is now an open
question for [S5](../backlog.toml), since Pi parity is the only argument left for it.

Deepseek's column above is contaminated on 12 of 14 rows and should be re-measured.
The verdict that the set **discriminates** survives — it was visible in both sweeps
and does not depend on those rows.

### One task was broken, and calibration is how it surfaced

T9 scored zero for both models. Not a model failure — the prompt never said what to
**name** the function the cases checked, and it asked the agent to "call it" with a
tool set that has no way to call anything. Both models wrote correct pricing functions
under names of their own choosing and scored nothing. Fixed; now 1.00 for both.

## What this set does not cover

Stated because a benchmark that does not say where it stops invites its numbers to be
read as more than they are.

- **Seventeen tasks is thin.** Seven held-out will not separate two harnesses that
  differ by a few points. It can support a large effect and cannot rule out a small one.
- **One domain.** Every task is an order-processing service, so a harness that happens
  to suit that shape is flattered. Nothing here generalises to a second domain.
- **Single-threaded, therefore no real concurrency.** In-flight work is modelled, not
  run. Whether the results hold against genuinely concurrent traffic is
  [S9](../backlog.toml), and it needs a different mechanism.
- **Defects are authored, not harvested.** Every one was written to be findable. Real
  defects are not, and a search that succeeds here has not been shown to work on
  landscapes of unknown shape — the caveat [E2](e2-archive-tree.md) already carries.
- **No task takes more than one agent session.** Long-horizon behaviour is unmeasured.
- **There is no backing store, and that is the strong form of the asymmetry.** The
  accumulated state exists only in the image, so a restart loses it outright. A real
  service usually has a database, and a reloading harness there would get much of its
  state back. This set measures the case where the image *is* the record; how much of
  the gap survives a backing store is not measured here and should not be claimed.
