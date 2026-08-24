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
| `pi/` | [badlogic/pi-mono](https://github.com/badlogic/pi-mono) | TypeScript — viva's lineage |
| `opencode/` | [sst/opencode](https://github.com/sst/opencode) | TypeScript |
| `deepseek-harness/` | [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | TypeScript, everything-is-a-plugin over [Cordis](https://github.com/cordiverse/cordis) |

Claude Code appears in the tables below and is **not** cloned: it is closed
source, and every claim about it here comes from its own instruction surface
as a running harness, which is weaker evidence than the source of the other
four. Where its internals are unknown, the cell says so.

Two unrelated projects are called opencode: `sst/opencode` (TypeScript) is the
one here; `opencode-ai/opencode` (Go) is a different thing with the same name.
The DeepSeek docs live at `deepseek-harness.github.io` but the code is under
the `deepseek-ai` org, which is why searching the obvious name finds nothing.

## Rules

Nothing here is edited, imported, or copied. It is read. Anything worth taking
is reimplemented and attributed in a commit message, and anything not taken is
worth saying why — `docs/harness-lineage.md` is where Pi's divergences already
live.

A claim in this file names the file and line it was read from. Three claims
that used to sit here were written from our own documentation instead, and the
clones falsified all three; the sections below record what the source says.

## Retention: who decides that something is worth keeping

The axis this project calls Level 3, and the one where reading the clones cost
the most: **the harness-owns-WHEN design is not unique to viva. Codex
ships it.**

| | decides WHEN | artifact | graduation rule | survives restart |
|---|---|---|---|---|
| Codex | **the harness** — background pipeline at root-session start | `MEMORY.md`, `memory_summary.md`, `skills/` with executable `scripts/` | "procedure repeats (more than once)" → skill | yes, git-baselined |
| Claude Code | **the model**, plus an explicit user command | memory files + an index; skills may carry scripts | none mechanised (observed) | yes, files |
| viva | **the harness** — one bounded turn at task end | memory line, `.viva/skills/`, `.viva/tools/` | evidence of prior reuse, tier 2 → tier 3 | yes, files |
| deepseek-harness | nobody — a repo rule the model is told to obey | Agent Notes, CI-gated | n/a | yes, files |
| opencode | n/a — consumes skills, authors none | — | — | — |
| pi | none | — | — | — |

### What Codex actually does

`codex-rs/memories/README.md`. Triggered when a root session starts — not
ephemeral, not a sub-agent, feature enabled, state DB available — and runs
asynchronously in the background, in two phases.

- **Phase 1, per-thread extraction.** Claims a bounded set of recent, idle
  rollouts from a state DB under a lease, filters each to memory-relevant
  items, sends it to a model, and stores a structured `raw_memory` plus a
  `rollout_summary`. Secrets redacted. Failures get retry backoff rather than
  a hot loop.
- **Phase 2, global consolidation.** One global lock. Ranks stage-1 outputs by
  **`usage_count`, then `last_usage`**, drops anything outside
  `max_unused_days`, syncs artifacts under `~/.codex/memories/` — a git
  baseline directory — prunes stale summaries, writes a `git`-style workspace
  diff, and spawns a consolidation sub-agent (no approvals, no network, local
  write only) pointed at that diff to update `MEMORY.md`, `memory_summary.md`
  and `skills/`.

Their consolidation prompt carries the graduation rule this project derived
from KC6, in the same words:

> "Create a skill when the procedure repeats (more than once) and clearly
> saves time or reduces errors for future agents."
> — `codex-rs/memories/write/templates/memories/consolidation.md:705`

and their skill layout carries the executable tier:
`scripts/<tool>.*  # optional; executed, not loaded (prefer stdlib-only)`.

So harness-owns-WHEN, model-owns-WHAT, route by shape, graduate on reuse,
count usage, prune what does not pay — all six, in production, backed by a
database and a git baseline. What Codex does **not** do is promote a skill
into a registered, named, versioned tool that runs with the model out of the
loop; its terminal artifact is a text package a model reads.

The consequence for this repository is not that the reflection turn was
wrong. It is that its novelty claim was, and the baseline moved: the honest
control for a retention experiment is now Codex's pipeline, not the KC6
zero-investment null.

## The live door: deepseek-harness built it, in TypeScript, and refused to promote it

`packages/extensions/tool-cordis/README.md` and the design note at
`.agents/notes/implemented/feature/2026-07-08-self-referential-cordis-toolset.md`.
Five model-facing tools over the live runtime the agent is running inside:
`cordis_inspect`, `cordis_define`, `cordis_run`, `cordis_stop`,
`cordis_undefine`. That is this project's door, in another language.

Three parts worth taking seriously:

- **A generated API catalog.** Their stated problem: model-written code has to
  call service APIs whose source it has never seen, and "guessed method
  signatures and, worse, guessed return-value shapes cost many steps of blind
  probing." So `cordis_inspect` serves a generated, freshness-gated projection
  of every service signature and event, intersected with the live service
  store — what is RUNNING from the store, what it CAN DO from the catalog.
  A JSDoc edit that does not regenerate the catalog fails a gate.
- **Composition is the point, not registration.** They explicitly rejected a
  structured `register_tool` verb in favour of one mount primitive, because a
  registration payload cannot express one capability depending on another.
  Mounts relate through ordinary `provide`/`inject`: unmounting A returns B to
  pending with its registrations unwound.
- **No promotion, by decision.** "They create no Plugin file, install no
  package, change no `cordis.yml` … do not survive restart, and cannot be
  promoted automatically. To keep an experiment, ask the Agent to implement a
  normal Plugin through the regular development workflow."

That last line is KC6's verdict reached independently — and they shipped the
ephemeral half anyway, because mid-session composition is where it pays. It is
the same residual claim `docs/retention-policy.md` narrowed to.

### Python drives; TypeScript extends

`python/sdk/README.md`. The Python SDK does not extend the harness in Python.
It launches a bundled single-file `dsh-jsonrpc-agent` executable and drives it
over JSON-RPC stdio; the plugin composition it runs is a Cordis YAML of
TypeScript plugins. Python is a **client language**, TypeScript is the
**extension language**, and the two never meet in the same artifact.

Read against KC6's 32% fluency tax — every point of which traced to coupling
"registered tool" to "compiled into the SBCL image" — this is the same split
`docs/retention-policy.md` ratified: drive from whatever the caller writes,
extend in whatever the model writes best.

## Long-running commands

Three designs, and they are not variations on one idea:

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
- **viva** — `bash` with `background: true`, plus a `jobs` tool that
  lists, reads and stops. Chosen because this daemon is long-lived: in Pi the
  process ends with the session, so a background server dies with it, while
  here a job outlives the turn and needs a name, a log and a stop.

Codex's default is the inverse of the other two. Pi and viva both run a
command in the foreground and treat backgrounding as the special case -- `&`
in Pi, `background: true` here. Codex backgrounds unconditionally and treats
*waiting* as the special case. That single choice subsumes both of viva's
mechanisms: a `jobs` tool is what a process handle already is, and streaming
is what a read loop already does.

What viva is missing, found by reading Pi rather than by reasoning:
`env:exec` collects output into a string and returns only at the end, so a
slow command shows nothing and then everything. That is why one felt like a
hang — and part of why background jobs got reached for at all. Issue #35.

**Killing the tree, not the process**, is the one point all four agree on:
`sh -c "npm run dev"` is a shell whose child holds the port. Pi calls
`killProcessTree`, viva kills the process group, and both arrived there
the same way.

## Abort in flight is not a differentiator

Pi passes its `AbortSignal` into the streaming fetch —
`pi/packages/ai/src/api/openai-completions.ts:323`, `:332`, with
`options?.signal?.aborted` deciding the stop reason at `:665`. Pi can end a
completion mid-generation. Any harness that hands a signal to an HTTP client
can; nothing about it belongs to a language, and viva's 168× measurement
is a measurement of stopping early rather than of being fast.

One line of policy does differ, and it should be described as policy. Pi polls
steering at the **end** of an iteration (`agent-loop.ts:259`), so a steer that
arrives mid-generation waits out the current request, and its abort ends the
run (`agent-loop.ts:196`: `stopReason === "aborted"` returns). viva's
`abort-on-steer` ends the request the steer interrupted and **re-enters the
loop carrying it**. Abort-and-resume against abort-and-stop — real, small, and
reimplementable in an afternoon by anyone who wants it.

## What survives the comparison

Stated narrowly, because the wide version was wrong:

> Codex has retention with no live execution. deepseek-harness has live
> execution with no retention, by explicit decision. viva holds both
> halves, which makes it the one place the composition claim can be tested:
> does a capability that graduates *mid-task*, and can be called by another
> capability, beat a text skill re-derived each time?

Four things this changes about the KC6 re-pose, each from a source above:

1. **Tier 3 in a language the model writes fluently** — script plus manifest,
   never an in-image Lisp compile. Both reference harnesses concluded this
   independently; KC6 priced the violation at 32%.
2. **The regime has to be one where the door can win**: high use counts,
   expensive re-derivation, composition depth of at least two. Five cheap
   tasks measured the install cost and nothing else.
3. **The control is Codex's pipeline**, not our own null. Usage-ranked,
   pruned, git-baselined text retention is a far harder bar than zero.
4. **Take the API catalog before the door.** Their problem #2 — a model
   blind-probing signatures it cannot read — arrives here the moment tools
   start calling tools, and their fix is a generated artifact behind a
   freshness gate, not a hand-written table.

TLA+ does not appear in this comparison, and that is the finding: no other
harness makes machine-checked lifecycle claims, and none of them needs to in
order to compete. It is a development-cost advantage for a small team, not a
product difference, and positioning that leans on it is leaning on the wrong
thing.

## herdr: what it costs not to own the agent

`herdrdev/herdr`, read 2026-08-21. Rust, Apache-2.0, "the runtime your coding
agents live on" — a background server that owns the terminals of *other
people's* agents: claude code, codex, cursor, opencode, grok. tmux-style
prefix keys, panes marked working/blocked/idle, sessions that survive a closed
lid and a dropped network, reattach over ssh, and a socket API through which
agents spawn panes, prompt each other, and wait until another is genuinely
blocked.

That last list is uncomfortably close to this project's daemon, cells, and the
peer messaging #15 specifies. The overlap is real and should be said plainly.
The difference is not features. It is what the two systems can *know*.

### herdr vendors an emulator, and #45 said not to

| | |
|---|---|
| `vendor/libghostty-vt` | 698 Zig files, vendored with local patches |
| `src/raw_input.rs` | 3,118 lines of key decoding and re-encoding |
| `src/detect/manifests/` | 20 per-agent TOML rulebooks, 112 detection rules |
| `src/detect/manifest_update.rs` | 778 lines to keep those rulebooks current |

#45 ruled against embedding libghostty and herdr embeds it. That looks like a
refutation and is the opposite of one, because the reason is visible in the
code: **herdr must emulate a terminal because it hosts programs it did not
write.** All it has of a foreign agent is the bytes that agent paints. To know
whether Claude Code is working, herdr parses the pane into cells and matches
rules against them:

```toml
[[rules]]
id = "osc_title_working"
state = "working"
region = "osc_title"
regex = ['^[\x{2800}-\x{28FF}] ']
```

That is a braille range. **herdr detects that an agent is working by
regex-matching its spinner.** Then it debounces the answer — three
confirmations, 100 ms apart, capped at 700 ms, with a three-second startup
grace — because screen-scraping is noisy. And it ships a versioned manifest per
vendor with an auto-updater, because every agent's interface changes whenever
its vendor feels like it.

None of this is bad engineering. It is *excellent* engineering, and it is the
irreducible cost of the position herdr chose.

### The finding

**herdr infers agent state from pixels. Viva reads it off the protocol.**

`turn.started`, `turn.completed`, `tool.started` are events on a socket, and
`busy` is a field. There is no emulator, no braille regex, no debounce, no
per-vendor rulebook, and nothing to auto-update when somebody changes their
spinner — because the agent is ours and it says what it is doing.

So #17 is stronger than it was written. It says *ride the multiplexer, do not
build one*. The sharper statement is: **the emulator is downstream of not
owning the agent.** herdr had to vendor libghostty because it multiplexes
foreign processes. Anything that owns its agent does not need one, and
anything that vendors one is telling you it does not own its agent.

### What that costs us, said honestly

herdr works with every agent, including ones that do not exist yet. Its
20 manifests are the price of a generality viva does not have and is not
buying: `viva live` drives viva and nothing else. That is a narrower
product, and the narrowness is what buys the exact state.

A person who wants Claude Code, Codex and viva in one grid wants herdr, and
should have it — with a viva pane in it. That is #17 working as ratified,
and it is why viva must not grow a pane manager.

### TUI strategies, three ways

| | rendering | input |
|---|---|---|
| herdr | ratatui + crossterm, over a vendored libghostty-vt | 3,118 lines; tracks the kitty flags *inner* programs push, and re-encodes for them |
| opencode | `@opentui` + Solid.js — a reactive component tree with the terminal as render target | opentui's keymap layer |
| viva | own double-buffered screen, changed runs only, 0 bytes on an unchanged frame | 145 lines; pushes kitty flags to the *outer* terminal as a client |

herdr's ratatui buffer does what `src/tui/screen.lisp` does — two buffers,
diffed, emit the difference. Arriving at the same structure independently is
mild evidence it is the right one; it is certainly not novel, and the roadmap
should not claim it is.

The input asymmetry is the interesting half. herdr *observes* kitty keyboard
flags because it sits between a terminal and a program and must speak both
sides. Viva *pushes* them because it is a client of somebody else's
terminal. Same protocol, opposite ends, and the size difference — 3,118 lines
against 145 — is that asymmetry, not craft.
