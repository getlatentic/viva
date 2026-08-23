# vivarium

A coding agent that extends itself by writing files you can read.

- It keeps what it works out. Code it has already wanted twice becomes a
  tool it calls by name.
- The files are the interface. You can read, edit, or delete any of them.
- Sessions outlive the terminal, so you can reattach later.
- TLA+ proves the session lifecycle, the task tree, and the replay barrier.

```bash
sh install.sh     # needs SBCL; installs Quicklisp if it is absent
viva              # opens a session in the current directory
```

## Run it

```bash
viva                       # full screen, on a terminal
viva attach                # line oriented; pipes and diffs
viva learned               # what this directory has retained
viva daemon status         # the long lived process
```

`viva` starts the daemon if none runs. Both names work: `viva` and `vivarium`.

## What it retains, and where

| tier | written to | reaches the model as |
| --- | --- | --- |
| note | `MEMORY.md` | prompt text |
| skill | `.vivarium/skills/<name>/SKILL.md` | prompt text |
| tool | `.vivarium/tools/<name>/tool.json` | the tool list, and MCP |

Each tier also reads from `~/.vivarium/`, which applies to every directory.
The project directory wins when both define the same name.

The agent writes these with the ordinary `write` tool. No special verb exists.
You can author one by hand in the same format.

A tool that declares parameters must answer a describe request. Registration
refuses a manifest that the script cannot satisfy, and names the field.

## Measured

Run each command yourself. The numbers below come from these runs.

| what | number | command |
| --- | --- | --- |
| Lisp tests | 1,879 pass | `viva test` |
| Rust tests | 30 pass | `cargo test --manifest-path tui/Cargo.toml` |
| TLA+ configurations | 20 agree | `./spec/verify.sh` |
| terminal invariants | 23 hold | `python3 tui/conformance.py` |
| 200 concurrent sessions | 106 MB, 202 threads | see below |
| 614,048 churn cycles | heap 64 MB to 65 MB | `viva soak` |

A session costs one thread. Memory is not the limit. Threads are.

To repeat the session measurement, spawn cells and read the heap:

```lisp
(dotimes (n 200) (vivarium.actor:spawn :label "/tmp/x"
                   :agent (vivarium.harness:make-workspace-agent :cwd "/tmp/")))
(round (sb-kernel:dynamic-usage) (* 1024 1024))   ; 106
(length (sb-thread:list-all-threads))             ; 202
```

## What is borrowed

- The agent loop is a port of [Pi](https://github.com/badlogic/pi-mono).
  See [docs/harness-lineage.md](docs/harness-lineage.md).
- The skill format follows Anthropic's Agent Skills.
- The tool format follows MCP. `viva mcp` serves the registry to any client.

Other harnesses retain too. Codex ships a retention pipeline with usage
ranking and pruning. Read [docs/harness-comparison.md](docs/harness-comparison.md)
for what each one does, with citations.

## What failed

Kill criterion 6 tested compiling retained code into the live Lisp image.
It lost on all 6 families and cost about twice as much as text.

The detail matters. 19 of 59 attempts failed to compile, which measures the
model's Common Lisp fluency. One family used the door with zero failures and
still cost 43% to 73% more. The round trip is the cost, not the language.

[experiments/kc6/RESULTS.md](experiments/kc6/RESULTS.md) carries the numbers.

## Files

```
bin/vivarium         the launcher; resolves its own symlinks
src/core/            messages, tools, the agent loop
src/workspace/       skills, registry, memory, reflection
src/daemon/          sessions as actors, the socket, the task tree
src/tui/             the Lisp full screen client
tui/                 the Rust client, on ratatui
spec/                TLA+ specifications and their configurations
experiments/         pre-registrations, runs, and results
docs/                design decisions and comparisons
```

## Status

This is a research harness. The experiments measure the retention policy.
Nobody has run the composition experiment yet. See
[docs/b15-preregistration.md](docs/b15-preregistration.md).

It runs on macOS. Nobody has tested Linux. Windows does not build.
