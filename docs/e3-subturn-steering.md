# E3 — sub-turn steering

## What production harnesses actually do

Read from Codex source (`~/workspace/harness-test/vendor/codex`, f5a938ad60). Queued
input and steering are **not** the same mechanism:

| tier | preemptible by a steer? | evidence |
|---|---|---|
| in-flight token generation | no — provider boundary | — |
| blocking tool (`sleep`, multi-agent `wait`) | **yes, immediately** | `steer_input` flips a `watch` channel to `InputQueueActivity::Steer` (`input_queue.rs:205`); `sleep.rs:118` `tokio::select!`s the sleep against `activity_rx.changed()`; `wait.rs:186` returns `WaitOutcome::Steered` |
| delivery into the model's context | no — next turn iteration | `regular.rs:75-89` checks `has_pending_input` only *after* `run_turn` returns |

`steer_input` (`session/mod.rs:3989`) also refuses Review and Compact turns
outright — `NonSteerableTurnKind`. So steering is real preemption of *waiting*, and
queue-and-resume for *content*.

**Pi steers more finely than Codex, and this narrows the claim.** From
`agent-loop.ts:155`, Pi's inner loop polls `getSteeringMessages()` at the end of
*every* iteration (line 259) and injects them *before the next assistant response*
(line 182). One iteration is one model message plus its tool batch — so Pi already
lands steering between model requests within a task, not only at task end.
`prepareNextTurn` can additionally swap `model` and `thinkingLevel` between
iterations (lines 232–245).

So "content steering below the turn boundary" is **not** an unclaimed tier. Pi has
it for messages.

**Claude Code sets the bar for capability change, and stops short of it.** Read from
the Agent SDK and the desktop app's control protocol ([E6](e6-harness-teardown.md)):
a running session accepts `set_model`, `set_permission_mode`, `interrupt`,
`stop_task`, `rewind_files` and `mcp_toggle`. There is **no `set_system_prompt` and no
`set_tools`**. `mcp_toggle` carries `(serverName, enabled)`, so the tool list can move
mid-session — but only by switching a **pre-registered** server on or off. No request
introduces a tool that did not exist when the session began.

So the baseline is sharper than "resolved at startup": the strongest production
harness on this machine can swap the *model* mid-session but not the prompt, and can
gate tools it already had but not acquire one.

**opencode re-reads both per request, and that narrows the claim a third time.** Read
from source ([E6](e6-harness-teardown.md)): its turn loop is a plain `while (true)`
(`prompt.ts:1088`) that re-resolves the tool set every iteration
(`SessionTools.resolve`, `prompt.ts:1226`) and rebuilds the system prompt on every
request (`LLMRequestPrep.prepare`, `llm/request.ts:56`) — with a plugin hook,
`experimental.chat.system.transform`, existing purely so an external party can rewrite
that prompt per request.

So "resolved at startup" describes Pi and Codex. It does not describe every production
harness, and the earlier version of this claim was too broad.

## Claim

What no harness does is let an agent **acquire a capability that did not exist at
startup**.

The distinction survives opencode because re-reading is not acquiring. `resolveTools`
is `Record.filter` over a registry assembled upstream (`llm/request.ts:208`) — it
removes what permission disabled and never adds. Claude Code's `mcp_toggle` gates a
pre-registered server. Both re-evaluate *which* of a known set is live; neither can
introduce a tool that was nowhere at session start.

In a live image the agent installs a `DEFUN` and the tool's schema is read off the
resulting function — nothing pre-registered, no schema authored, nothing restarted.
That is the tier to test, and it is now the only part of the original claim left
standing.

In a live image the agent is a CLOS object. If request assembly reads the prompt slot
and the tool method set at call time, an external mutation changes what the agent
*can do* on the next request inside the run. Message injection is solved; **capability
injection is not**, and that is the tier to test.

## Method

Build the agent as an object whose request-assembly generic function reads its
state at call time rather than closing over it at turn start. Then, mid-turn:

1. mutate the prompt slot from another thread, confirm the next request in the same
   run carries it;
2. `defmethod` a new tool onto the dispatch generic, confirm it appears in the same
   run's tool list — this is the part Pi cannot do at all;
3. measure requests-to-effect for a *capability* change, against the Pi baseline of
   "never, without a restart".

The steering source must be able to be a monitor, a sibling agent, or the benchmark
— not only a human typing. That is the point of doing it in-image.

## Kills it

- Turns-to-effect is 1 anyway, because in practice a turn contains one model
  request and the boundary is where the change would land regardless. Then this is
  a rename of queue-and-resume, not a new capability.
- Mid-turn prompt mutation produces incoherent trajectories — the model contradicts
  its own earlier reasoning in the same turn often enough to lose more than the
  latency gains. Measure this before building on it.
- Provider-side prompt caching penalises mutating the prefix mid-turn badly enough
  to erase the benefit.

## Independent of

E1. This is about the agent loop, not the trial loop.
