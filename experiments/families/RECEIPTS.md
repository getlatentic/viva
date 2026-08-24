# Where these families came from

The anti-rigging rule: a family must come from a **real recurring friction**,
with the receipt named. A friction invented to suit the experiment is an
experiment measuring itself.

Both families below come from frictions hit repeatedly while building this
project, most of them on 2026-08-21. None was invented for the battery.

## Family `ledger` — reconciling an append-only log that two writers touched

**Receipt.** `experiments/tier3` was launched twice by mistake: the first run
was orphaned rather than killed, and two drivers wrote one results file. The
corruption was not loud.

```
4     spans  v4  1  13   2  48135   2008
pans  v5     1   11  1    39020   1308      <- a row missing its first two characters
3     spans  v3  0  118  2  235348  16267   <- one task apparently costing 235k tokens
```

Rows out of order, a truncated row, an implausible outlier, and two variants
failing that had passed. **All of it looks like data**, and it was nearly read
as a regression from that day's retention changes. Fixed by a lock
(`6ac4439`), but the analysis skill it demanded — detect torn lines, dedupe
retried records, keep the last write per key, and refuse to total a file that
has been damaged — is the friction.

**Why re-derivation is expensive.** Every one of those defects is silent. A
parse that skips a torn line quietly under-counts; one that accepts it counts
garbage; deduping on the wrong key drops real records; keeping the *first*
retry rather than the last reports a number that was superseded. Getting it
right takes real work, and getting it wrong looks like success.

**Second receipt, same shape.** `results.tsv` carried `prompt` and
`completion` columns holding a literal `0` on every row while `requests`
varied — a cost measure that was fiction and looked answered (`4f312d0`). A
totalling task that cannot notice an all-zero column is the same failure.

## Family `manifest` — does a declaration match the thing it declares?

**Receipt.** #41 exists because a `tool.json` is written by a model to describe
a script the same model wrote, and nothing checked the two agreed. The
expensive direction is the manifest omitting a parameter the script requires:
the caller cannot send what it was never told about, and finds out inside
somebody else's traceback, in a later task.

**Second receipt, and it is mine.** Five times on 2026-08-21 I called functions
that did not exist — `make-instance-tool`, `harness-skill-directories`,
`copy-termios`, `rename-path`, `read-records` — and `viva check` reported
none of them, because an undefined function is a *style warning*. Two were
caught only by a failing test; one by a read error that happened to be package
qualified. A declaration that disagrees with its implementation and still
builds clean is exactly this family.

**Third receipt.** A test fixture indexed `skill-directories` by position, and
`first` is the *machine* directory — so it wrote into `~/.vivarium/skills`,
passed (it read them back from the same wrong place), and broke an unrelated
test with the leftovers. Consistently wrong is invisible until something else
resolves the same name correctly and disagrees.

**Why re-derivation is expensive.** Both sides have to be read — the declared
interface and the actual one — and compared in *both directions*: a promise the
implementation cannot keep, and a requirement the declaration never mentions.
Each direction fails differently and neither is visible from one side alone.

## Measured, 2026-08-21 — what the families actually cost

One run, both families, deepseek-v4-flash, off-peak, gate green beforehand.

| family | solved | wall-clock | prompt tokens | completion tokens |
|---|---|---|---|---|
| `ledger` | 6/6 | 18s/task | 43,464/task | 2,400/task |
| `manifest` | 6/6 | 20s/task | 47,891/task | 3,024/task |

Whole run: **$0.0855** for 12 tasks.

**#11's third acceptance criterion is NOT met, and is restated rather than
waved through.** It asked for *"task cost ≥ several minutes of model work per
task at solve time"*. Measured: **18 to 20 seconds.**

Wall-clock was a proxy for *expensive to re-derive*, and it is a bad proxy at
this model's speed — the same derivation that takes a slow model minutes takes
this one seconds, and neither number says how much work was avoided. Tokens do,
and tokens are what `docs/b15-preregistration.md` measures. Against the `spans`
corpus (~30k prompt, ~1.4k completion per task) these families cost **1.5× to
2× more per task**, which is the property the criterion was reaching for.

So the criterion becomes: **a family qualifies at ≥ 40k prompt tokens per task
at solve time.** Both clear it. The wall-clock form is retired as
model-dependent.

**A harder problem, recorded because it threatens #43's power.** Every task
solved, most in a single model request. A task solved in one request contains
very little re-derivation for retention to save — which is exactly the ceiling
KC6 hit from the other side, where five cheap tasks measured install cost and
nothing else.

This does not invalidate the families; it bounds what they can show. If the
composition arm's advantage is the *derivation* it skips, and derivation is one
request, the effect available to measure is small. Before B15 runs, either:

- the families gain variants the model does **not** solve first try (more
  decoys, more interacting rules), so there is derivation to save; or
- B15 reports its effect against this ceiling explicitly, and a null result is
  read as *"no headroom at this difficulty"* rather than *"composition does not
  pay"*.

Written down now, while it is a design constraint. After the run it would be an
excuse.
