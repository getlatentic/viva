# viva

viva is an experimental agent harness for persistent, self-extending agents.
Sessions persist beyond the terminal. Agents extend their environment in two
different ways. One is temporary: they compile new behaviour into the running
Common Lisp image. The other is durable: they write notes, skills and tools
into the workspace for later sessions to reuse.

Most harnesses treat a run as disposable. The process starts and the model
works with the tools it was given. When the run ends, whatever was useful
survives only as files or conversation history.

The experiment is whether agents benefit from turning the work they do into
capabilities they can reuse. The alternative is solving the same class of
problem from a fixed harness every time. The answer is not assumed. Each
experiment fixes its comparison and its kill criterion before it runs, and the
repository keeps the negative results beside the positive ones.

![Sessions on the left, the transcript on the right, each tool call a titled rule with its result beneath it](docs/viva.png)

- Sessions run in the background and reattach by id.
- Closing the terminal does not end a running turn.
- One client works with many concurrent sessions.
- 200 idle sessions share about 20 MB of heap and use one thread each.
- Full-text search spans every session recorded, in every directory.
- A session spawns scoped child agents that cannot outlive it.
- Live-image modification is off by default.
- `viva shell --capabilities on` enables it for the shell harness.
- `viva trust` gates a project's own tools before a later session can call them.

## What persists

Three continuities, and they are three different mechanisms.

**Conversation.** Session state lives in the daemon. A client can disconnect
and later reattach to the same session and transcript, under the same id.
Closing a client removes a subscriber rather than ending the work, and a client
whose daemon goes away reconnects by itself.

| event | the session | the turn that was running |
| --- | --- | --- |
| client closed or crashed | keeps running | keeps running |
| lid closed | pauses with the machine | resumes with the machine |
| daemon stopped or killed | comes back, same id | lost; the session says so |
| `session.stop` | ends | ends |

A turn is a thread in the daemon. When the daemon dies, the turn dies with it,
and the transcript holds everything up to the last message written.

**Capability.** An agent writes notes, skills and tools into the workspace as
ordinary project files. Those files survive a process restart, and a later
session reuses them once you have run `viva trust` on the project.

**Execution.** With capabilities enabled, an agent compiles a function into the
running Common Lisp image and invokes it immediately. That function lives only
in that image. viva records its lineage in the journal, and it does not
reconstruct the compiled function after a restart.

The third is deliberately not durable yet.

```text
                       viva
                        │
          ┌─────────────┴─────────────┐
          │                           │
     persistent work             self-extension
          │                           │
      daemon/session          ┌───────┴────────┐
                              │                │
                         live image        workspace
                         transient          durable
                              │                │
                         functions       notes / skills /
                                           tools
```

Common Lisp makes the live half of the experiment practical. Its image model
lets an agent define, compile, install and invoke new behaviour without
crossing an edit-build-restart boundary. Durable reuse is a separate mechanism,
and it goes through workspace files.

## Install

```bash
sh install.sh     # needs SBCL; installs Quicklisp if it is absent
viva              # opens this directory's session, or starts one
```

Or take the binaries. CI builds `viva-macos-arm64` and `viva-linux-x86_64`,
which need neither SBCL nor Quicklisp nor a checkout. Put `viva` and `viva-tui`
in one directory on your `PATH`: `viva` finds the full-screen client beside it.

```bash
install -m 755 viva-macos-arm64 ~/.local/bin/viva
install -m 755 viva-tui ~/.local/bin/viva-tui
```

### A provider key

```bash
mkdir -p ~/.viva && cat > ~/.viva/auth.json <<'JSON'
{ "deepseek": { "apiKey": "sk-..." } }
JSON
```

Three places, tried in this order. A flag names one key for one run. The file
is where somebody put a key on purpose, and the environment is whatever a shell
happened to export.

| | |
| --- | --- |
| `--api-key` | this run only |
| `~/.viva/auth.json` | `deepseek`, `openai`, `openrouter`, `bedrock` |
| `DEEPSEEK_API_KEY` and friends | the environment |

Keys are not settings: `config` is a file people copy into projects and commit,
and `auth.json` is not.

### Windows

Run it under WSL. Both ends talk over a unix socket, and Windows has none, so
the daemon does not build there.

```powershell
wsl --install               # PowerShell, once, then reboot
```

```bash
git clone <this repo> ~/viva     # inside the Ubuntu shell
cd ~/viva && sh install.sh
```

Keep the checkout inside the WSL filesystem. A path under `/mnt/c/` sends every
file read across the Windows boundary. CI does not test WSL. It tests the Linux
build that WSL runs.

## Run

| command | what it does |
| --- | --- |
| `viva` | full screen: sessions, transcript, tasks |
| `viva attach` | line oriented, for pipes and diffs |
| `viva learned` | what this directory has retained |
| `viva sessions` | every recorded conversation here |
| `viva daemon status` | the long lived process |

Keys inside the full screen client. Press `/` for the commands.

| key | action |
| --- | --- |
| `Ctrl-P` | find any session, running or not; type to narrow |
| `Ctrl-N` | start a session in a new tab |
| `Ctrl-W` | close the tab; the session keeps running |
| `Ctrl-O` | show all of a tool's output, or the first three lines again |
| `Ctrl-L` | what this session has learned |
| `Ctrl-B` | put the sessions column away, or bring it back |
| `!` | run a shell command here; the model does not see it |
| `Ctrl-C` | stop the running turn; leave when there is none |

## What it keeps, and where

| tier | written to | reaches the model as |
| --- | --- | --- |
| note | `.viva/MEMORY.md` | prompt text |
| skill | `.viva/skills/<name>/SKILL.md` | prompt text |
| tool | `.viva/tools/<name>/tool.json` | the tool list, and MCP |

Everything viva keeps for itself is under `~/.viva/`: `auth.json`, `config`,
`sessions/`, `journal/`, `trusted.sexp`. `VIVA_HOME` names that directory
outright.

A fact becomes a note. Code becomes a skill. Code the agent has already wanted
twice becomes a tool it calls by name. The agent writes these with the ordinary
`write` tool, and you can author one by hand in the same format. `~/.viva/`
applies to every directory, and the project directory wins on a name clash.

## Self-improvement experiments

Where the answer stands today. Each entry links to the run that produced it.

- [x] **Retention on real work.** 25 tasks, five recurring job shapes, policy
  on. It retains, and what it retains is good: 5 artifacts, 4 of 5 worth
  keeping on a cold review. Later tasks called the one tool it built five
  times. [Results](experiments/dogfood/RESULTS.md).
- [x] **Does retention pay?** Not yet, and honestly split. The corpus improved
  8.2% against a 20% threshold, and one job shape got 18% worse. Averaging
  those into a win is the thing the threshold exists to prevent.
- [x] **Live self-modification** — compiling retained code into the running
  Lisp image, mid-task. Killed on the pre-registered rule. Carrying the door
  costs about 23% in tokens even when nothing opens it. The cleanest, most
  fluent use in the battery still cost 43% to 73% more.
  [Results](experiments/kc6/RESULTS.md).
- [x] **Will a model invest if you let it?** Not on its own. Across 45
  task-runs with the door open, every arm made zero `remember` calls and wrote
  no `MEMORY.md`. Re-running under explicit framing did not move it.
- [ ] **Composition** — does a capability that calls another capability beat a
  text skill re-derived each time? This needs both retention and live
  execution in one harness, which is why it is testable here.
  [Pre-registration](docs/b15-preregistration.md).
- [ ] **A Lisp-fluent model.** 19 of 59 self-modification attempts failed to
  compile, which measures the model rather than the mechanism. The current
  pin forbids the probe.
- [ ] **Ergonomics on the door** — shipping an idiom guide in the tool
  descriptions, since a door's ergonomics include its language.
- [ ] **Rehydrating a live capability** — does reconstructing a minted
  function after a restart beat simply reloading the file-backed tool? Held
  until a result gives a reason to build it.

What the record supports so far: **retention pays where the work is mechanical
and recurs, and costs where the work is judgment.** The round trip is the
expense, not the language. Short tasks have no derivation cost to amortise an
artifact against.

[docs/self-improvement-model.md](docs/self-improvement-model.md) states the
model behind them.

## Files

```
bin/viva             the launcher
src/core/            messages, tools, the agent loop
src/workspace/       skills, registry, memory, reflection
src/daemon/          sessions as actors, the socket, the task tree
src/tui/             the Lisp full screen client
tui/                 the Rust client, and three checks that drive it over a pty
spec/                TLA+ specifications and their configurations
experiments/         pre-registrations, runs, and results
tools/               the image build, and the checks that need a terminal
docs/                design decisions and comparisons
```

```bash
viva test                                   # the Lisp suite
cargo test --manifest-path tui/Cargo.toml   # the client
./spec/verify.sh                            # the TLA+ configurations
```

CI runs all three on macOS and Linux, builds a standalone binary on each, then
starts a daemon with the binary it built and asks it for its sessions. An
artifact that cannot serve fails the build. Eleven of the 23 TLA+
configurations must fail: a proof that stops proving breaks the run instead of
passing quietly.

## Acknowledgements

- The agent loop is a port of [Pi](https://github.com/badlogic/pi-mono).
  [docs/harness-lineage.md](docs/harness-lineage.md) names what came from Pi
  and what this project added.
- The skill format follows Anthropic's Agent Skills.
- The tool format follows MCP. `viva mcp` serves the registry to any client.
- The Rust client draws with [ratatui](https://ratatui.rs) and parses markdown
  with pulldown-cmark.
- The Lisp engine runs on SBCL.

## Status

Still in development, as a research harness.
