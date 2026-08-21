# How four harnesses answer the same questions

Four coding agents, cloned shallow, gitignored, never vendored. Study material
for one recurring question: *when a design decision here looks arbitrary, what
did people who solved it already do?*

The clones themselves live under `third-party/`, which is gitignored --
`./third-party/refresh.sh` fetches them. This file is the part worth keeping:
findings survive a fresh clone, four other projects' history does not.

| | | |
|---|---|---|
| `codex/` | [openai/codex](https://github.com/openai/codex) | Rust |
| `pi/` | [badlogic/pi-mono](https://github.com/badlogic/pi-mono) | TypeScript — vivarium's lineage |
| `opencode/` | [sst/opencode](https://github.com/sst/opencode) | TypeScript |
| `deepseek-harness/` | [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | TypeScript |

Two unrelated projects are called opencode: `sst/opencode` (TypeScript) is the
one here; `opencode-ai/opencode` (Go) is a different thing with the same name.
The DeepSeek docs live at `deepseek-harness.github.io` but the code is under
the `deepseek-ai` org, which is why searching the obvious name finds nothing.

## What the comparison has already settled

**Long-running commands**, which is what prompted the clones. Three designs,
and they are not variations on one idea:

- **Pi** — `bash` takes `command` and an optional `timeout` with *no default*.
  It streams stdout and stderr as they arrive and kills the process tree on an
  AbortSignal. The turn blocks, but you watch it and can stop it, so blocking
  is tolerable. No background option, and it does not need one.
- **Codex** — an exec *server*, and **everything is background by default**.
  `ExecParams` carries no timeout and no wait flag; `ExecResponse` returns only
  a `process_id`, never an exit code or output. So `Exec` starts and returns.
  Output comes from polling:

      ReadParams { process_id, after_seq, max_bytes, wait_ms }

  `after_seq` resumes a numbered stream, `max_bytes` bounds it, `wait_ms` long-
  polls for more. Running a command in the foreground is the *emulated* case --
  the client loops on read until the process ends. One primitive gives
  streaming, bounded output, resumability, and a handle to signal.
- **vivarium** — `bash` with `background: true`, plus a `jobs` tool that
  lists, reads and stops. Chosen because this daemon is long-lived: in Pi the
  process ends with the session, so a background server dies with it, while
  here a job outlives the turn and needs a name, a log and a stop.

Codex's default is the inverse of the other two. Pi and vivarium both run a
command in the foreground and treat backgrounding as the special case -- `&`
in Pi, `background: true` here. Codex backgrounds unconditionally and treats
*waiting* as the special case. That single choice subsumes both of vivarium's
mechanisms: a `jobs` tool is what a process handle already is, and streaming
is what a read loop already does.

What vivarium is missing, found by reading Pi rather than by reasoning:
`env:exec` collects output into a string and returns only at the end, so a
slow command shows nothing and then everything. That is why one felt like a
hang — and part of why background jobs got reached for at all. Issue #35.

**Killing the tree, not the process**, is the one point all four agree on:
`sh -c "npm run dev"` is a shell whose child holds the port. Pi calls
`killProcessTree`, vivarium kills the process group, and both arrived there
the same way.

## Rules

Nothing here is edited, imported, or copied. It is read. Anything worth taking
is reimplemented and attributed in a commit message, and anything not taken is
worth saying why — `docs/harness-lineage.md` is where Pi's divergences already
live.

## What vivarium decided, and why not simply to copy

Take Codex's **mechanism** — a running command is a handle, output is polled —
and neither its model-facing shape nor its lifetime.

**Not its shape.** Codex's `Exec`/`Read`/`Write`/`Signal` is the wire between
its client and its exec-server; the model sees one shell tool, and the *client*
runs the poll loop. Exposing those four as tools would make `ls` cost a poll
loop. The model here keeps seeing one `bash`.

**Not its lifetime.** `ExecParams` says the handle is *"scoped to this
connection/session"*. Codex's processes die with the session, so it never had
the problem `jobs` solves. This daemon runs for hours.

**And one thing beyond it.** Sessions here are actors with mailboxes,
journalled events, and fan-out to every subscriber. A running process given the
same machinery gets replay-from-sequence (which is Codex's `after_seq`, already
built as the journal) and output visible to *every* attached client — which
Codex structurally cannot do, its handles being per-connection.

The care needed: a cell is bound to an agent and its turns, and its states are
about a turn. That is what `spec/CellLifecycle.tla` proves. A process has
neither. Reusing the actor machinery is right; calling a process a cell would
borrow a proof that was never about it.

Staged as Sprint 5, so each step is decided with evidence from the one before:
streaming (#35), then an inbox (#36), then services declared in the germline
(#37) — the retention router's fourth shape, and the one place the organism's
own architecture buys something a better-engineered exec server does not.
