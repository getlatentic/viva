# viva

An experimental agent harness in Common Lisp, for long work and many agents.

Most coding agents live and die with a terminal window. viva runs the work in
a daemon. Sessions survive a closed lid, a dropped network, a restart of the
client, and a restart of the daemon. You reattach and the conversation is
still there, under the same id.

- Close the terminal and the turn keeps going.
- Restart the daemon and every session comes back, under the same id.
- 200 concurrent sessions cost 20 MB and one thread each.
- Search every session you have ever had, by its text.
- A session spawns scoped children that cannot outlive it.
- It keeps what it learns as files you can read and edit.

```bash
sh install.sh     # needs SBCL; installs Quicklisp if it is absent
viva              # opens this directory's session, or starts one
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
| `Ctrl-B` | show the running sessions beside the page, or hide them |
| `Ctrl-W` | close the tab; the session keeps running |
| `Ctrl-O` | show all of a tool's output, or the first three lines again |
| `Ctrl-L` | what this session has learned |
| `Ctrl-R` | read the session again from the daemon |
| `!` | run a shell command here; the model does not see it |
| `/` | list the commands |
| `Ctrl-C` | stop the running turn; leave when there is none |
| wheel, `PageUp`, `Home`, `End` | move through the transcript |

The page is the transcript, the full width of the screen.

| part | shows |
| --- | --- |
| tab bar | the name, the sessions you opened, each with its state, and a count of the rest |
| sessions | what each running session is about, by the first thing asked in it |
| page | your questions, marked; replies rendered from markdown; each tool call as a titled rule with its result and its time under it |
| workers | a delegate reads as a `worker`, and the calls it makes are drawn inside it |
| welcome | on a session nothing has been said in: the model, what this directory has retained, the earlier sessions here, and the keys |
| running | subagents and delegates, in a column that exists while one runs |
| input edge | model, effort, project, branch, and the share of the context the last request used |

The context share is the count the provider reported. It is not an estimate.

Closing a client removes a subscriber. It does not end the work. If the daemon
goes away, the client reconnects by itself and reads the session again.

What survives what:

| event | the session | the turn that was running |
| --- | --- | --- |
| client closed or crashed | keeps running | keeps running |
| lid closed | paused with the machine | resumes with the machine |
| daemon stopped or killed | comes back when the daemon does, same id | lost; the session says so |
| `session.stop` | ends | ends |

A turn is a thread in the daemon. When the daemon dies, the turn dies with it,
and the transcript holds everything up to the last message written. The
restored session opens with a note that says the turn did not finish.

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
| Lisp tests | 1,925 pass | `viva test` |
| Rust tests | 78 pass | `cargo test --manifest-path tui/Cargo.toml` |
| TLA+ configurations | 23 agree | `./spec/verify.sh` |
| terminal invariants | 33 hold | `python3 tui/conformance.py` |
| recorded sessions replayed through the client | clean | `python3 tui/journal_replay.py` |
| 2 minutes of churn | 6,906 cycles, heap 67 MB flat | `viva soak --minutes 2` |
| 200 sessions | heap 59 MB to 79 MB, 202 threads | the snippet below |
| one streamed token, 10 turns | 4.25 ms | `cargo test --manifest-path tui/Cargo.toml bench -- --nocapture` |
| one streamed token, 400 turns | 4.29 ms | the same |

Threads are the limit, not memory. The frame cost does not grow with the
conversation: the client lays out only the entry that changed.

```lisp
;; With vivarium/daemon loaded and nothing else. The heap before is 59 MB.
(dotimes (n 200) (vivarium.actor:spawn :label "/tmp/x"
                   :agent (vivarium.harness:make-workspace-agent :cwd "/tmp/")))
(round (sb-kernel:dynamic-usage) (* 1024 1024))   ; 79
(length (sb-thread:list-all-threads))             ; 202
```

Eleven of the 23 TLA+ configurations must fail. A proof that stops proving
breaks the run instead of passing quietly. `spec/Recovery.tla` is the one for
a session that outlives its daemon: it names the two hazards, and one of them
is the arrangement the daemon still has.

## What is borrowed

- The agent loop is a port of [Pi](https://github.com/badlogic/pi-mono).
  See [docs/harness-lineage.md](docs/harness-lineage.md).
- The skill format follows Anthropic's Agent Skills.
- The tool format follows MCP. `viva mcp` serves the registry to any client.
- The Rust client draws with ratatui and parses markdown with pulldown-cmark.

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
tui/                 the Rust client, and three checks that drive it over a pty
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
