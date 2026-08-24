# Porting Pi's loop to Lisp

**The harness is now `viva` (`~/workspace/viva`), not "viva".** It began
as a port of Pi's loop and has diverged enough that the name was claiming a
provenance the code no longer has: streaming with abort-in-flight, schemas derived
from live functions, an s-expression wire format, a provider abstraction, forked
scored trials, self-extension. Pi remains the control arm and the loop is still
diffable against `agent-loop.ts:155`.

Shared infrastructure for [E3](e3-subturn-steering.md), [E4](e4-self-editing-object.md)
and [E5](e5-single-tool-rlm.md). Decision: **port, do not drive Pi over RPC.**

**Status: arm A works end to end, and extends itself.** `~/workspace/viva`,
3,670 lines (1,991 source / 1,679 tests and experiments), 187 assertions green. Against llama-server + gpt-oss-20b the harness repaired a
broken definition in a running image — `(order-total *lines*)` went from signalling
a TYPE-ERROR to returning 35, checked by calling the function in-process rather
than by reading what the agent said.

Arm A's tool set is `read_definition`, `install`, `rollback`, `find_definitions`,
`bash` ([image-tools.lisp](../src/image/image-tools.lisp)). Pi's `write` and
`edit` collapse into `install`: in an image there is no difference between creating
a definition and replacing one. Five tools rather than four is consistent with Pi's
real surface, which is four core plus `grep`/`find`/`ls`.

## Tool definitions are derived, not written

The part with no equivalent in a file-based harness. A tool's schema is read off
the live function — lambda list for names and arity, docstring for the description,
and SBCL's derived ftype for argument types ([derive.lisp](../src/image/derive.lisp)).
Two consequences:

- **A schema cannot go stale.** Redefining the function redefines the schema. There
  is a test for exactly this: change a function from one argument to two and the
  derived tool reports two.
- **An agent that installs a `DEFUN` has thereby written a tool.** No schema to
  author. This is what makes [E3](e3-subturn-steering.md)'s capability injection
  usable by an agent rather than only by a person editing the harness.

Types are honest about what they know: a declared or declaimed argument yields a
precise JSON type, an undeclared one is advertised as **any** rather than guessed
at. Advertising a constraint the function does not have would be worse than
advertising none.

Schemas and validation live together in [schema.lisp](../src/core/schema.lisp)
because they must agree. Arguments are checked against the schema **before** the
tool body runs — a missing argument arriving as `NIL` otherwise fails somewhere
inside the body, and the model gets told about that internal failure instead of
about the call it got wrong. The error names what was missing and what the tool
expects.

## Self-extension, demonstrated live

[self.lisp](../src/image/self.lisp) gives an agent `register_tool` and
`remember`. Against gpt-oss-20b, starting with no way to price a shipment and
forbidden from doing the arithmetic itself:

```
tools: read_definition, install, rollback, find_definitions, bash, register_tool, remember
  → install         ← Installed DEFUN DEPOT::SHIPPING-COST.
  → register_tool   ← Registered shipping_cost. It takes: weight (any, required).
  → shipping_cost   ← 19
tools at start: 7    tools at end: 8    function in image: 19
EXTENDED -- the agent wrote a tool, registered it mid-run, and used it
```

Four requests, no restart. That is E3's capability-injection claim working; whether
it *improves outcomes* is still the experiment.

The base prompt and base tools are deliberately out of reach of both tools — the
immutable floor borrowed from prime-agent, so a self-edit that breaks the editor
stays recoverable.

## Deliberate deviations from Pi

| Pi | here | why |
|---|---|---|
| polls steering at the end of an iteration | ends the request a steer interrupts, and re-enters carrying it | see below — the difference is the policy, not the abort |
| prompt and tools resolved before the loop | read through a generic function per request | the entire point of [E3](e3-subturn-steering.md) — a mid-run change must land on the next request |
| callbacks in an `AgentLoopConfig` object | generic functions on the agent | so [E4](e4-self-editing-object.md)'s agent can override its own hooks with `defmethod` |
| `complete` is a fixed provider call | generic on the agent | lets a scored trial swap in a scripted responder, and lets an agent change its own provider |

Both mutability deviations are covered by tests: *"the system prompt is read per
request, so a mid-run change lands"* and *"a tool added mid-run is available on the
next request"*. That is E3's capability-injection claim demonstrated at loop level —
the real experiment is whether it changes outcomes.

## Streaming, and what it actually bought

Originally built blocking, on the reasoning that the loop's control flow depends
only on the stop reason and the tool calls. That was true and beside the point:
**without streaming you cannot abort a request in flight.** A steer arriving
mid-generation has to wait for the whole response.

[stream.lisp](../src/core/stream.lisp) parses SSE and reassembles tool calls,
whose name and arguments arrive as fragments across many chunks keyed by an index.
`should-abort-p` is checked before every line read, so an abort lands finer than
event granularity. Measured against gpt-oss-20b on the same prompt:

```
abort in flight:  ABORTED after   1,927 ms and    0 deltas
same, unaborted:  STOP    after 323,875 ms and 1,352 deltas
```

**168× faster to stop** than letting the same request run to completion. The
mechanism is not exotic and is not ours: Pi hands its `AbortSignal` to the streaming
fetch (`packages/ai/src/api/openai-completions.ts:323`) and ends a completion
mid-generation too. Any harness whose HTTP client takes a signal can.

What differs is one line of policy. Pi polls steering at the *end* of an iteration
(`agent-loop.ts:259`), so a steer arriving mid-generation waits out the current
request, and an abort ends the run (`agent-loop.ts:196`). With `abort-on-steer` a
steer queued from another thread ends the request it interrupts and the loop
re-enters carrying it — abort-and-resume against abort-and-stop. The policy is
opt-in; default off reproduces Pi's behaviour exactly, which keeps the control arm
honest.

Two smaller returns, both of which would have saved time earlier: time-to-first-token
is now measurable (1,657 ms on a cold cache against 7,142 ms total), and a run that is
thinking looks different from a run that has hung — the failure that originally cost a
dig through a server log.

**Parsing gotcha worth keeping:** llama.cpp's final usage chunk carries
`choices: null`, and jzon spells JSON null as a symbol. Reading it as a value fails
deep in the accumulator with an error that mentions neither streaming nor JSON. Every
field read now goes through a `present` guard.

## Findings from the first live run

**`reasoning_content` is a separate field and dropping it loses everything.**
gpt-oss puts chain-of-thought there and leaves `content` empty until it stops
thinking. With a small token budget every reply is an empty `finish_reason:
"length"` — the run looks silent when it was working. Now parsed into a `thinking`
block, which is deliberately not echoed back on the next request.

**A reasoning model needs a budget that clears its reasoning, or `:length` is the
normal outcome.** At `max_tokens` 64, gpt-oss-20b never emitted a single content
token. At 1024 it answered every time. Any scored trial that caps tokens tightly
will silently measure truncation instead of capability.

**Determinism holds.** A fixed seed gave four identical replies. An earlier
"DIVERGED" reading was the token budget, not slot-cache state — worth recording
because the wrong diagnosis would have sent E1/E2 chasing a cache confound that
does not exist at `--parallel 2`.

**Reasoning effort is a required harness parameter, not a nicety.** At its default
effort gpt-oss-20b decoded all 2,048 permitted tokens as reasoning and emitted no
tool call whatsoever — one silent request and the run ended. The server log is
unambiguous: `eval time = 78764.65 ms / 2048 tokens`. With `reasoning_effort: low`
the same task completed in seven requests. It is now a slot on the agent, sent both
top-level and through `chat_template_kwargs` because llama.cpp reads it from the
template and hosted providers read it from the field.

**Fixed schemas make the agent guess exact strings, and it guesses wrong.** The
ledger keyed definitions as `DEFUN SHOP::ORDER-TOTAL`; the agent asked for
`SHOP::ORDER-TOTAL`, exact-match lookup missed, and it looped between
`read_definition` and `find_definitions` until the iteration cap. Fixed by resolving
a target by operator-stripped name, then by bare symbol name, reporting candidates
when ambiguous — and by listing what does exist when a lookup misses. This is
first-hand evidence for [E5](e5-single-tool-rlm.md)'s premise: the schema was the
obstacle, not the task.

**The agent fabricated its verification, and only a behavioural check caught it.**
Its closing summary presented a REPL transcript — `CL-USER> (order-total ...)` →
`35` — as proof. That session never happened. Its actual attempts shelled out to a
fresh `sbcl --script` that had never heard of the definition, and every one of them
failed. The fix was genuine; the evidence for it was invented.

Consequence for [E2](e2-archive-tree.md), and it is not a small one: **a scored
trial must score the image, never the agent's report.** A harness that accepted
self-reported success would have recorded a pass here on fabricated grounds, and
would keep doing so for changes that did not work at all.

## Scope, measured

"Minimal" describes Pi's design thesis, not its repo. `packages/coding-agent` is
**58,702 lines** of TypeScript — terminal UI, themes, commands, extensions, packages.
None of it is the loop. The loop lives in `packages/agent` (12,415 lines), and the
part that must be ported is far smaller:

| file | lines | port? |
|---|---|---|
| `agent-loop.ts` — `runLoop` + tool-call pipeline | ~640 of 796 | **yes, faithfully** |
| `harness/tools/{read,write,edit,bash}.ts` | 471 | yes, but see below |
| `harness/tools/edit-diff.ts` — fuzzy diff matcher | 500 | only for the fidelity run |
| `harness/reducer.ts` — session state reduction | 667 | yes |
| `harness/agent-harness.ts` | 508 | partially |
| `harness/compaction/compaction.ts` | 848 | later; not on any kill criterion |
| `harness/env/nodejs.ts`, `tui`, `coding-agent` | ~75,000 | no |

Real port surface: **~1,500–2,300 lines of TS**. The instinct that it is portable
holds; the correction is that the target is `packages/agent`, not the 58k package
that carries the name.

## What must be preserved exactly

From `agent-loop.ts:155`, the structure that makes Pi Pi:

- **Outer loop** — after the agent would stop, poll `getFollowUpMessages()`; if any,
  re-enter.
- **Inner loop** — per iteration: inject pending messages *before* the assistant
  response, stream one assistant message, execute its tool batch, then poll
  `getSteeringMessages()` at the end of the iteration.
- `stopReason === "length"` fails the **whole** tool batch rather than executing
  possibly-truncated arguments. Easy to miss, and it is a correctness behaviour.
- `prepareNextTurn` may swap `model` and `thinkingLevel` between iterations.
- Tool batches run sequential or parallel, and a batch can signal `terminate`.

## The tool-semantics trap

Pi's four tools are `read`, `write`, `edit`, `bash` — file-oriented, because Pi's
world is a directory. E5's arm B operates on the image.

**Do not port the file tools and call that arm A.** Comparing file-Pi against
image-single-tool confounds tool *semantics* with tool *cardinality*, and the result
would be uninterpretable. Arm A is Pi's *structure* — four tools, fixed schemas,
sub-1000-token prompt, everything resolved at startup — carrying the image's
equivalents (`read-definition`, `install`, `run`, `bash`). Only the cardinality and
the mutability differ between arms.

## Fidelity check

The reason not to port a control is that a win becomes unattributable. Since we are
porting anyway, buy the attribution back with one measurement:

1. Port the file tools too, including `edit-diff.ts`.
2. Run the Lisp loop and real Pi on the same task set, same model, same seed, with
   the file tool set.
3. Confirm trajectories and pass rates land within noise.

Then swap in the image tools for the experiments. Without step 2 every downstream
result carries an unquantified "or my port is just different" caveat. With it, the
port is a legitimate control and says so with a number.

Vendored at `~/workspace/harness-test/vendor/pi` (badlogic/pi-mono, MIT).
