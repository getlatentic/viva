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

`~/workspace/vivarium` — 2,283 source lines, 242 tests green, SBCL 2.6.7 / macOS
ARM64. Three ASDF systems with dependencies pointing inward:

| system | what it is |
|---|---|
| `vivarium` | the harness: messages, tools, schemas, agent, loop, providers |
| `vivarium/image` | one task domain: a live Lisp image to read, change and undo |
| `vivarium/search` | forked scored trials, an archive, selection over it |

The split is tested, not aspirational: `(ql:quickload :vivarium)` leaves
`VIVARIUM.IMAGE` and `VIVARIUM.TRIAL` absent from the world.

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

The claim narrowed twice under evidence. Pi already polls steering at the end of
every inner iteration, so "content steering below the turn boundary" was not
unclaimed. What no harness does is change the **system prompt or tool set** mid-run —
both are startup-resolved in Pi and Codex. That works here and is tested.

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

### E6 — production harness teardown · **partial**

Not a build, a read. Codex is vendored and was read from source — the steering
findings came from there. Claude Code's binary is confirmed extractable
(`~/.local/share/claude/versions/<ver>`, Bun-compiled, plaintext JS bundle) but not
yet read. One question only: **what is fixed at turn start versus re-read per
request.** That is E3's baseline, and it is a fact about those programs rather than
something to reason out.

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

1. **E5's Lisp-quality gap**, measured alone. It is cheap, it is the likeliest reason
   the single-tool arm loses, and it needs no new machinery.
2. **E2 claim 1** on a landscape where lineages actually specialise, so the conflict
   census has pairs to count.
3. **A real task** instead of a constructed trap. Everything in E2 so far shows greedy
   failing where theory says it must; none of it shows that definition-search
   landscapes have that shape.
4. **E6's remaining half** — extract the Claude Code bundle, answer the one question.

Local model runs use `llama-server` rather than ollama: seeds, GBNF, parallel slots
and slot-level cache visibility, all of which specific kill criteria depend on. A
local 20B is fine for A/B comparisons held constant across arms, but watch for floor
effects — and for "does this work at all", it measures the model, not the harness.
