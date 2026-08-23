# viva

An experimental agent harness in Common Lisp, for long work and many agents.

Most coding agents live and die with a terminal window. viva runs the work in
a daemon. Sessions survive a closed lid, a dropped network, and a restart of
the client. You reattach and the conversation is still there.

- Close the terminal and the turn keeps going.
- 200 concurrent sessions cost 106 MB and one thread each.
- Search every session you have ever had, by its text.
- A session spawns scoped children that cannot outlive it.
- It keeps what it learns as files you can read and edit.

```bash
sh install.sh     # needs SBCL; installs Quicklisp if it is absent
viva              # opens a session in the current directory
```

## Live with it

```bash
viva                       # full screen: sessions, transcript, tasks
viva attach                # line oriented; pipes and diffs
viva learned               # what this directory has retained
viva sessions              # every recorded conversation here
viva daemon status         # the long lived process
```

Inside the full screen client:

| key | action |
| --- | --- |
| `Ctrl-P` | find any session, running or not; type to narrow |
| `Ctrl-N` | start a session in a new tab |
| `Ctrl-W` | close the tab; the session keeps running |
| `Ctrl-L` | what this session has learned |
| `/` | list the commands |
| `Ctrl-C` | stop the running turn; leave when there is none |

Closing a client removes a subscriber. It does not end the work.

## What it keeps, and where

| tier | written to | reaches the model as |
| --- | --- | --- |
| note | `MEMORY.md` | prompt text |
| skill | `.vivarium/skills/<name>/SKILL.md` | prompt text |
| tool | `.vivarium/tools/<name>/tool.json` | the tool list, and MCP |

A fact becomes a note. Code becomes a skill. Code the agent has already
wanted twice becomes a tool it calls by name.

The agent writes these with the ordinary `write` tool. You can author one by
hand in the same format. `~/.vivarium/` applies to every directory, and the
project directory wins when both define the same name.

## Measured

Run each command yourself. The numbers come from these runs.

| what | number | command |
| --- | --- | --- |
| Lisp tests | 1,879 pass | `viva test` |
| Rust tests | 30 pass | `cargo test --manifest-path tui/Cargo.toml` |
| TLA+ configurations | 20 agree | `./spec/verify.sh` |
| terminal invariants | 23 hold | `python3 tui/conformance.py` |
| 614,048 churn cycles | heap 64 MB to 65 MB | `viva soak` |
| 200 sessions | 106 MB, 202 threads | the snippet below |

Threads are the limit, not memory.

```lisp
(dotimes (n 200) (vivarium.actor:spawn :label "/tmp/x"
                   :agent (vivarium.harness:make-workspace-agent :cwd "/tmp/")))
(round (sb-kernel:dynamic-usage) (* 1024 1024))   ; 106
(length (sb-thread:list-all-threads))             ; 202
```

Eight of the 20 TLA+ configurations must fail. A proof that stops proving
breaks the run instead of passing quietly.

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
bin/vivarium         the launcher; `viva` links to it
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

The code still says `vivarium` inside. Only the command is `viva`.
