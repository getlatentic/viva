# E4 — self-editing agent object

The meta level. [prime-agent](https://www.primeintellect.ai/blog/prime-agent) does
this against files; the question is what changes when the target is a live object.

## Claim

An agent that edits its own CLOS object — prompt slot, tool method set, policy
method bodies — outperforms a fixed one on held-out tasks, and does so without the
serialise/reload cycle prime-agent needs to make edits survive a turn.

The mutation unit is a live method, not a source file. The ledger already records
it, so `/refine`'s "evidence-backed rollback" comes for free rather than being built.

## Method

Object level first, meta level second. Scoring one meta-change means running an
entire object-level campaign, so this is only affordable once E2's score is cheap
and trusted.

Then: give the agent write access to its own object, run it on a task set, hold out
a second set, compare against the same agent with a frozen object.

Two guardrails, both borrowed from prime-agent and both cheap:

- **Immutable floor.** Fix a base prompt and a minimal tool set the agent cannot
  edit, so a self-edit that breaks the editor is always recoverable. prime-agent
  keeps its base system prompt fixed and only lets `/refine` touch the surrounding
  layer; steal that exactly.
- **Control plane stays out of the image.** genera-lab's is already on 7717. An
  in-image agent that corrupts its own dispatch must not take its supervisor down
  with it.

## Kills it

- Self-edits improve training-set score and lose held-out score. That is the
  expected failure and the reason for a held-out set.
- The agent converges on editing its own scorer rather than its own competence.
  Detectable, and the reason the objective must live outside the object.
- Edits that survive are all trivially portable to a static prompt file — meaning
  the live object bought nothing over prime-agent's approach.

## Depends on

E1 (scoring), E3 (a mutable object read at call time), E2 (a trusted objective).
