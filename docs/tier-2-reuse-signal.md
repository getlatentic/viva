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

## Measured, 2026-08-21 — the risk this document named actually happens

The risk written here was: *a skill that must be called may be ignored in
favour of writing the code again.* One clean run of `experiments/tier3` (8
variants, one shape, policy on, deepseek-v4-flash, off-peak) measured it.

**The skill was written during task 3's reflection.** From task 4 onward it
appears in the system prompt that was *actually sent* — read out of the request
payload, not off the agent:

```
task  skills carried in the prompt that was SENT
v1    []
v2    []
v3    []
v4    ['sum-span-elapsed']
v5    ['sum-span-elapsed']
v6    ['sum-span-elapsed']
v7    ['sum-span-elapsed']
v8    ['sum-span-elapsed']
```

**Five tasks could have called it. Two did.** The `uses` counter reads `2`, and
the transcripts agree: an extra `run_skill` in v4 and v8, none in v5, v6 or v7.
The model re-derived the transformation three times out of five with the skill
sitting in its prompt.

**So nothing graduated.** The threshold is three runs; the counter reached two.
The registry stayed empty in a corpus built specifically to reach tier 3.

**What this is and is not.** It is one run: five opportunities, n = 1, no
repeats, no control. It is not a powered result and no threshold should move
because of it. What it does establish is that the failure mode is real rather
than hypothetical — the skill was present, was findable, and was skipped more
often than it was used.

**Two consequences.**

*For #43.* The treatment arm needs graduation to actually happen, and a corpus
of eight tasks did not get there. A family whose transformation is reached for
only 40% of the time will not accumulate three uses inside a run of that
length. Families must be sized so the skill is reached often enough to
graduate, or the treatment arm measures nothing and the comparison is between
two controls. `docs/b15-preregistration.md` requires six tasks needing the same
transformation for exactly this reason; this run says six may still not be
enough at a 40% call rate, and that the arm should be checked for graduation
before its numbers are read.

*For the ladder.* Calling a skill is a choice the model makes each time, and it
made it twice in five. Whether the prompt can raise that rate — or whether the
counter should credit re-derivation of a skill's own content — is the open
question this measurement opens, not one it settles.
