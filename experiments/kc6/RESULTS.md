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
