# vivarium

An agent harness whose world is a **running Common Lisp image** rather than a
directory of files. The agent reads a definition, compiles a replacement into the
live process, rolls it back if it was wrong, and can hand itself a new tool
mid-run — with nothing restarting at any point.

Verified on SBCL 2.6.7 / macOS ARM64. **242 tests green.**

```bash
sbcl --eval '(ql:quickload :vivarium/image)'
```

New here? Read [HANDOFF.md](HANDOFF.md) — the question this answers, the six
experiments, what has been settled, and the mistakes already paid for.

## Three layers, dependencies pointing inward

| system | what it is | knows about |
|---|---|---|
| `vivarium` | the harness: messages, tools, schemas, an agent, a loop, providers | nothing task-specific |
| `vivarium/image` | one task domain: a live Lisp image to read, change and undo | the harness |
| `vivarium/search` | scored trials in forked children, an archive, selection | both |

The split is load-bearing, not decorative: `(ql:quickload :vivarium)` brings up the
harness with no `VIVARIUM.IMAGE` or `VIVARIUM.TRIAL` package in the world, so a
second task domain does not have to be bolted onto the first. There is a test for
exactly that.

## The harness

An ordinary agent loop — stream a response, run its tool calls, repeat — with three
deliberate differences.

**The agent is a live object, read per request.** Its prompt and tool set are read
through a generic function *at the moment a request is built*, never captured when
the run starts. Another thread can change what the agent is mid-run and the next
request already carries it. Most harnesses resolve both at startup.

**A steer can abort a request in flight.** Measured against gpt-oss-20b on one
prompt: `ABORTED after 1,927 ms / 0 deltas` against `STOP after 323,875 ms / 1,352
deltas`. Opt-in; with it off the loop behaves like any other.

**Tool schemas are derived, not written.** A tool's parameters come off the live
function — lambda list for names and arity, docstring for the description, SBCL's
derived ftype for argument types. A schema cannot go stale, and an agent that
installs a `DEFUN` has thereby written a tool.

## Providers

The request is a plain OpenAI-compatible chat completion. Everything a particular
server adds sits behind generic functions in
[provider.lisp](src/core/provider.lisp), so a server that lacks a feature is simply
not told about it:

```lisp
(make-instance 'agent:queued-agent
               :provider (provider:llama-cpp-provider
                          :endpoint "http://localhost:8099/v1/chat/completions"
                          :output-prefix provider:+harmony-output-prefix+))
```

`llama-cpp` adds GBNF grammars and template keyword arguments; `openai` puts
reasoning effort in a top-level field and takes no grammar; the default does
neither. The provider lives on the agent, so one arm of a comparison can run on a
local model and another on a hosted one through the same loop.

`constrained-output-prefix` is there because a grammar constrains the **whole**
completion. A bare s-expression grammar makes llama-server reject its own model's
output — the grammar forbade the channel markers the server then tried to parse.
Which literal is required is a property of the model's template, so the provider
answers for it.

## Structured data

JSON tool calling is the trained path and stays the default. [sexp.lisp](src/core/sexp.lisp)
is the Lisp-native alternative: a tool call is a function call and its schema is a
lambda list.

```lisp
(install :source (defun order-total (lines) ...) :note "comped lines count as zero")
```

The definition arrives as a form, read directly — no escaping, no unquoting. Both
formats produce the same arguments table, so tools and validation are shared and
only the wire format differs.

Reading model output is the hazard, and the tests pin it: `*read-eval*` is off,
symbols intern into a sandbox package, and there is a length cap. The sandbox
imports `cl:t` and `cl:nil` deliberately — a package inheriting nothing reads the
model's `nil` as a fresh symbol that is *true*, which would make every boolean
argument mean its opposite.

## Search

`vivarium/search` forks a child per trial from a single-threaded zygote, installs a
candidate, scores it against cases, and reports per-case scores down a pipe. Per-case
rather than one number, because a single scalar makes a Pareto frontier impossible.

SBCL refuses to fork with more than one thread running, so the process that forks
trials can never be the one serving traffic. That is a measured constraint, not a
preference, and it is why the zygote exists.

A candidate is a set of ledger entries, so promoting a winner is replaying
`(target, source)` through `install` — conflicts are per-definition rather than
per-line, and there is no textual merge anywhere.

## Layout

```
src/core/    message schema sexp tool agent provider stream client loop
src/image/   ledger image derive image-tools self
src/search/  trial arena
tests/       one file per module, plus live-*.lisp needing a running server
experiments/ questions with an answer, not tests
```

## Documentation

| file | what it holds |
|---|---|
| [HANDOFF.md](HANDOFF.md) | the goal, all six experiments, current state, where to pick up |
| [docs/](docs/) | one file per experiment, with method and kill criteria |
| [docs/session-notes.md](docs/session-notes.md) | decisions, measurements and mistakes carried across sessions |
| [docs/harness-lineage.md](docs/harness-lineage.md) | what was taken from Pi, and every deliberate divergence |
| [docs/probes/](docs/probes/) | the scripts behind the E1 numbers, rerunnable |

The research track this grew out of is at
[../research/live-image-harness](../research/live-image-harness); these docs are
the working copy that travels with the code.
