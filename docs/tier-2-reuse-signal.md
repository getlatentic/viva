# The tier-2 reuse signal (#7)

A spike's deliverable is a decision. This is it, with the evidence.

## Why it matters more than it looks

Three runs of `experiments/tier3/` — four trivial encounters, four expensive,
then eight expensive — retained a skill and **never** a tool. That is
structural, not a corpus problem: **tier 2 absorbs the pressure that would
produce tier 3.** The router promotes on evidence of reuse, but once a skill
exists the re-derivation cost it was measuring is gone, so the evidence a tool
needs never accumulates.

So reflection cannot reach tier 3 by repetition at any corpus length.
Graduation (#8) is the only path, and graduation needs a number to threshold
on. That number is this issue.

## The obstacle

**A skill is not invoked.** It is injected into the system prompt and read, so
there is no use event to count. Codex can rank by `usage_count` because its
memories pipeline reads rollouts after the fact; ours would have to infer.

## The candidates, and what each costs

1. **Post-hoc judgement.** A pass over the transcript asking whether the skill's
   procedure was what the task did. A model call per task, and a judgement
   rather than a count.
2. **Make the skill's code executable.** Its snippet becomes a script the model
   runs by name. Use is then a fact, observed exactly.
3. **Textual resemblance.** Did a command the model ran look like the snippet?
   Free, and brittle in both directions.

## Decision: (2), and it is smaller than it sounds

The routing rule's whole virtue is that it turns on a **fact** — *have I
reached for this before* — rather than a judgement — *is this good enough*.
(1) and (3) put an inference underneath a rule that was designed to avoid one.
Only (2) keeps the property.

It is also not a new idea, and not ours. Codex's consolidation prompt lays a
skill out as

    scripts/<tool>.*   # optional; executed, not loaded (prefer stdlib-only)

so a Codex skill already carries code that is **run**, not read. And our tier-2
format already requires *"one fenced code block that runs"* — the snippet is
executable today; nothing calls it.

So the change is not "make skills into tools". It is: **give a tier-2 skill's
existing snippet a way to be run by name, and count the runs.** A skill stays
a file in the germline, still readable, still editable, still committable. What
it gains is an entry point.

## What that unblocks

- `#8` gets its threshold: promote a skill to a registered tool at N runs.
- Tier 3 becomes reachable, which three experiments say it currently is not.
- The count is a fact, so `#2` — *the next task provably benefits* — has
  something to measure that is not a judgement.

## The risk, named

A skill that must be *called* may be ignored in favour of writing the code
again, exactly as a tool can be. That is measurable the same way this finding
was: run the corpus and count. If calls do not happen, the signal is worthless
and (1) or (3) come back — with the advantage that we would then know.
