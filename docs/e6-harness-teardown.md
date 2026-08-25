# E6 — production harness teardown

**Status: done.** All four harnesses read. opencode was the last one and it moved
the answer — see [E3](e3-subturn-steering.md).

Not a build — a read. One question only: **what is fixed at turn start versus
re-read per request.** That is [E3](e3-subturn-steering.md)'s baseline, and it is a
fact about these programs rather than something to reason out.

## Four legible sources, and what each is good for

All are on this machine. `~/workspace/harness-test/vendor/` is itself a git repo
holding the vendored trees as plain directories — only `pi` carries its own `.git`,
so a commit hash read inside the others is harness-test's, not upstream's.

| source | form | answers |
|---|---|---|
| Codex | Rust source | turn loop, steering, `TurnContext` |
| Pi | TS source, own git `ac4ac9e` | inner-loop steering; the control arm |
| Claude Agent SDK | Python `0.2.131` + TS source | **what a host may change mid-session** |
| Claude.app | Electron, `app.asar` 39.5 MB plaintext JS | the same protocol, independently |
| opencode | TS source, 137 MB | not yet read |

## The Electron app is a host, not the loop

Worth stating because it looked like the shortcut and is not. `/Applications/Claude.app`
(`com.anthropic.claudefordesktop`, 1.25927.0) is Electron and its `app.asar` extracts
to 404 plaintext JS/JSON files with an ordinary zip-shaped header — far easier to read
than the CLI. But what is *in* it is the **host** side: `control_request`,
`can_use_tool`, `set_permission_mode`, `stream-json`. It drives Claude Code over the
same control protocol the SDK speaks.

The agent loop and request assembly are not there. They remain in the CLI, which is a
Bun-compiled single-file Mach-O at `~/.local/share/claude/versions/2.1.210` — the
bundle sits in the binary uncompressed and is greppable, but it is the only route to
the loop itself.

## What the control protocol answers, which is most of the question

The SDK enumerates every control request the CLI accepts. This is the mutable surface
of a *running* Claude Code session, from the outside, in readable source:

```
initialize          interrupt           stop_task
set_model           set_permission_mode rewind_files
mcp_toggle          mcp_status          mcp_reconnect
get_context_usage
```

**There is no `set_system_prompt` and no `set_tools`.** The model, the permission
mode, and whether a given MCP server is on can all change mid-session. The system
prompt and the tool set cannot.

`mcp_toggle` is the near-miss and the reason to be precise. Its payload is
`(serverName, enabled)` — a whole **pre-registered** server switched on or off. So the
tool list can change mid-session, at server granularity, drawn from what was
registered at startup. What no request does is introduce a tool that did not exist
when the session began.

That is exactly the line [E3](e3-subturn-steering.md) claims to cross, and exactly the
distinction `register_tool` makes: viva's agent installs a `DEFUN` and derives a
tool from the live function, with nothing pre-registered and nothing restarted.

## opencode re-reads both, per request

It did move the baseline, and it is the only one of the four that does.

`prompt.ts:1088` is a plain `while (true)`, one model request plus its tool batch per
iteration. Two things happen **inside** that loop:

- `SessionTools.resolve(...)` at `prompt.ts:1226` — the tool set is rebuilt every
  iteration, not captured before it.
- `LLMRequestPrep.prepare()` on every `LLM.run` (`llm.ts:106`) rebuilds the system
  prompt from the agent's prompt, the provider default, the session system and the
  user system (`llm/request.ts:56`).

There is even a plugin hook, `experimental.chat.system.transform`
(`llm/request.ts:70`), whose entire job is to let an external party rewrite the system
prompt on each request.

So "prompt and tools are resolved at startup" is **not** true of every production
harness. It is true of Pi and Codex, and Claude Code's control protocol has no verb
for either — but opencode rebuilds both per request by construction.

**What it still cannot do is acquire a tool that did not already exist.**
`resolveTools` (`llm/request.ts:208`) is a filter:

```ts
return Record.filter(input.tools, (_, k) => input.user.tools?.[k] !== false && !disabled.has(k))
```

It removes entries that permission or the user disabled. It never adds one. That is
the same shape as Claude Code's `mcp_toggle` — gating a set assembled upstream — and
it is the line [E3](e3-subturn-steering.md) now turns on.

## What remains

- **The CLI binary**, now optional and much narrower. The host side answered the
  mutability question; the binary would only add whether the *internal* loop re-reads
  anything the protocol does not expose. Read it only if opencode leaves a gap.
- **Codex's `code-mode` crates**, still worth reading before building
  [E5](e5-single-tool-rlm.md)'s arm B — Codex appears to have its own answer to the
  single-tool question.

## Kills it

Nothing to kill — this is measurement. The only failure mode is reverse-engineering
past the question, so keep it to request assembly and turn boundaries.
