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

**HARNESS = `vivarium` at `~/workspace/vivarium`** (renamed from "pi-lisp" 2026-08-08;
the name claimed a provenance the code outgrew). **Three ASDF systems, dependencies
inward — do not collapse them:** `vivarium` (core harness, task-agnostic),
`vivarium/image` (the live-image task domain), `vivarium/search` (forked trials +
archive). Layering is tested: `(ql:quickload :vivarium)` leaves VIVARIUM.IMAGE and
VIVARIUM.TRIAL absent. **242 assertions green, 2,283 source lines.**

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
323,875 ms / 1,352 deltas — 168× faster to stop.** Pi delivers a steer no earlier than
the next request; Codex preempts a *waiting* tool but not an in-flight completion.
Neither can do this. Opt-in, default off = Pi's behaviour, keeping the control honest.
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
