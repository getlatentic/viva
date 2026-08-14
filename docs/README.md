# Experiment index

Project overview is in [../HANDOFF.md](../HANDOFF.md). This file is the index and
the measured results.

Six separable experiments on one question: what does an agent harness gain when
the agent's world is a live Lisp image rather than a directory of files?

The substrate is [genera-lab](../../genera-lab) — an SBCL image an agent already
inspects, repairs and extends while it serves. `ledger.lisp` records every
mutation with its previous source, so rollback and replay-into-a-fresh-image
already work. What is missing is a scored loop on top.

Each experiment states one claim, the method that would settle it, and the result
that kills it. They are independent unless a dependency is named.

| # | experiment | claim under test | status |
|---|---|---|---|
| [E1](e1-trial-isolation.md) | trial isolation & cost | an isolated trial in a live image costs milliseconds, not seconds | **done — see below** |
| [E2](e2-archive-tree.md) | archive/frontier search | Pareto-frontier search over ledger entries beats greedy keep-best on equal budget | **claim 2 confirmed: greedy frozen at 10.1 at every budget, pareto reaches global 15.0 at 10× budget; claim 1 open** |
| [E3](e3-subturn-steering.md) | sub-turn steering | mutating a live agent object changes the *next request inside the running turn* | open |
| [E4](e4-self-editing-object.md) | self-editing agent object | an agent that edits its own CLOS object outperforms a fixed one | needs E1 + E3 |
| [E5](e5-single-tool-rlm.md) | single-tool RLM | one tool (`eval` a form in the image) beats a fixed tool schema | open |
| [E6](e6-harness-teardown.md) | production harness teardown | read how Codex and Claude Code actually assemble a request | partial |
| [harness](harness-lineage.md) | `vivarium` — Pi's loop ported, then diverged | shared substrate for E3–E5 | **arm A repairs a live image and extends itself; 40 tests green** |
| [B7](smalltalk-probe.md) | Smalltalk probe (spinoff) | Smalltalk is the better substrate for a live-image harness | **done — no execution-model reason left to reject it. A Pharo image forks and keeps serving: 475 forks, 0 failures, 0 requests lost, every child's image resumes mid-computation. Fork stalls are the same order of magnitude as SBCL's, not better or worse — both figures are small-sample and the in-image clock is entangled with the scheduler. What remains is source-level self-description (the ledger's job, now [B9](../backlog.toml)) and one unanswered question ([B10](../backlog.toml))** |
| [B10](b10-preregistration.md) | does live continuation improve outcomes? | resuming exact live computation beats reconstructing state from the ledger | **halted — not identifiable on this workload. Two rounds, two proxies mistaken for the property: run length, then a legible interaction. Any defect expressible in source is found by *reading*, and reading accumulates no search state worth losing. Reopen on a real task with expensive reproducible investigative state; the instrument is built and validated. See also — B7 proved the capability, not the benefit. Three arms: naive reconstruction → explicit durable cognition → captured computation, so a Smalltalk win cannot just mean the SBCL schema was too thin** |
| [B11](b11-preregistration.md) | context distillation | a distilled or ledger-only context beats carrying the full transcript | **done — compression works; the restart it requires does not pay for it. 34 pairs: dropping the transcript saves ~2,400 tokens, the restart it needs costs ~3,000, net +600 against simply continuing, with score flat throughout. The pre-registered middle-arm prediction is disconfirmed on 3 clauses of 4 — the distilled summary is *worse* than the transcript it replaces. And B10's observation was a property of family D: `LEDGER − FULL` is −2,229 where B10 measured it and +1,774 everywhere else** |
| [B12](../backlog.toml) | Cordis probe | reversible effects solve the half of self-evolution vivarium never modelled | **next. How an *accepted* mutation leaves the organism — the one lifecycle stage vivarium has no answer for, and the one B11 says nothing about. Four load-bearing cases: partial activation failure, dependency withdrawal, wrong inverse, plus clean unload and replacement as controls. Measure Cordis as it exists before layering reconciliation on it. Runs before B8, which it re-frames: execution containment vs effect containment** |
| [B8](../backlog.toml) | BEAM probe | supervision contains a bad mutation better than fork, and hot upgrade beats reconstruction | **queued behind B12. Third persistence philosophy: replace supervised members from durable state — the industrial existence proof of B10's arm A2, not a fourth arm. Still live: B11 did not show explicit state inadequate** |
| [B9](../backlog.toml) | mutation observability | every persistent self-modification produces evidence | **generalised out of B7 — the dangerous operation is unobserved state transition, not code generation. Independent of the B12 → B8 order** |
| [B13](../backlog.toml) | in-place compaction | the transcript can be compacted without rebuilding the agent | **filed, not sequenced. B11 coupled compression to restart through the *mechanism*, not by necessity. Predicts ~2,400 tokens saved with none of the +3,000 restart tax — or refutes B11's decomposition. Does not run before B12** |

## The substrate investigation, as three falsifiable questions

"What is the best language for a self-improving agent?" is not answerable and was
never asked here. The substrate work decomposes into three questions that each
have a kill criterion, plus a fourth primitive that outlives all of them:

| substrate | what it makes possible | the question |
|---|---|---|
| **SBCL** | code can become data | does homoiconicity reduce self-improvement impedance? |
| **Smalltalk** | *captured* computation can become durable | does preserving computation itself improve outcomes? |
| **BEAM** | processes can become disposable | if cognition is explicit state, does supervised evolution make the system safer or better? |
| **the ledger** | history can become authoritative | — it is not a competitor; all three runtimes need it |

Answered in dependency order rather than as a bake-off. [B7](smalltalk-probe.md)
asked whether computational capture *works* and found that it does.
[B10](b10-preregistration.md) asked whether it is *useful* and could not identify
the effect on this workload. [B11](b11-preregistration.md) then measured what
cognitive state should cross a version boundary at all, and its answer leaves the
substrate question exactly where it was: the ledger is authoritative, the
transcript is ephemeral working cognition, and runtime continuation was never an
arm — so Smalltalk still has no workload-level reason to migrate, and BEAM stays
live because explicit state has not been shown inadequate.

That is why the order is now [B12](../backlog.toml) → [B8](../backlog.toml).
B12 attacks a capability vivarium genuinely lacks — how a promoted change leaves
— rather than another representation hypothesis, and it re-frames B8 as effect
containment against execution containment. [B9](../backlog.toml) runs
independently of all of it.

## Prior art, settled

- [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — one editable
  file, 5-minute time-boxed trials, one scalar (val_bpb), keep-or-revert, git as
  history. Family A: single asset, hill-climb.
- [GEPA](https://arxiv.org/abs/2507.19457), [ADAS](https://arxiv.org/abs/2408.08435),
  [DGM](https://arxiv.org/abs/2505.22954), AlphaEvolve — Family B: population,
  archive, frontier. GEPA's finding matters here: always taking the best-scoring
  candidate sticks in a local optimum, so keep anything that wins on *at least one*
  instance.
- [prime-agent](https://www.primeintellect.ai/blog/prime-agent) — closest existing
  system. Persistent IPython kernel as the only tool; prompts, skills, memory and
  sub-agents are CRUD-able at runtime; `/refine` reads its own trajectory and
  applies the smallest edit. Base system prompt immutable, everything around it
  mutable, all changes written to disk so they survive turns.

prime-agent is the file-backed approximation of an image. It uses a persistent
kernel because that is the nearest thing Python has to one, then adds append-only
JSONL so harness edits survive a turn boundary — which is what `ledger.lisp` is.
The concept is not unclaimed. The substrate is.

## E1 result, which reshapes everything downstream

**SBCL 2.6.7 refuses to fork with more than one thread running.** Measured, not
inferred ([probes/fork-probe.lisp](probes/fork-probe.lisp)):

```
[stage1] threads=1  fork+work+reap=34.7ms  status=0  child: ok result=42
[stage2] threads=5  FORK REFUSED: Cannot fork with multiple threads running.
```

genera-lab serves over Hunchentoot and is permanently multi-threaded, so **the
serving image can never be the thing that forks.** A zygote is mandatory, not an
optimisation.

Cost per isolated trial, all on SBCL 2.6.7 / macOS ARM64, genera-lab loaded
([probes/zygote-probe.lisp](probes/zygote-probe.lisp)):

| path | per trial | isolation |
|---|---|---|
| cold `sbcl` + `quickload` | ~2,600 ms | full |
| saved core, fresh process | ~75 ms | full |
| zygote fork, sequential ×20 | 31.8 ms | full |
| zygote fork, parallel ×20 | 28.3 ms | full |
| in-process, no fork | 0.12 ms | none |

Two things to read off this.

**Parallel fan-out barely beats sequential** (28.3 vs 31.8 ms). Fork cost dominates
and does not parallelise — copy-on-write page-table setup over a ~100 MB heap on
macOS. Do not plan on wide fan-out being free.

**The gain is not "big experiments get faster", it is "small experiments become
viable."** Against a 100 ms benchmark, a cold-process loop spends 96% of wall-clock
on startup; the fork loop spends 22%; in-process spends 0.1%. Nothing here makes a
5-minute training run cheaper. What it does is let the trial *be* 100 ms — which
changes what you can search, not how fast you search it.

Do not compare these against autoresearch's 5-minute budget. That budget is the
experiment, not overhead; his startup cost is explicitly excluded and unstated.

## Bases and model runtime

**[Pi](https://github.com/badlogic/pi-mono) is the control arm, prime-agent is the
treatment.** Pi resolves extensions, skills, prompts and tool schemas at startup — it
*is* the "everything fixed before the run" condition prime-agent argues against — and
it is a strong, minimal, MIT-licensed baseline.

**Pi's loop gets ported to Lisp, not driven over RPC** — see [harness-lineage.md](harness-lineage.md)
for the measured scope (~1,500–2,300 lines, in `packages/agent`, not the 58k
`packages/coding-agent`) and for the one fidelity measurement that keeps a ported
control attributable.

**`llama-server`, not ollama**, for anything scored:

- seed and full sampler control per request — E1/E2 are worthless without
  reproducible trials
- GBNF / `json_schema` constraints — E5's single-tool arm needs well-formed
  s-expressions without a retry loop
- `-np N` parallel slots with continuous batching — E2's fan-out shares one weight
  copy; ollama queues
- slot-level prompt cache visibility (`--cache-reuse`, slot save/restore) — E3's
  third kill criterion is a cache measurement ollama's abstraction hides

`~/.llamabarn/gpt-oss-20b-mxfp4.gguf` is ready to serve. `devstral-small-2` is the
stronger coding model and lives as an ollama blob; llama.cpp reads GGUF by magic, so
the sha256 filename is fine to point at directly.

**Trust boundary on local models.** For "does harness B beat harness A", a local
model is fine held constant across arms — but watch for floor effects, where a model
too weak to use either harness shows no difference that is not evidence of none. For
"does this work at all", a local 20B measures the model, not the harness. Local for
high-volume low-stakes roles (E2 mutation proposals, judges); frontier for arms that
decide something.

## Architecture forced by E1

Three processes, not one:

- **serving image** — threaded, holds live sessions and real traffic. Mutated by
  `install`, exactly as genera-lab does today. Never forks.
- **zygote** — single-threaded, genera-lab and benchmark fixtures loaded, no
  threads ever spawned. Forks one child per trial. Children `_exit`; a child that
  wedges or corrupts its heap cannot touch the parent.
- **arena** — out-of-process, owns the archive, samples parents, promotes winning
  ledger entries into the serving image.

They share the ledger. A variant is a set of `(target, source, previous-source)`
entries — that is the genome, and the datatype already exists.

The consequence to accept: the zygote's warm state is loaded code and fixtures,
**not the serving image's live sessions**. Fixture-scored trials and live-traffic
scoring are now two different mechanisms, separated by a measured constraint rather
than by preference. Live-traffic scoring is the per-session CLOS variant path
genera-lab already has, not a fork.
