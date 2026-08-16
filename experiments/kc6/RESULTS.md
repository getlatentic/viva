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
