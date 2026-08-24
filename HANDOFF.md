# Handoff

Everything needed to pick this up cold: what it is for, what has been settled,
what has not, and the mistakes already paid for.

## The question

**What does an agent harness gain when the agent's world is a running image rather
than a directory of files?**

Every self-improving agent system in the literature edits source files and uses git
as its memory. That is a historical accident: the Lisp and Smalltalk people had live
images and drove them by hand, while the agent community grew up around GitHub. The
two traditions never met. This project is the meeting.

Not a thesis to defend — a question with six falsifiable answers attached. Several
early claims have already been narrowed or retracted by measurement, and the notes
say so.

## What is real, and what it does

`~/workspace/viva` — 424 tests green, SBCL 2.6.7 / macOS ARM64. Five ASDF
systems with dependencies pointing inward:

| system | what it is |
|---|---|
| `viva` | the harness: messages, tools, schemas, agent, loop, providers |
| `viva/image` | one task domain: a live Lisp image to read, change and undo |
| `viva/tasks` | the benchmark: 17 tasks, their fixtures, and the cases that score them |
| `viva/search` | forked scored trials, an archive, selection over it |
| `viva/cli` | `bin/viva` — one entry point for every run |

The split is tested, not aspirational: `(ql:quickload :viva)` leaves
`VIVA.IMAGE` and `VIVA.TRIAL` absent from the world.

Two things it does end to end against a local model, both verified by behaviour
rather than by what the agent claimed:

- **repairs a live definition** — `(order-total *lines*)` went from signalling a
  TYPE-ERROR to returning 35, checked by calling the function in-process;
- **extends itself mid-run** — wrote a function, installed it, registered it as a
  tool whose schema was read off the live function, and called it. Seven tools to
  eight in four requests, nothing restarted.

## The six experiments

Each states one claim, and the result that kills it. They are independent unless a
dependency is named. Full detail in [docs/](docs/).

### E1 — trial isolation and cost · **settled**

*An isolated trial in a live image costs milliseconds, not seconds.*

Holds, and it dictated the architecture. **SBCL refuses to fork with more than one
thread running**, so the process that forks trials can never be the one serving
traffic — a zygote is mandatory. Cost per isolated trial: fork 28–32 ms, saved core
75 ms, cold start 2,600 ms, in-process 0.12 ms.

The honest reading is not "experiments get faster". It is that **a 100 ms experiment
becomes viable at all** — which changes what you can search, not how fast you search
it. Parallel fan-out barely beats sequential, so wide fan-out is not free.

### E2 — archive and frontier search · **claim 2 settled, claim 1 open**

*(1) Merging is free because a variant is a set of ledger entries. (2) A Pareto
frontier beats greedy keep-best.*

Claim 2 holds, in a narrower form than first reported. Budget sweep, no model
involved, same start and proposer for both arms:

| budget | 60 | 150 | 300 | 600 |
|---|---|---|---|---|
| greedy best n | 12 | 12 | 12 | 12 |
| pareto best n | 20 | 28 | 34 | **40** |

Greedy is frozen at every budget. Pareto advances monotonically and reaches the
global optimum at 600. So: **the frontier converts a hard trap into a budget
question, at a measured 10× price.** Not "Pareto wins at equal budget".

Claim 1 has its machinery built and tested but no verdict: with the corrected
frontier the two-dial search converges before complementary specialists appear, so
the conflict census has no pairs to count. Needs a landscape where two lineages
genuinely specialise.

**Kills it:** frontier and greedy within noise on a real benchmark at a budget
anyone would pay; or two winners routinely touching the same definition with neither
body subsuming the other.

### E3 — capability injection · **mechanism demonstrated, effect open**

*Mutating a live agent object changes what the agent can do on its next request.*

The claim has narrowed **three times** under evidence. Pi already polls steering at
the end of every inner iteration, so "content steering below the turn boundary" was
never unclaimed. Then opencode turned out to rebuild *both* prompt and tool set on
every request, with a plugin hook existing purely to rewrite the prompt — so
"startup-resolved" describes Pi and Codex, not every harness.

What survives, and it is sharper: **no harness lets an agent acquire a capability that
did not exist at startup.** opencode's `resolveTools` is a filter that never adds;
Claude Code's `mcp_toggle` gates a pre-registered server. Both re-evaluate *which* of a
known set is live. Installing a `DEFUN` and deriving a tool from the resulting function
is the tier none of them reach, and it is tested here.

Streaming then added a tier neither has: **abort in flight**. Measured on one prompt,
`ABORTED after 1,927 ms / 0 deltas` against `STOP after 323,875 ms / 1,352 deltas`.

What remains is the actual experiment: does any of it **improve outcomes**?

**Kills it:** mid-run prompt mutation produces incoherent trajectories; or prompt
caching penalises a changed prefix badly enough to erase the gain.

### E4 — self-editing agent object · **needs E1 + E3**

*An agent that edits its own CLOS object outperforms a fixed one.*

`register_tool` and `remember` exist and work. The base prompt and base tools are
deliberately out of reach — prime-agent's immutable floor, so a self-edit that breaks
the editor stays recoverable.

Do the object level first. Scoring one meta-change means running a whole object-level
campaign, so this is only affordable once E2's score is cheap and trusted.

**Kills it:** self-edits improve the training set and lose the held-out set; or the
agent converges on editing its own scorer rather than its competence.

### E5 — one tool instead of five · **wire format built, comparison open**

*Replacing a fixed tool schema with a single `eval` tool beats the hand-designed set.*

The Lisp-native shape is built: a tool call is a function call and its schema is a
lambda list, with a GBNF generated from it so s-expressions get the structural
guarantee JSON gets automatically. Three findings, one against the case:

- the escaping tax is **real but small** — +3.6%, six escapes on a definition;
- a custom grammar must live **inside** the model's own output protocol, or the
  server rejects its own model's output;
- grammar-constrained s-expressions work, but **the model's Lisp was worse than its
  JSON-arm Lisp**. That is the likeliest way this arm loses.

**Kills it:** that Lisp-quality gap, measured on its own before building arm B; or
free-form eval making trajectories unauditable.

### E6 — production harness teardown · **largely answered**

Not a build, a read, with one question: **what is fixed at turn start versus re-read
per request.** Answered for Codex and Pi from source, and for Claude Code from its
control protocol — which is open source in the Agent SDK and again in the desktop
app's Electron bundle, so the Bun-compiled CLI never had to be reverse-engineered.

Every control request a running Claude Code session accepts: `initialize, interrupt,
stop_task, set_model, set_permission_mode, rewind_files, mcp_toggle, mcp_status,
mcp_reconnect, get_context_usage`. **No `set_system_prompt`, no `set_tools`.** The
model can change mid-session; the prompt cannot. `mcp_toggle` is `(serverName,
enabled)` — a *pre-registered* server on or off — so the tool list can move without a
new tool ever being introduced. That is the exact line E3 claims to cross.

opencode was the last one read, and it moved the answer — see E3. Its turn loop
(`prompt.ts:1088`) re-resolves the tool set every iteration and rebuilds the system
prompt on every request. But `resolveTools` is `Record.filter`: it removes what
permission disabled and never adds.

## An unresolved choice, stated rather than implied

The question at the top presupposes an answer it never argued for. Three runtimes
support live change, and each encodes a **different definition of self-improvement**:

| | the agent is | strongest at |
|---|---|---|
| **SBCL** | a program that rewrites programs | code is data, so generating and installing a definition has almost no impedance |
| **Smalltalk** | a computational organism that persists | snapshot resumes mid-computation; stacks are objects |
| **BEAM** | a society that survives by replacing members | a bad mutation dies and is supervised away, and two module versions run at once |

"What does a harness gain when the agent's world is a running image" quietly assumes
the first two. **Erlang's framing is not another implementation of that question; it is
a different question** — and one whose failure mode ("a component will eventually emit
bad code") is arguably the one self-improvement actually has.

This has never been chosen explicitly. Two probes exist to inform it —
[B7](backlog.toml) on Pharo, [B8](backlog.toml) on BEAM — both deliberately scoped as
property probes rather than task-set ports, because the task set is Lisp-specific by
construction and porting it would compare two benchmarks while calling the result a
substrate comparison.

The asymmetry to weigh when they report: supervision, isolation, restart and
versioning are **patterns** — this project already has fork isolation, a ledger and
rollback. Homoiconicity is not obtainable as a library. And fork's containment is
stronger than it looks: BEAM's process isolation is intra-VM, so a mutation that wrecks
the runtime takes the node, whereas E1's forked child cannot touch its parent by
construction.

## What is settled, so nobody re-researches it

- **autoresearch** (Karpathy) — one editable file, 5-minute trials, one scalar,
  keep-or-revert, git as history. Family A: single asset, hill-climb.
- **GEPA, ADAS, DGM, AlphaEvolve** — Family B: population, archive, frontier. GEPA's
  result is the load-bearing one: always breeding from the best aggregate scorer
  sticks in a local optimum.
- **prime-agent** (Prime Intellect) — the closest existing system, and the
  file-backed approximation of an image. Persistent IPython kernel as the only tool;
  prompts, skills, memory and sub-agents CRUD-able at runtime. **The concept is
  claimed; the substrate is not.**
- **Pi** (`badlogic/pi-mono`) — the control arm. Four tools, sub-1000-token prompt,
  everything resolved at startup. Its loop was ported here and has since diverged.

## The strength being played to

Narrower than where this started, and the real one: **the schema is the lambda list,
and the lambda list is live.** Derive a tool's schema from the running function and
it cannot go stale; let an agent install a `DEFUN` and it has written a tool without
authoring a schema. The rest follows from the image being what is real rather than
files being what is real — the ledger as genome, per-definition merge with no textual
diff, forked warm images as trials.

## Mistakes already paid for

Each of these hid for a while and cost real time. They are guarded by tests now.

**Frontier must be the non-dominated set**, deduplicated by score vector. "Best on at
least one case" keeps every tie; on scores floored at zero it returned 81 candidates
out of 81 trials and Pareto degenerated into random sampling. An earlier headline
result was that randomness wearing a Pareto label — retracted.

**Reap before draining the trial pipe.** Draining first blocks until the child closes
it, so the timeout can never fire; a sleeping child held the parent in `read` for its
full 30 seconds.

**Close the pipe's fd-stream.** One leaked descriptor per trial, invisible below a
thousand trials, then fatal — surfacing as `1024 is not of type (UNSIGNED-BYTE 10)`,
which names nothing near the cause.

**`reasoning_effort` is required, not optional.** At default effort gpt-oss-20b
decoded all 2,048 permitted tokens as reasoning and emitted zero tool calls. The run
looked hung.

**The sandbox package must import `cl:t` and `cl:nil`.** A package inheriting nothing
reads the model's `nil` as a fresh symbol named `"NIL"`, which is *true* — every
boolean argument would silently mean its opposite.

**Score the image, never the agent's report.** In the first successful repair the
agent presented a REPL transcript showing the right answer as proof. That session
never happened; its real verification attempts all failed. The fix was genuine, the
evidence invented.

## Where to pick up

[backlog.toml](backlog.toml) holds the order of work and is the source of truth for
it. The summary, and the one thing that reorders everything:

**It starts with the task set.** Every open experiment is blocked on the same missing
object. The whole project's task content is three prompts over two functions, plus a
numeric landscape with no code in it; everything else is machinery operating on a toy.
That is why there are 272 green tests and no results.

1. **Sprint 1 — the instrument.** A task set where imageness is load-bearing, scored
   by calling into the image. Alongside it, opencode read (independent, and it has to
   land before E3's experiment is *designed*, not after), and a guard so experiment
   files stop rotting silently.
2. **Sprint 2 — cheap verdicts.** E5's Lisp-quality gap and E2's claim 1. Both are
   within-harness or no-model comparisons, so neither waits on a trustworthy control.
3. **Sprint 3 — an honest control.** The fidelity check against real Pi, which
   [harness-lineage.md](docs/harness-lineage.md) specifies and which has never run
   because it needs a task set. Until it does, every comparative result carries an
   unquantified *or my port is just different*.
4. **Sprints 4–6** — E3's and E5's real experiments, then E4, then genera-lab.

Two corrections to the order this list used to give. E5's quality gap does *not* need
"no new machinery" — it needs tasks, like everything else. And E2 claim 1 is not merely
unmeasured: every candidate in the current landscape carries exactly one definition,
always the same target, so a complementary pair cannot exist and no budget fixes it.

## Models, and which arm each is honest for

`llama-server` locally, never ollama: seeds, GBNF, parallel slots and slot-level cache
visibility, all of which specific kill criteria depend on. Credentials for the hosted
two are in `.env`, which is gitignored — keep them out of every committed file.

| | reach | good for | not for |
|---|---|---|---|
| gpt-oss-20b, local | `llama-server`, port 8099 | anything needing a **grammar** — E5's constrained arm cannot run anywhere else — plus seeds and cache measurements | "does this work at all"; it measures the model |
| `openai/gpt-oss-120b` | OpenRouter | volume A/B where both arms are held constant; 131k context, ~$0.037/$0.17 per M | grammar-constrained sampling; GBNF is llama.cpp-only |
| `deepseek-v4-flash` | DeepSeek **direct**, not OpenRouter | the arm that has to be strong enough to decide something | unbudgeted sweeps — the balance is small |

Both hosted servers work through the existing `openai-provider` with only `:endpoint`
and `:api-key` differing. A local 20B is fine for A/B held constant across arms, but
watch for floor effects: a model too weak to use either harness shows no difference,
and that is not evidence of none.
