# Session notes

Working memory carried across sessions: what was decided, what was measured, and
the mistakes that cost time. Kept because most of it is not recoverable from the
code — a bug that was fixed leaves no trace of how long it hid.

Research track at `~/workspace/research/live-image-harness/` asking what an agent
harness gains when the agent's world is a live Lisp image instead of files. Substrate
is [[genera-lab-live-image-agent]]. Six experiments, each with a kill criterion:
E1 trial isolation (**done**), E2 archive/frontier search (next), E3 sub-turn
steering, E4 self-editing CLOS object, E5 single-tool RLM, E6 harness teardown.

**E1 settled 2026-08-07 by measurement, and it forced the architecture:** SBCL 2.6.7
refuses `fork` with more than one thread ("Cannot fork with multiple threads
running"), so genera-lab's Hunchentoot-threaded serving image can *never* be the
thing that forks. Three processes required — serving image (threaded, live sessions,
mutated by `install`), zygote (single-threaded, forks trials), arena (out-of-process,
owns the archive). Per-trial cost: fork 28–32ms, saved core 75ms, cold+quickload
2600ms, in-process 0.12ms. Parallel fan-out barely beats sequential, so wide fan-out
is not free. The honest claim is **not** "faster experiments" — it is that a 100ms
experiment becomes viable at all.

**E2 machinery BUILT + claim 2 settled 2026-08-08.** `search/trial.lisp` (fork a scored
trial from the zygote, pipe back per-case scores, `_exit`) + `search/arena.lisp` (archive,
greedy vs Pareto, `merge-candidates`/`conflicts-between`/`complementary-pair`).
162 assertions green. `experiments/e2-selection.lisp` — no model, same
budget/start/proposer, only selection differs. Budget sweep is the real result:

  budget   60  150  300  600
  greedy   12   12   12   12   (total 10.10 at every budget — frozen)
  pareto   20   28   34   40   (total 15.00 at 600 — global)

Correct claim is **"the frontier converts a hard trap into a budget question"**, at a
measured **10× price**, NOT "Pareto wins at equal budget". 47 ms/trial end to end.
Round-robin over the frontier sets the rate, so progress dilutes as the frontier
grows — a frontier-size-aware schedule is the untried lever.

**Three bugs found here, all invisible at small scale — do not reintroduce:**
- **Frontier must be the NON-DOMINATED SET**, deduped by score vector. "Best on at
  least one case" keeps every tie; on scores floored at 0 it returned 81 of 81
  candidates and Pareto degenerated to random sampling. An earlier "Pareto reached
  the global optimum at budget 60" result was that randomness, not selection —
  retracted.
- **`run-trial` must reap BEFORE draining** the pipe. Draining first blocks until the
  child closes it, so the timeout can never fire (a 30 s sleeping child held the
  parent in READ). Requires the payload to fit the pipe buffer, hence `*detail-limit*`.
- **`drain` must close its fd-stream.** Leaked one fd per trial; dies ~1000 trials in
  as `1024 is not of type (UNSIGNED-BYTE 10)`, which names nothing near the cause.

**Prior art is settled, don't re-research it:** autoresearch = Family A (one file,
hill-climb, git). GEPA/ADAS/DGM/AlphaEvolve = Family B (archive, Pareto frontier —
greedy keep-best provably sticks in local optima). prime-agent (Prime Intellect) is
the closest existing system and is the file-backed approximation of an image; the
concept is claimed, the substrate is not.

**Bases decided:** Pi (badlogic/pi-mono, MIT, vendored at
`~/workspace/harness-test/vendor/pi`) = control arm, prime-agent = treatment. User
decided 2026-08-07 to **port Pi's loop to Lisp, not drive it over RPC** — port surface
is `packages/agent` (~1,500–2,300 lines: `agent-loop.ts` runLoop + 4 tools +
reducer), NOT `packages/coding-agent` (58,702 lines of TUI/extensions). Model runtime
= llama-server, not ollama (seeds, GBNF, `-np` slots, cache visibility).

**HARNESS = `viva` at `~/workspace/viva`** (renamed from "pi-lisp" 2026-08-08;
the name claimed a provenance the code outgrew). **Three ASDF systems, dependencies
inward — do not collapse them:** `viva` (core harness, task-agnostic),
`viva/image` (the live-image task domain), `viva/search` (forked trials +
archive). Layering is tested: `(ql:quickload :viva)` leaves VIVA.IMAGE and
VIVA.TRIAL absent. **242 assertions green, 2,283 source lines.**

**Providers are an abstraction, NOT llama.cpp everywhere** (`src/core/provider.lisp`):
core sends a plain OpenAI-compatible completion; `llama-cpp` adds grammar +
`chat_template_kwargs`; `openai` puts reasoning_effort top-level and takes no
grammar; default does neither. The provider lives on the AGENT so two arms can use
different servers through one loop. `constrained-output-prefix` is a provider
question (`+harmony-output-prefix+`), not a Lisp constant.

**ARM A WORKING + SELF-EXTENDING** (re-verified after the refactor: repair → 35,
self-extend → 7 tools to 8, 19).

**Tool schemas are DERIVED from live functions, not written** (`image/derive.lisp`):
lambda list → names/arity, docstring → description, SBCL's ftype → argument types
(precise only when declared/declaimed; undeclared is advertised as "any", never
guessed). So a schema can't go stale, and an agent that installs a DEFUN has thereby
written a tool. `image/self.lisp` (`register_tool`, `remember`) proved it live: gpt-oss-20b
went 7 tools → 8 mid-run — wrote SHIPPING-COST, installed, registered, called it,
got 19, in 4 requests with no restart. Base prompt + base tools deliberately
unreachable (immutable floor from prime-agent). Arguments are validated against the
schema BEFORE the tool body runs — otherwise a missing arg arrives as NIL and the
model gets told about an internal failure instead of its own bad call. Repaired a broken definition in a live image end to end vs
llama-server + gpt-oss-20b — `(order-total *lines*)` went TYPE-ERROR → 35, checked by
calling the function in-process. Tools: `read_definition`/`install`/`rollback`/
`find_definitions`/`bash` (Pi's write+edit collapse into install). Backend is a
protocol (`pi-lisp.image`) with three known implementations: plain SBCL, genera-lab's
ledger/session image, the forked trial child. Deviations from Pi: non-streaming;
prompt+tools read through a generic function *per request* (E3's premise, tested);
loop hooks + `client:complete` generic on the agent (E4, and scripted test responder).

**STREAMING + ABORT-IN-FLIGHT added 2026-08-08** (`core/stream.lisp`, SSE parse +
tool-call reassembly from index-keyed fragments). Was blocking on the reasoning that
control flow only needs stop-reason + tool-calls — true but beside the point:
**without streaming you cannot abort a request in flight.** `should-abort-p` is
checked before every line read; with `:abort-on-steer t` a steer from another thread
kills the request it interrupts. Measured: **ABORTED at 1,927 ms / 0 deltas vs STOP at
323,875 ms / 1,352 deltas — 168× faster to stop.** Opt-in, default off = Pi's
behaviour, keeping the control honest.
**Corrected 2026-08-21** — this entry claimed abort-in-flight was a capability Pi and
Codex lack. It is not: Pi passes its `AbortSignal` into the streaming fetch
(`packages/ai/src/api/openai-completions.ts:323`). What Pi lacks is the *policy* —
steering is polled at the end of an iteration (`agent-loop.ts:259`) and an abort ends
the run, so abort-and-resume is the only difference. Written from our own docs instead
of the source; see `docs/harness-comparison.md`.
Gotcha: llama.cpp's final usage chunk has `choices: null` and jzon spells null as a
symbol — every field read goes through a `present` guard.

**S-EXPRESSION WIRE FORMAT built 2026-08-08** (`core/sexp.lisp`): a tool call is a
function call, its schema is a lambda list, `(shipping-cost :weight 7)` converts to
the same arguments table JSON produces so tools/validation are shared. Three
measured findings:
- **Escaping tax is small** — 225→233 chars (+3.6%, 6 escapes). The "two layers"
  argument is structural, not a size argument. Don't oversell it.
- **A custom GBNF must live INSIDE the model's own output protocol.** A bare
  s-expression grammar → llama-server 500 "does not match the expected peg-native
  format"; prefixing the root with `<|channel|>final<|message|>` fixes it. Matches
  llama.cpp's own tool grammars, which carry the markers. Hence `*channel-prefix*` /
  `+harmony-final+`, configurable (it's a template property, not a Lisp one).
- Grammar-constrained s-expressions **work** (parseable call, definition as a live
  form), but the model's Lisp was worse than its JSON-arm Lisp — the likeliest way
  arm B loses.

**Reading model output safely:** `*read-eval*` off, sandbox package, length cap. The
sandbox MUST `(:import-from #:common-lisp #:t #:nil)` — a package inheriting nothing
reads the model's `nil` as a fresh symbol named "NIL" which is **true**, so every
boolean argument silently means its opposite.

**Live-run gotchas, all cost real time — don't rediscover:**
- gpt-oss puts CoT in `reasoning_content` with `content` empty; dropping it makes a
  working run look silent.
- **`reasoning_effort` is required, not optional**: at default effort gpt-oss-20b
  decoded all 2048 permitted tokens as reasoning and emitted ZERO tool calls. With
  `"low"` the same task took 7 requests. Sent both top-level and via
  `chat_template_kwargs`.
- Fixed tool schemas force the agent to reproduce exact target strings and it gets
  them wrong (asked `SHOP::ORDER-TOTAL`, ledger keyed `DEFUN SHOP::ORDER-TOTAL`) →
  infinite loop. Needed fuzzy target resolution + candidate listing on miss. Direct
  evidence for E5.
- **The agent FABRICATED its verification** — printed a REPL transcript showing `35`
  that never ran, while its real bash checks all failed. Fix was genuine, evidence
  invented. So: **E2 must score the image, never the agent's report.**

**HOSTED PROVIDERS WIRED + TWO WIRE BUGS FIXED 2026-08-08.** Keys live in `.env`
(gitignored, `.env` + `.env.*` already covered — never paste them into a doc).
OpenRouter (`openai/gpt-oss-120b`, 131k ctx, $0.037/$0.17 per M) and DeepSeek direct
(**`deepseek-v4-flash`** and `deepseek-v4-pro` — those are the only two ids the API
lists; flash is what "DeepSeek flash" means). DeepSeek is *not* reached through
OpenRouter. Both work through the **existing** `openai-provider` with only
`:endpoint` + `:api-key` differing — no new provider class was needed. Budgets are
small: DeepSeek $9.24, so a sweep has to be costed before it is run.

Getting there needed two fixes, both in code no test covered — **the blocking
response parser had no test file at all**, which is why they survived:
- **`content: null` crashed the parse.** OpenRouter sends JSON null for `content` on
  any message that is entirely tool calls. jzon renders null as a *symbol*, which is
  true and has no length, so `(plusp (length text))` signalled `The value NULL is not
  of type SEQUENCE` — naming neither the field nor the server. `stream.lisp` already
  had the `present` guard for exactly this; `client.lisp` never got it.
- **Chain of thought has two spellings.** llama.cpp and DeepSeek use
  `reasoning_content`, OpenRouter uses `reasoning`. Reading one spelling drops the
  other, and a reasoning model with empty `content` then looks silent — the failure
  this project already paid for once.
Both now go through **`src/core/wire.lisp`** (`present`/`field`/`text-field`/
`reasoning-field`), which is where the "OpenAI-compatible is a family resemblance"
vocabulary lives; `stream.lisp` and `client.lisp` share it instead of one owning it.
`tests/wire.lisp` pins both against recorded bodies from all three servers.
**272 assertions green** (was 242).

**`experiments/e5-wire-format.lisp` was DEAD and nobody noticed.** The provider
refactor left `(make-instance 'agent :provider *provider*:queued-agent ...)` at two
call sites — reads as a package-qualified symbol, so the file died at read time with
"Package *PROVIDER* does not exist". Nothing in it had run since. Fixed; the offline
half reproduces the documented 225→233 / +3.6% / 6 escapes exactly. Experiments are
not in the test suite, so they rot silently — check them after any core refactor.

**E6 LARGELY ANSWERED 2026-08-08, from the host side rather than the binary.** Four
legible sources, not two: Codex + Pi (source), the **Claude Agent SDK** (Python
0.2.131 + TS, both vendored, open source) and **Claude.app** — Electron,
`app.asar` 39.5 MB, extracts to 404 plaintext JS files. Correction worth keeping: the
Electron thing is the *desktop app*; the Claude Code **CLI** is still a Bun-compiled
Mach-O at `~/.local/share/claude/versions/2.1.210`. And the asar is a **host**, not
the loop — it drives Claude Code over the same `control_request` protocol the SDK
speaks, so the loop is only in the binary.

The protocol answers most of E3's baseline question. Full set the CLI accepts:
`initialize, interrupt, stop_task, set_model, set_permission_mode, rewind_files,
mcp_toggle, mcp_status, mcp_reconnect, get_context_usage`. **No `set_system_prompt`,
no `set_tools`.** `mcp_toggle` is `(serverName, enabled)` — a *pre-registered* server
on/off, so the tool list moves mid-session but nothing new can be introduced. That is
precisely the line `register_tool` crosses. `~/workspace/harness-test/vendor/` is one
repo holding the trees as plain dirs, so a commit read inside codex/opencode/the SDKs
is harness-test's, not upstream's — only `pi` has its own git. **opencode still
unread**; it is the one source that could still move the baseline.

**THE TASK SET EXISTS 2026-08-08 — S1, the root the whole backlog waited on.**
`viva/tasks` (4th ASDF system, depends on `viva/image`; search does NOT depend
on it, since `run-trial` takes thunks). 913 lines, 14 tasks, 42 cases. **357 assertions
green** (was 272). Design record: `docs/task-set.md`. Order of work: `backlog.toml`.

**Two properties pinned per task, and a benchmark is worthless without both:** it must
FAIL before a fix and PASS completely under a known-good one. The answer key lives in
`tests/tasks.lisp`, never in the task set, so nothing on the agent path reaches it.
Scored end to end through a **forked trial at 43–62 ms**, matching E2's 47 ms.

**The four imageness dimensions collapse to two roots.** A file harness cannot observe
or preserve *state that exists only in the running process and was never produced by
loading source*. "Diagnose from runtime-only info" IS that state; "keep serving" is how
it dies. Only capability-acquisition stands apart, and it is a harness property, not a
task one. Keep the honest caveat attached: give a file harness a REPL-over-socket tool
and the distinction dissolves — but that is an image harness with extra steps.

**The ceiling claim got corrected in the harder direction.** First draft said a
reloading harness still takes full marks on correctness. True only where correctness is
a property of the function alone (T13: `order-total` still right after `*lines*` is
emptied). Where correctness is defined against the accumulated data, losing the data
fails that too — emptying `*events*` takes T1 from 3 green cases to **zero**, repaired
definition included. Both pinned by tests.

**E2 CLAIM 1's CLEAN-MERGE HALF IS DEMONSTRATED**, for the first time, via T12:

  ships only   shipping-surcharge 1.0   export-untaxed 0.0
  taxes only   shipping-surcharge 0.0   export-untaxed 1.0
  merged       shipping-surcharge 1.0   export-untaxed 1.0    conflicts NIL

Two lineages fixing different definitions, neither dominating, merge carrying both.
The old landscape could never produce this — every candidate carried exactly one
definition, always the same target.

**Three defects found building it, all worth keeping:**
- **`install-definition` evaluated outside the image's package.** It bound `*package*`
  while READING and not while EVALUATING, so any form that DERIVES names — `defstruct`
  constructors and accessors above all — interned them wherever the caller happened to
  be. Surfaced as `MAKE-EVENT is not present in <task package>` for a struct that had
  just installed successfully. Fixed in `image.lisp`; it would have hit any agent that
  installed a `defstruct`.
- **A case must observe, not act.** T7 had two cases each invoking `advance-all`.
  Running the broken one first marked every order `:COMPLETE`, so the fixed one never
  took the `:DEFERRED` branch again and a *correct* repair scored as a failure — an
  artefact indistinguishable from a bad harness. Cases that must act now restore from a
  snapshot first; the one case that must NOT restore is the one watching for a drained
  queue.
- **A case that signals scores NIL, not 0**, and the task tests must mirror
  `trial:score-case` or they disagree with the search layer about what a crash means.

**`--eval` reads exactly one form.** Two forms in one `--eval` string silently runs only
the first — cost a confusing empty-output debug round. Use `--load` with a file.

**CALIBRATION 2026-08-08 (S2c) — THE SET DISCRIMINATES, and it cost one task defect
plus a constraint on every experiment after it.** 14 tasks × 2 models (gpt-oss-120b via
OpenRouter, deepseek-v4-flash direct) through the real loop and arm A's tool set, mean
8.3 requests of a 12 cap. Five tasks separate the models; **none is solved by neither**.
Eight solved by both — *not* waste: the set compares HARNESSES, and where model
capability is not the bottleneck a failing harness fails for harness reasons. Table in
`docs/task-set.md`. Runner is `src/tasks/attempt.lisp` (`attempt-task`), shared by S3,
S5, S6 — setup, build cases, THEN act; the ordering is the correctness argument.

**24% CELL-FLIP RATE BETWEEN TWO IDENTICAL SWEEPS — n=1 IS NOISE.** Same tasks, same
models, temperature 0, fixed seed: 6 of 25 comparable cells disagreed (T3/gpt .33→.67,
T7/ds .83→1.0, T10/gpt 1.0→.33, T11/gpt .67→1.0, T12/ds .67→1.0, T14/gpt .33→1.0).
Hosted providers do not promise determinism and do not deliver it. **`attempt-repeatedly`
+ `fraction-summary` exist for this and S3/S5/S6 must use them, reporting spread not
just a mean.** One casualty already: sweep 1 showed gpt-oss-120b rewriting T14's
already-correct definition *and breaking it*, which read as the control task earning its
place. It did not reproduce. One sample, one story.

**T9 scored 0.00 for both models and it was the TASK's fault** — the class of bug
calibration exists to catch. The prompt never said what to NAME the function the cases
check, and told the agent to "call it" using a tool set with no way to call anything.
Both models wrote correct pricing functions under their own names and scored nothing.
The trace also caught the documented fresh-`sbcl --script` verification failure again.
Fixed → 1.00/1.00. **Also recorded rather than overstated: the B-capability family
checks a schema COULD be derived from the installed function, not that the agent
registered and used it as a tool. That needs the agent object in scope — S6.**

**Gotchas from the build, all cost time:**
- `attempt-requests` collided as both a defstruct accessor and a class accessor; the
  struct's won and type-checked its argument (`BENCH-AGENT is not of type ATTEMPT`).
  Agent slots are `bench-*` now.
- `--eval` reads exactly ONE form. Two forms in one string silently runs only the
  first. Use `--load` with a file.
- A verdict classifier that lumps "off floor and ceiling" together with "models differ"
  is wrong, and it inverted the reading: ceiling tasks are the BEST harness-comparison
  tasks, not waste.

**BENCHMARK CONTAMINATION, caught 2026-08-08 and it invalidated a sweep.** A scored
agent with `bash` reads the machine hosting its own benchmark. Observed in the
trajectories: `cat src/tasks/control.lisp` and `cd /Users/dev/workspace/vivarium &&
cat src/tasks/service.lisp` -- the files holding the cases it was being scored on --
plus three verification scripts written into the REPO ROOT, one commented "Mirror
T11's fixture exactly (from src/tasks/merge.lisp)". Not adversarial: it wanted to
verify, and the benchmark was the nearest thing to verify against.

- **A cwd jail is NOT sufficient** -- an absolute path ignores the cwd. `bash` now
  refuses any command naming a path outside its scratch dir, records every command,
  and writes reaching commands into the results JSON so a row can be discarded later.
  The judgement must survive the run: the detector has already been wrong once.
- **First detector matched the bare word "viva"**, which every task package name
  contains (VIVA.TASK.T11), so it flagged correct behaviour. Tells are path-shaped
  now. A contamination flag that fires on good runs is worse than none.
- **Contamination was most of the COST too**: T13 286s/12req -> 8s/4req once the shell
  stopped paying off. T11 now solves in 4 requests using only image tools.
- **The deeper finding: `bash` is close to useless in an image harness.** Across every
  trace, not one bash call verified anything about the live image -- a fresh process
  cannot see it, which is exactly the fabricated-verification failure already paid for.
  Whether arm A should carry bash at all is now open; Pi parity is the only argument
  left for it, and that only matters for S5's file-tool comparison.
- Deepseek's calibration column is contaminated on 12/14 rows and needs re-measuring.
  The verdict that the set DISCRIMINATES survives -- visible in both sweeps, not
  dependent on those rows.

**`viva attend` built** (`src/cli/attend.lisp`): watch one task run and steer it
live. Line-oriented ANSI, NOT ncurses -- croatoan/cl-charms/cl-tui are all in the dist
and none earns its place, because the transcript IS the deliverable (E5's auditability
criterion) and a full-screen app costs scrollback, copy-paste and piping. Rendering was
never the hard part; reading stdin while a request is in flight is, and that is a
`bordeaux-threads` reader calling `queue-steering`. **E1 bites again: two threads means
this process can never fork a trial** -- attending and searching must be separate
processes. Shows the ledger as was/now per definition plus the per-case scores, which is
"the modification and then the improvement" in one view.

**Also fixed:** an arm was offered for `VIVA_LOCAL_ENDPOINT` with nothing listening,
producing a whole column of `err` -- arms now TCP-probe first. `inject` emits `:message`
for messages going INTO the loop, so `attend` printed the prompt twice; assistant
messages only. `check` used `uiop:tmpize-pathname`, which COPIES the source beside the
original -- each run copied every experiment and the next globbed the copies, 69 junk
files before it was caught.

**Steering, read from source in both:** queue ≠ steer. Codex — a steer preempts
*blocking tools* immediately via a watch channel (`sleep.rs`, `wait.rs`), but content
lands at the next turn iteration. Pi is finer: `agent-loop.ts:259` polls steering at
the end of *every* inner iteration and injects before the next assistant response, so
"content steering below the turn boundary" is already claimed. E3 therefore narrowed
to **capability injection** — no harness mutates the system prompt or tool set
mid-run, both are resolved at startup. Claude Code's binary is at
`~/.local/share/claude/versions/<ver>` (Bun-compiled Mach-O, plaintext JS bundle,
greppable) — NOT `~/.local/bin/`.

Related: [[verify-artifact-claims-by-behavior]] — E1 was settled by running fork, not
by reading docs.
