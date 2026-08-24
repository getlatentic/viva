# viva

An experimental agent harness in Common Lisp. The work runs in a daemon, so a
session outlives the terminal that started it.

![Sessions on the left, the transcript on the right, each tool call a titled rule with its result beneath it](docs/viva.png)

- Close the terminal and the turn keeps going.
- Restart the daemon and every session comes back, under the same id.
- 200 sessions share 20 MB of heap and take one thread each.
- Search every session you have ever had, by its text.
- A session spawns scoped children that cannot outlive it.
- It keeps what it learns as files you can read and edit.

## Install

```bash
sh install.sh     # needs SBCL; installs Quicklisp if it is absent
viva              # opens this directory's session, or starts one
```

Or take one file. CI builds `viva-macos-arm64` and `viva-linux-x86_64`, which
need neither SBCL nor Quicklisp. CI starts a daemon with the file it built,
asks that daemon for its sessions, then stops it. An artifact that cannot serve
fails the build.

### Windows

Run it under WSL. Both ends talk over a unix socket, and Windows has none, so
the daemon does not build there. `.github/workflows/windows-probe.yml` measures
what a Windows runner has: SBCL installs, SB-POSIX supplies 12 of the 20 calls
this code makes, and the client hits 6 compile errors, every one `std::os::unix`.

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

Closing a client removes a subscriber. It does not end the work. If the daemon
goes away, the client reconnects by itself and reads the session again.

| event | the session | the turn that was running |
| --- | --- | --- |
| client closed or crashed | keeps running | keeps running |
| lid closed | pauses with the machine | resumes with the machine |
| daemon stopped or killed | comes back, same id | lost; the session says so |
| `session.stop` | ends | ends |

A turn is a thread in the daemon. When the daemon dies, the turn dies with it,
and the transcript holds everything up to the last message written.

## What it keeps, and where

| tier | written to | reaches the model as |
| --- | --- | --- |
| note | `MEMORY.md` | prompt text |
| skill | `.vivarium/skills/<name>/SKILL.md` | prompt text |
| tool | `.vivarium/tools/<name>/tool.json` | the tool list, and MCP |

A fact becomes a note. Code becomes a skill. Code the agent has already wanted
twice becomes a tool it calls by name. The agent writes these with the ordinary
`write` tool, and you can author one by hand in the same format. `~/.vivarium/`
applies to every directory, and the project directory wins on a name clash.

## Measured

Run each command yourself. The numbers come from these runs, and CI repeats
every one of them on macOS and Linux.

| what | number | command |
| --- | --- | --- |
| Lisp tests | 1,930 pass | `viva test` |
| Rust tests | 85 pass | `cargo test --manifest-path tui/Cargo.toml` |
| TLA+ configurations | 23 agree | `./spec/verify.sh` |
| undefined variables | none, in 8 systems | `sbcl --script tools/check-warnings.lisp` |
| terminal invariants | 33 hold | `python3 tui/conformance.py` |
| recorded sessions replayed | clean | `python3 tui/journal_replay.py` |
| 2 minutes of churn | 6,906 cycles, heap 67 MB flat | `viva soak --minutes 2` |
| 200 sessions | heap 59 MB to 79 MB, 202 threads | the snippet below |
| one streamed token | under 1 ms, flat from 10 turns to 400 | `cargo test --release --manifest-path tui/Cargo.toml bench -- --nocapture` |

Threads are the limit, not memory. Frame cost does not grow with the
conversation. The client lays out only the entry that changed.

```lisp
;; With vivarium/daemon loaded and nothing else. The heap before is 59 MB.
(dotimes (n 200) (vivarium.actor:spawn :label "/tmp/x"
                   :agent (vivarium.harness:make-workspace-agent :cwd "/tmp/")))
(round (sb-kernel:dynamic-usage) (* 1024 1024))   ; 79
(length (sb-thread:list-all-threads))             ; 202
```

Eleven of the 23 TLA+ configurations must fail. A proof that stops proving
breaks the run instead of passing quietly. `spec/Recovery.tla` covers a session
that outlives its daemon.

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
tools/               the image build, and the checks that need a terminal
docs/                design decisions and comparisons
```

## Borrowed

- The agent loop is a port of [Pi](https://github.com/badlogic/pi-mono).
  See [docs/harness-lineage.md](docs/harness-lineage.md).
- The skill format follows Anthropic's Agent Skills.
- The tool format follows MCP. `viva mcp` serves the registry to any client.
- The Rust client draws with ratatui and parses markdown with pulldown-cmark.

Other harnesses retain too. [docs/harness-comparison.md](docs/harness-comparison.md)
says what each one does, with citations.

## Status

A research harness. The experiments measure the retention policy, and nobody
has run the composition experiment yet:
[docs/b15-preregistration.md](docs/b15-preregistration.md).

Retention is not yet an improvement. Kill criterion 6 tested compiling retained
code into the live Lisp image. It lost on all 6 families and cost about twice
as much as text: [experiments/kc6/RESULTS.md](experiments/kc6/RESULTS.md).

The code still says `vivarium` inside. Only the command is `viva`.
