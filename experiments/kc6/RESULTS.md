# KC6 results

Filled as the runs land. The verdict section, when it exists, quotes the
decision rule verbatim and fills in only the numbers.

## Pre-checks

**0, reachability — PASS** (gated in `preflight.sh`: model pin, tool surface,
wire schemas, component consumer).

**1, lifecycle — PASS** (`preflight.sh` green end to end; ledger genealogy
reconstructed).

**2, non-collapse — FAIL, reported as the pre-registered tax.** AN (arm A's
exact configuration plus a never-use policy) against B on the bound three,
three repeats, 45 task-runs each:

```
AN: 45 task-runs, 494s, 1,051,074 tokens, 45/45 solved
B:  45 task-runs, 482s, 1,014,394 tokens, 45/45 solved
wall gap  2.5%  (limit 5%)   PASS
token gap 3.6%  (limit 2%)   FAIL
```

The protocol's consequence for this check is reporting, not gating: "above
that, the machinery's mere presence is a material tax and is reported as
one." So it is: carrying the open door costs about 3.6% in tokens even when
policy forbids using it, beyond the schema surface AN and B share. Likely
mechanism — the policy line itself plus behavioral variance around it — noted
without being netted out. In dollars at measured cache behaviour: roughly a
cent per 45 task-runs.

**3 and 4** evaluate at the battery checkpoint over the bound three's arm-A
cells (amendment 14). The smoke cell's signal stands on the record: arm A
solved f3 five-for-five without touching the door once.

## The pilot measurement, and the caps

Pilot spend: $0.27 (meter, peak-conservative rates). Total spend including
smoke and anchors: $0.3076 of $7.00. Per-task average across the pilot:
~11,700 tokens at an ~84% hit rate; f4 runs 4-19s per task, f3 13-21s.

The caps stand as pre-registered and are not binding at this shape: 120M
total / 9M miss tokens for the battery, $1.50 pilot sub-cap (used: $0.27),
$7.00 hard. Projection from measured pilot shape: the full battery lands
near $1, an order of magnitude inside the ceiling.

## Observations that are not yet results

Solve rates are saturated so far — every arm solves everything (smoke A 5/5,
AN 45/45, B 45/45). If arm C saturates too, the primary decision rides
entirely on cost per solved task, which the decision rule anticipates with
its "or": a 30% token reduction OR +0.20 solve rate.

## The checkpoint, and amendment 15

**Pre-check 3 FAILED at the checkpoint** — nine arm-A cells on the bound
three, 45 task-runs, zero door entries; the battery stopped by protocol at
$0.58 total spend. The decisive diagnostic came from the arms comparison:
**arm C invested nothing either** — zero `remember` calls, no MEMORY.md in
any of its 45 runs. All three arms behaved identically.

So the finding is not "the capability surface is too narrow"; it is
"recurrence was invisible." Each task ran as a fresh conversation with
nothing saying four more of the same kind follow, while the hypothesis
presupposes perceptible recurrence. Amendment 15 adds one matched sentence
per task — count and kind, never mechanism — archives every pre-framing row
(spend retained in the meter), and re-runs all arms. The pre-framing rows
live in `results-preframing.tsv`; they are evidence about unprompted
behavior, and they say: without a recurrence signal, nobody invests in
anything, capability or text alike.

## Pre-check 2 under amendment 15's framing — FAIL again, reported again

```
AN: 45 task-runs, 547s, 1,170,910 tokens, 45/45 solved
B:  45 task-runs, 520s, 1,111,280 tokens, 45/45 solved
wall gap  5.1% (limit 5%)   FAIL (was 2.5% pre-framing)
token gap 5.2% (limit 2%)   FAIL (was 3.6% pre-framing)
```

The tax grew under framing, and its direction is stable across both
readings: AN — the open door plus a policy never to use it — costs more than
B's closed door. Both readings stand in the record; the consequence remains
reporting, per the protocol's own sentence.

And the behavioral null persists in the constrained arms: under framing,
AN and B still made zero `remember` calls, wrote no MEMORY.md, and B never
attempted the door (no ledger exists — not even a refused activation). The
arms that can actually invest — A and C — run next; the checkpoint over A's
bound-three cells decides whether the framing moved anyone.

## Checkpoint two, under the framing — the null is the finding

Pre-check 3 fired a second time: nine arm-A cells on the bound three, zero
door entries. The instrument was suspected first and cleared — the framing
sentence is verbatim in every task's first user message on the wire. And the
decisive diagnostic: **arm C invested nothing either.** Zero remember calls,
zero MEMORY.md, across all framed C cells. The battery stopped at $1.13.

Twice-measured, instrument-verified: on tasks this model solves directly in
5-20 seconds, it invests in NO retention mechanism — compiled capability and
text notes alike — even when told the work recurs. The tasks are too cheap
for tooling to be rational, and pre-check 3 did precisely what it exists to
do: prevent a null-null battery from firing the kill criterion on a
comparison in which neither mechanism was ever used. "A fails to beat C"
would have been true by the letter and wrong in substance — external skills
captured nothing either.

The tools-as-components diagnosis is defeated twice over: C's text channel
is exactly as unreached as A's compile channel. The surface is not the
problem; the investment incentive is.

Open fork, user's decision: invited-mode framing (the adaptation battery's
NUDGED precedent — names the category of investment, relabels the measured
question to "when invited to retain, does compiled capability beat text"),
or harder families where direct solving is expensive enough that investment
is rational within five tasks, or stop here and take the finding back to
design.

## The spontaneity null — a standing result, condition 2 of amendment 16

**This model does not spontaneously invest in retention on tasks it solves
directly in 5-20 seconds: 90 task-runs, two framings (bare, and with
recurrence named), zero investment in every mechanism — no capability
minted, no note remembered, no MEMORY.md written, in any arm.** The
system-prompt audit is part of the record: every affordance was described to
the model (remember's description even names cross-task persistence), and
the only behavioral instruction was "finish what you were asked."

This is the baseline the Level 3 retention policy must beat, measured before
that policy exists. The roadmap's "promote exists; the POLICY does not" is
now data, not assumption.

## Amendment 16: invited mode

The invitation, identical in every arm, category never mechanism: "Durable
improvements you make carry into the later tasks." The measured question is
relabeled honestly: **when invited to retain, does compiled capability beat
external text?** The kill inference survives the relabel — a perfect policy
deciding WHEN to retain cannot make a worthless WHAT worthwhile. Per-arm
investment rate joins as a secondary metric. Risk named before running:
cheap tasks compress the absolute effect; the pre-registered answer to
under-threshold agreement is the ambiguous-zone extension, never a threshold
move.

## Checkpoint three, invited — the channels finally split, and the run stops

Pre-check 3 fired a third time, and condition 3 of amendment 16 makes this a
hard stop. Instrument verified again: the invitation is verbatim in every
first user message. Total spend at stop: $1.58 of $7.00.

The diagnostic that changes the finding's identity — per-arm investment under
invitation (`investment.py`, 45 task-runs per arm):

```
arm A   created 0  promoted 0   remember calls 1   memory lines 2
arm AN  created 0  promoted 0   remember calls 0   memory lines 0
arm B   created 0  promoted 0   remember calls 2   memory lines 4
arm C   created 0  promoted 0   remember calls 1   memory lines 2
```

**The text channel moved — barely, but from exact zero to first life, in
three arms. The compile channel moved nowhere, including in arm A, the one
arm holding both channels.** Invited, told the work recurs, holding compile
and text in the same hands, the model reached for text once and for the door
never.

Three readings, in descending order of what the evidence supports:

1. **Surface**: with both channels available and investment invited, revealed
   preference went text-over-compile 1-0. The backlog's tools-as-components
   trigger condition — "the surface is too narrow to be used at all" — is
   now formally met for the first time. One datum wide.
2. **Economics**: 1-2 investments per 45 runs is epsilon; on 5-20 second
   tasks even text barely rationalizes. The harder-families/Level-3 path
   addresses this and is already filed.
3. **Invitation strength**: the ratified sentence ran faithfully, but the
   adaptation precedent's NUDGED lived in the SYSTEM prompt with sharper
   category wording ("anything you had to work out"); this invitation rode
   the user message. A stronger, precedent-exact probe exists below the
   compliance ceiling. Caveat, not excuse.

The stop is pre-registered and the next lever is the user's: pull
tools-as-components (its trigger is now met), or take the Level 3 retention
policy as the next artifact and re-pose KC6 against it (harder families are
already filed as its evaluation), or spend one more ~$1.30 on a
NUDGED-exact probe before deciding.

## Level 3 v1: the retention policy beats the baseline — both channels

The fork resolved Level-3-first, and the policy's v1 shipped the same night:
one bounded reflection turn after every task, in the task's own conversation,
retaining only through the existing doors (`src/workspace/reflection.lisp`,
`docs/retention-policy.md`). The arc, measured:

```
                        text channel        compile channel
uninstructed (90 runs)  0                   0
invited      (45 A-runs) epsilon (1 call)   0
under policy (2 cells)  active, clean       f1: 0   f2: 4 created,
                                            4 activated, 3 resolved,
                                            1 PROMOTED
```

The split between f1 and f2 under the policy is the finding that
reframes the surface question: **the door opens when the content is
transformation-shaped.** f1's frictions are knowledge (what the validator
wants) and the policy correctly retained them as text; f2's friction is a
parser — string to string — and the policy minted it, tested it, and
promoted it to the durable default: the first unforced promotion in the
organism's history. Instrumentality on that cell: 75% versions resolved,
100% of creating tasks resolving — both thresholds passed, unforced.

The smoke also caught three instrument defects (relative-path copies that
find silently swallowed, producing an empty sandbox the model repaired by
reading sibling runs; grading after reflection, letting reflection un-solve
work; sandboxes confineable by :root but not by bash) — all three fixed in
the driver: absolute paths with an empty-sandbox tripwire, grade before
reflect, per-cell /tmp isolation. The model's sibling-reading repair is
preserved in results-preframing-era notes as live evidence for the
confinement item.

Peak exceptions: three smoke cells ran inside the 06:00-10:00 window under
amendment 13's logged escape, ~$0.09 total. Meter: $1.66 of $7.00.

**KC6 is now well-posed for the first time**: arms A and C both under the
retention policy — compiled versus text, GIVEN that retention happens —
which is what the kill criterion always meant. Ready to run on the user's
go: ~$1.30, off-peak.
