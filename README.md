# vivarium

A long-lived agent that does ordinary work in a directory — reads and writes
files, searches a repository, runs commands — and, when you ask it to, decides
for itself what the work taught it and writes that down.

What it keeps lands **outside the process**, in the folder it was working in:
a note in `.vivarium/MEMORY.md`, a skill in `.vivarium/skills/`, a tool in
`.vivarium/tools/`. Plain files. You can read them, edit them, delete them,
commit them — and so can any other agent, because the tools it writes are also
served over MCP. Nothing it learns is trapped in a running image or a vendor's
memory store.

It has one long-lived process behind it, so a session outlives the terminal
that started it. Close the pane; the work carries on.

## Install

Needs **SBCL** and **Quicklisp**. Nothing else is installed by hand.

```bash
git clone https://github.com/tosinamuda/vivarium && cd vivarium
cp .env.example .env        # then fill in one provider key
./bin/vivarium test
./bin/vivarium install      # puts `vivarium` on your PATH
```

The first run downloads dependencies and compiles everything: about **4
minutes**, then ~2 seconds warm. It ends in `Passed: 1344 / Failed: 0`. If
Quicklisp is missing, `bin/vivarium` prints the two commands that install it.

`install` links the launcher into the first writable directory on your PATH —
`~/.local/bin`, `~/bin`, `/usr/local/bin`, or wherever you point `--prefix`. It
refuses to replace anything it did not put there, and tells you the `export`
line if the directory it chose is not on your PATH. Every `vivarium …` example
below assumes you ran it; without it, they are `./bin/vivarium …` from the
repository.

`.env` needs exactly one of `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY` or `BEDROCK_API_KEY` — or a `VIVARIUM_LOCAL_ENDPOINT`
with a llama.cpp server actually listening. `bin/vivarium` loads `.env`
itself, so no run depends on you having sourced it.

Verified from a fresh clone under a fresh `HOME` — new Quicklisp, empty
caches, no `.env`. The install path is covered by tests in
[tests/release.lisp](tests/release.lisp), because documentation drifts
silently and a red test does not.

## See it learn something

```bash
./demo/retention
```

Five times over, the same chore with different data: a folder of JSONL
transcripts, and a request for the token totals inside them. Nothing in it
asks for a tool or a note — after each task the agent gets one turn to decide
for itself what is worth keeping, and the script reports what it kept, whether
anything used it, and what it cost.

About **$0.02**, two minutes, and it stops at a $0.25 cap checked by the
project's own meter between tasks.

Runs vary, and the report says which happened rather than assuming. Every run
so far has answered all five correctly and kept something: usually a note
about the file format, carried into every later task; on one run it wrote
itself a **tool**, `usage-totals`, and called it on a later task — a
transformation worked out once and then reached for instead of redone. Per
kilobyte of input, the late tasks have come out cheaper on every run so far.

Five tasks is a direction, not a measurement, and the numbers move run to run
— which is why they are printed by the run in front of you rather than quoted
here. The measurement is the 25-task study.

That is a demo, not a study. The study is
[experiments/dogfood/RESULTS.md](experiments/dogfood/RESULTS.md): 25 real
recurring jobs, four claims fixed before any data. Retention **happens** (5
artifacts across 25 tasks), what it keeps is **good** (4 of 5 survived a cold
review), it **gets reused** (a tool the agent wrote during one task was called
five times by two later ones) — and it **does not yet pay**: +8.2% tokens
against a −20% threshold, and split, improving mechanical recurring work while
costing more on work that is mostly judgement.

Which is why retention is opt-in. Defaulting a measured cost increase onto
everyone is not something this repository does.

## Ordinary work

```bash
vivarium do "the tests fail, fix it" --cwd ~/work/thing
vivarium do "summarise what changed" --retain     # …and keep what it learns
vivarium shell --cwd ~/work/thing                 # interactive; /help lists the verbs
vivarium ipc --cwd .                              # JSON in, JSON out, one object per line
```

As a library it is `harness:make-workspace-agent` and `harness:ask`; the
shell, `do` and the IPC server are thin wrappers over exactly that.

**The organism.** One process, sessions inside it:

```bash
vivarium daemon start --background
vivarium attach              # /detach leaves it running
```

A session outlives its terminal. Verified by killing the terminal outright and
rejoining the session by name from a new one — along with colour, resize,
Ctrl-C, and redirection, all inside a real tmux pane. We do not build a
multiplexer; we behave properly inside yours.

**What it keeps, and where.**

```
.vivarium/MEMORY.md          notes it wrote      (also ~/.vivarium/, for every project)
.vivarium/skills/<name>/     SKILL.md
.vivarium/tools/<name>/      tool.json + a script in any language
.vivarium/extensions/*.lisp  yours, not its -- loaded only from a trusted project
```

A tool is a directory holding a manifest and a script. Arguments arrive as
**JSON on stdin**, never argv — a delimiter crossing a shell is a bug this
project has already paid for twice. Running a project's own code is a decision
you make: `vivarium trust <dir>`, or `/trust` in the shell.

**Serve them to other agents.**

```bash
vivarium mcp --cwd ~/work/thing
```

Every tool in that project's registry, over MCP on stdio, to any client. What
this agent worked out, another agent can call.

## What is actually proven

| claim | where |
|---|---|
| 1,344 tests green on a clean machine | `./bin/vivarium test` |
| the evolution lifecycle's safety properties — 13 TLC configs, 6 of them witnesses where the *violation* is the proof | `./spec/verify.sh` (needs Java and `tla2tools.jar`; the script says how) |
| the live-compile door costs 1.9× what plain text costs, with 0 of 6 families favouring it | [experiments/kc6/RESULTS.md](experiments/kc6/RESULTS.md) |
| retention happens, is good, is reused, and does not yet pay | [experiments/dogfood/RESULTS.md](experiments/dogfood/RESULTS.md) |
| what the mission claims, scored against itself line by line | [docs/MANIFESTO.md](docs/MANIFESTO.md) |

## History: the live image, and why it is parked

Vivarium began as a research question — *what does a harness gain when the
agent's world is a running Lisp image rather than a directory of files?* The
agent could compile a replacement definition into the live process, roll it
back if it was wrong, and hand itself a new tool mid-run with nothing
restarting.

It works. It is proven, ledgered, and was used by a real model. **It also lost
the experiment built to judge it.**

[Kill criterion six](experiments/kc6/RESULTS.md) put the live-compile door
against plain-text retention across six task families: 54 cells, 270 task-runs,
$3.50. The decision rule was written before any run:

> Keep the architecture if A beats C at that effect size with all six
> families agreeing.

A beat C in **0 of 6**. Not split — unanimous the other way, at 1.9× the cost
per solved task, with the arm-B control failing as well. The door was
genuinely used (47 capabilities minted, 10 promoted), so this is not a null
result from a feature nobody touched.

So retention moved outside the process, which is what the rest of this README
describes. The live-image path is **parked by ratification, not deleted**: the
code, the TLA+ spec and the tests all still stand, `--capabilities on` still
opens the door, and revisiting it is
[issue #16](https://github.com/tosinamuda/vivarium/issues/16).
[docs/kc6-protocol.md](docs/kc6-protocol.md) holds the protocol and its 17
amendments — the negative result is written up at the length the positive one
would have got.

## The harness

An ordinary agent loop — stream a response, run its tool calls, repeat — with
three deliberate differences.

**The agent is a live object, read per request.** Its prompt and tool set are
read through a generic function *at the moment a request is built*, never
captured when the run starts. Another thread can change what the agent is
mid-run and the next request already carries it.

**A steer can abort a request in flight.** Measured against gpt-oss-20b on one
prompt: `ABORTED after 1,927 ms / 0 deltas` against `STOP after 323,875 ms /
1,352 deltas`. Opt-in; with it off the loop behaves like any other.

**Tool schemas are derived, not written.** A tool's parameters come off the
live function — lambda list for names and arity, docstring for the
description, SBCL's derived ftype for argument types. A schema cannot go
stale.

Requests are plain OpenAI-compatible chat completions. What a particular
server adds sits behind generic functions in
[provider.lisp](src/core/provider.lisp), so a server that lacks a feature is
simply not told about it. The provider lives on the agent, so one arm of a
comparison can run against a local model and another against a hosted one
through the same loop.

## Layout

```
bin/           vivarium -- the launcher, and the bootstrap it runs
demo/          retention -- the five-task demo and its report
src/core/      message wire schema sexp tool agent provider stream client loop
src/workspace/ files search shell skills memory registry mcp trust sessions
src/console/   the shell, and the IPC server
src/daemon/    the long-lived process and its socket
src/image/     the parked live-compile domain, still proven and still tested
src/cli/       one entry point for every run
spec/          TLA+ and the verifier that runs every config
tests/         one file per module, plus live-*.lisp needing a running server
experiments/   questions with an answer, not tests
```

| file | what it holds |
|---|---|
| [docs/MANIFESTO.md](docs/MANIFESTO.md) | the mission, scored against itself |
| [CONTRIBUTING.md](CONTRIBUTING.md) | how work is proposed and judged |
| [docs/retention-policy.md](docs/retention-policy.md) | what the agent may keep, and why those channels |
| [docs/tool-registry.md](docs/tool-registry.md) | the manifest format, and the calling convention |
| [docs/architecture.md](docs/architecture.md) | the shape, frozen |
| [HANDOFF.md](HANDOFF.md) | the original question, and the six experiments |

Work is tracked as
[GitHub issues](https://github.com/tosinamuda/vivarium/issues), in sprints.
Verified on SBCL 2.6.7 / macOS ARM64.
