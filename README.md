# vivarium

An agent harness with two worlds. One is a **directory** — it reads, writes and
edits files, searches a repository, runs commands, loads skills and keeps
memory, the way any coding agent does. The other is a **running Common Lisp
image**, where the agent compiles a replacement definition into the live
process, rolls it back if it was wrong, and hands itself a new tool mid-run,
with nothing restarting at any point.

The second is the research; the first is what makes it about anything. See
[docs/roadmap.md](docs/roadmap.md) for how the two fit together, and
[docs/level-1.md](docs/level-1.md) for the ordinary half — including a
measured comparison against [Pi](https://github.com/badlogic/pi-mono), the
harness it was replicated from.

Vivarium now covers the core harness model independently of Pi. The remaining
product-level gap is the polished full-screen interactive frontend, which will be
Rust/Ratatui/Crossterm. Harness-level deferred and suspended operations belong in
the long-lived SBCL runtime and do not require provider batch APIs; only durable
provider-side jobs do. Session persistence uses one concrete implementation until
a second real backend justifies an abstraction. From there development shifts
beyond Pi: live task-local self-modification, inheritance of useful improvements,
versioned activation and rollback, and eventually Cordis-like compositional
lifecycle semantics. The shape is frozen in [docs/architecture.md](docs/architecture.md).

```bash
vivarium daemon start        # the organism; sessions live inside it
vivarium attach              # open one; /detach leaves it running
```

Verified on SBCL 2.6.7 / macOS ARM64. **719 tests green.**

New here? Read [HANDOFF.md](HANDOFF.md) — the question this answers, the six
experiments, what has been settled, and the mistakes already paid for.
[backlog.toml](backlog.toml) is the order of work.

## Running it

Everything goes through one entry point, which loads `.env` itself so no run
depends on the caller having sourced it.

```bash
./bin/vivarium test          # the whole suite; exits non-zero if anything fails
./bin/vivarium check         # compile every experiment, no network, no model
./bin/vivarium tasks         # the 17 tasks, their families and the held-out split
```

**Ordinary work in a directory** — three ways into the same agent:

```bash
vivarium shell --cwd ~/work/thing        # interactive; /help lists the commands
vivarium do "the tests fail, fix it"     # one prompt, one answer, no session
vivarium ipc --cwd .                     # JSON in, JSON out, one object per line
```

Skills go in `.vivarium/skills/<name>/SKILL.md`, extensions in
`.vivarium/extensions/*.lisp`, and whatever the agent decides to keep in
`.vivarium/MEMORY.md`. As a library it is `harness:make-workspace-agent` and
`harness:ask`; the shell and the IPC server are thin wrappers over exactly that.

Those three need no credentials. The rest need at least one arm in `.env`
(`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, or a `VIVARIUM_LOCAL_ENDPOINT` with
something actually listening — an arm nothing answers on is not offered).

**Watch one task, and steer it while it runs:**

```bash
./bin/vivarium attend T13 --model deepseek-flash
```

Trajectory on the left, the image's current state on the right — every
definition changed, as it was and as it now is — with scores and a `steer>`
line at the bottom. Type a line and it lands in the request already running,
aborting it rather than waiting for the next one. `--plain` drops the screen and
keeps the transcript, which is what piping or CI gets automatically.

**Point it at your own code, with your own prompt** — this is the general case;
a benchmark task is just a session someone pre-registered:

```bash
vivarium run "IN-STOCK-P returns a count, not a boolean. Fix it." \
  --package DEPOT --load inventory.lisp

vivarium run --file prompt.txt --system my-app --package MY-APP
echo "what is slow in here?" | vivarium run --system my-app
```

`--system` quickloads and `--load` loads a file first, so there is live code to
work on. Nothing is scored — there are no cases — so the ledger is the report.
The shell runs in your working directory, because it is your project; scored runs
are the opposite case and jail themselves.

Reading a definition that was loaded rather than installed still works: a function
reports its lambda list and **a variable reports its live value**. That last one is
the point of the whole project — an agent asked what `*STOCK*` was, got nothing,
guessed a hash table, and installed a `GETHASH` against a list of plists. The data
was in the image the whole time.

**Score models against the task set:**

```bash
./bin/vivarium calibrate --repeats 3 --out results.json
./bin/vivarium calibrate --tasks T13,T14 --models deepseek-flash --repeats 1
./bin/vivarium compare before.json after.json
```

`--repeats` defaults to 3 on purpose: two identical sweeps once disagreed on
**24% of cells** at temperature 0 with a fixed seed, so a single sample per cell
cannot support a comparison. `compare` reports that noise floor between any two
runs.

A scored agent's shell runs in an empty scratch directory and refuses paths
outside it. That is not hygiene — one read `src/tasks/control.lisp`, the file
holding the very cases it was being scored on. See [docs/task-set.md](docs/task-set.md).

## Five systems, dependencies pointing inward

| system | what it is | knows about |
|---|---|---|
| `vivarium` | the harness: messages, tools, schemas, an agent, a loop, providers | nothing task-specific |
| `vivarium/image` | one task domain: a live Lisp image to read, change and undo | the harness |
| `vivarium/tasks` | the benchmark: 17 tasks, their fixtures and the cases that score them | the image |
| `vivarium/search` | scored trials in forked children, an archive, selection | the image |
| `vivarium/cli` | one entry point for every run | everything |

The split is load-bearing, not decorative: `(ql:quickload :vivarium)` brings up the
harness with no `VIVARIUM.IMAGE`, `VIVARIUM.TASKS` or `VIVARIUM.TRIAL` package in
the world, so a second task domain does not have to be bolted onto the first. There
is a test for exactly that. Search does **not** depend on the task set either --
`run-trial` takes thunks and does not care where they came from.

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
bin/         vivarium -- the launcher, and the bootstrap it runs
src/core/    message wire schema sexp tool agent provider stream client loop
src/image/   ledger image derive image-tools self
src/tasks/   service task + one file per task family, attempt
src/search/  trial arena
src/cli/     args arms render screen commands attend main
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
