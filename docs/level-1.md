# Level 1 — a harness that can do ordinary work

[The roadmap](roadmap.md) says the project drifted into perfecting a six-account
Lisp benchmark while the harness still could not edit a file. This is the file
that stopped being true.

Vivarium now has a second world alongside the live image: a **directory**. It
reads, writes and edits files, searches a repository, runs commands, loads
skills, keeps memory, and takes extensions. It runs as a library, as an
interactive shell, and as an IPC server.

## Where it came from

Pi (`badlogic/pi-mono`, MIT) was read and replicated rather than invented from
scratch, for the same reason the agent loop was ported from it in the first
place: an arm that quietly diverges from its control is worse than no control.
The tool names, the argument names, and the output limits are Pi's — 2000 lines
or 50KB per read, whichever comes first — so that a comparison of the two
harnesses is a comparison of harnesses and not of context budgets.

What is deliberately **not** copied is Pi's TUI, its session tree with branch
summarisation, its provider catalogue, and the parts of its extension API that
exist to paint widgets. Those are Pi being a finished product. Vivarium needs
the capability, not the surface.

## What exists

```
vivarium/workspace          the library
  env          files and processes, and nothing else: the capability boundary
  glob bound   glob matching, ignore rules, output truncation. No I/O.
  edit         exact replacement, uniqueness and overlap checks, unified diff
  workspace    read write edit ls find grep bash, written against ENV only
  skill        SKILL.md discovery, frontmatter, the system-prompt block
  memory       VIVARIUM.md / AGENTS.md / CLAUDE.md in, MEMORY.md out
  extension    hooks, tool and command registration, per-project trust
  session      the transcript as JSONL, resumable with tool calls intact
  models       one table of endpoints, keys and model ids
  harness      the wiring, and the only file that knows about all of them

vivarium/console            the two run modes, ~350 lines between them
  shell        a line-oriented terminal. Reads stdin, so it also runs a script.
  ipc          JSON objects in, JSON objects out, one per line
```

Eight tools reach the model: `read`, `write`, `edit`, `ls`, `find`, `grep`,
`bash`, `remember` — plus whatever extensions register.

## The three ways to run it

**As a library.** This is the product; the other two are thin wrappers over it,
which is the test of whether it is actually reusable.

```lisp
(let ((agent (harness:make-workspace-agent :cwd "/some/repo"
                                           :provider p :model "deepseek-v4-flash")))
  (harness:ask agent "why does the parser drop trailing commas?"))
```

**As a shell.**

```bash
vivarium shell --cwd ~/work/thing
```

`/help` lists the commands. `!cmd` runs a shell command directly. Because it
reads standard input, a session can be scripted and diffed — which is why it is
line-oriented rather than full-screen.

**Over IPC.**

```bash
echo '{"type":"prompt","message":"what does this repo do?"}' | vivarium ipc --cwd .
```

A prompt runs on its own thread, so `steer` and `abort` mean something: a steer
queued while the model is generating lands in the request already in flight.
Pi and Codex both deliver a steer no earlier than the next request.

**One-shot**, for a script or a CI job:

```bash
vivarium do "the tests are failing, find out why and fix it" --cwd . --quiet
```

## Extensions

An extension is a Lisp file under `.viva/extensions/` (project) or
`~/.viva/extensions/` (machine). Loading it runs it, and its registrations
attribute to it:

```lisp
(defextension "recall"
  :description "Injects relevant past notes before each request."
  (register-tool recall-search)
  (on :before-request #'recall-inject))
```

Hooks: `:before-request`, `:context`, `:before-tool`, `:after-tool`,
`:turn-end`. A handler returning `NIL` observed; returning a value replaces the
payload and threads it into the next handler. One rule covers observation,
transformation and veto.

A project directory is only loaded once its root has been trusted (`/trust` in
the shell), because loading a file executes it and the working tree is exactly
what an untrusted repository controls. The trust record lives outside the
project, where the project cannot edit it.

Two worked examples ship in [`examples/extensions/`](../examples/extensions):

- **`recall.lisp`** — improves memory without touching the harness. It scores
  remembered lines against the words in each prompt and injects the few that
  match, instead of loading a four-hundred-line `MEMORY.md` into every request.
- **`skillsmith.lisp`** — a `write_skill` tool that creates a skill **and
  reloads resources in the same call**, so the skill is in the agent's own
  system prompt on its very next request.

That second one is the smallest complete instance of what this project is about,
and it has been run:

```
› Work out how to run this project's tests, run them once to confirm, then
  record that procedure as a skill named "run-the-tests".
  · bash python3 run_tests.py → OK
  · write_skill run-the-tests
› Which skills do you have available right now? Answer from your own context.
  From my context, I have one skill available right now:
  - run-the-tests — for running this project's test suite before committing.
  It lives at .viva/skills/run-the-tests/SKILL.md
```

No restart, no human, no edit to the harness.

## Vivarium against Pi

Four fixtures, each a repository whose `run_tests.py` fails on arrival. Judged
by whether that test passes afterwards — not by what the agent said it did,
which is the only claim a transcript can make. Same model, same prompt, same
starting tree, `AGENTS.md` as the only instruction file on both sides, no
skills, no extensions, no memory.

```bash
experiments/parity/run.sh --repeats 3
```

| fixture    | what it takes                                          |
|------------|--------------------------------------------------------|
| `median`   | one file, one bug, the failing test already names it    |
| `search`   | the defect is in a file the prompt does not name        |
| `feature`  | implement a function against an existing spec           |
| `two-bugs` | three functions wrong in one file; all must be fixed    |

Both harnesses solve all four, every repeat, on `deepseek-v4-flash`. Vivarium is
consistently two to three seconds slower per task, which is SBCL booting and
loading the system on every `vivarium do` — a startup cost, not a harness one,
and it disappears in `shell` and `ipc` where the image is booted once.

**The result is parity, and parity is the whole point.** Beating Pi on four
fixtures would prove nothing about a harness this young; being unable to match
it would have meant Level 1 was not real. It is real.

## What was actually wrong, and how it was found

Every one of these passed a local unit test and was found only by running the
whole thing.

**`install` was an execution channel** *(found earlier, in the image domain, and
the reason for the rule)*. A local test of a component is not evidence the
consumer can use it.

**The tool schema was malformed and validation did not notice.** `edit` needs an
array of objects; the schema layer could only express an array of scalars, and
emitted `{"type":"array"}` with no `items`. Local validation passed because the
validator had the same gap. Fixed by teaching the schema layer `(:object specs)`
— at the layer that owns both the schema and its validation, so the two cannot
disagree again.

**The diff printed overlapping hunks twice**, and the second showed an
already-replaced line as unchanged context. A diff that contradicts itself.
Fixed by grouping changes whose context windows touch.

**Reloading extensions duplicated every tool.** `defextension` appended rather
than replaced, so `refresh-resources` — which `write_skill` calls — put two
tools named `recall` in the request. The provider rejected it, and the failure
surfaced as a 400 on the request *after* the one that reloaded. Confirmed by
counting tools across three refreshes before changing anything.

**Root confinement bounded the harness, not the agent.** A rooted run refused to
start, one second in, on the home directory's extension folder — a path the
agent had not asked for. Confinement is a property of what the *model* can
reach; the harness reads its own resources through an unconfined environment.

**`/tmp` and `/private/tmp` were different projects.** Paths were resolved
lexically, so a trust record written under one spelling was invisible under the
other, and a trusted project silently refused to load its own extensions.

**A test helper clobbered another file's.** `tests/workspace.lisp` defined
`call-tool`; `tests/suite.lisp` already had one with different semantics, all
test files share one package, and eleven tests in files the new one never
mentions began to fail. Isolated, each passed.

## What this does not do yet

No compaction — a long session will hit the context window and stop rather than
summarise. No session resume from the shell (the transcript is written and can
be read back; nothing reloads it yet). No parallel tool execution: the loop
supports it, but `*environment*` is a dynamic binding that spawned threads do
not inherit, so it stays off until that is fixed properly rather than papered
over. No image support in `read`.

## Where this leaves the levels

Level 1 exists. Level 2's mechanism is demonstrated on the workspace as well as
the image: `skillsmith` is create-and-use with the *skill* as the artifact, in a
world where the artifact outlives the process by construction.

Level 3 is now the honest next question, and it is the one the roadmap named:
give vivarium a repository and a run of ordinary tasks, and ask whether task 20
goes better than task 1.
