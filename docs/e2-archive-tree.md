# E2 — archive and frontier search

**Status: machinery built; claim 2 settled on a synthetic landscape, claim 1 measured and unresolved.**
[trial.lisp](../src/search/trial.lisp) forks scored trials from a zygote;
[arena.lisp](../src/search/arena.lisp) holds the archive and both selection
strategies. 137 assertions green.

## Result: greedy is trapped; the frontier is only slow

[experiments/e2-selection.lisp](../experiments/e2-selection.lisp). No
model involved — both arms get the same budget, the same start and the same
proposal function, so the only variable is which parent they breed from. Running
this with an LLM proposer would confound selection with model quality.

The landscape: `accuracy` peaks at n=10 then dies; `throughput` is negligible but
always rising until n=25, after which it pays. Total therefore has a local maximum
at n=10 and its global maximum at n=40, with a valley between that no improving
step crosses.

| budget | greedy best n | greedy total | pareto best n | pareto total |
|---|---|---|---|---|
| 60 | 12 | 10.10 | 20 | 10.10 |
| 150 | 12 | 10.10 | 28 | 10.10 |
| 300 | 12 | 10.10 | 34 | 10.10 |
| 600 | 12 | 10.10 | **40** | **15.00** |

**Greedy is frozen at n=12 at every budget.** More trials buy it nothing, because
every neighbour of the trap scores worse in total and it will never take the step.
Pareto keeps whichever candidate leads `throughput` — one that is *losing on total*
— and that candidate keeps stepping right, monotonically, until the payoff.

The correct statement of the claim is therefore narrower and more useful than
"Pareto wins": **the frontier converts a hard trap into a budget question.** It cost
10× the trials (600 against 60) to convert it here. That price is the thing to carry
into a real search, because a real trial costs a model call rather than 45 ms.

Round-robin over the frontier is what sets the rate: the leading candidate is bred
from once per frontier member, so progress dilutes as the frontier grows. A
frontier-size-aware schedule is the obvious lever and has not been tried.

**47 ms per trial** end to end: fork, install, run two scored cases, report, reap.
Against E1's bare fork cost of 31.8 ms, install and scoring add ~15 ms.

## Two defects this experiment found

Both were invisible at small scale and both would have silently corrupted results.

**The frontier was defined wrongly.** "Best on at least one case" keeps every member
of a tie. On a landscape whose scores floor at zero it returned **81 candidates out
of 81 trials** — the frontier swallowed the archive and Pareto selection became
random sampling. An earlier run of this experiment appeared to show Pareto reaching
the global optimum at budget 60; that was random exploration wearing a Pareto label,
not selection. The frontier is now the **non-dominated set**, deduplicated by score
vector, with regression tests for both.

**Trials leaked one file descriptor each.** `drain` opened a stream on the pipe's
read end and never closed it. Invisible below ~1000 trials, then fatal — and it
surfaces as `1024 is not of type (UNSIGNED-BYTE 10)`, which names neither pipes nor
trials nor anything near the cause. Guarded now by counting descriptors across a
batch rather than by running to failure.

## Claim 1, still open

**Merging is free**: a variant is a set of ledger entries, so promoting a winner is
replaying `(target, source)` through `install`, with conflicts per-definition rather
than per-line. The datatype is built and tested — `candidate-from-entries` round-trips
a definition through a fork into a fresh image. What is untested is whether two
winners ever touch the same definition in a way neither body subsumes. If that turns
out to be common, claim 1 is dead and the git systems' merge layer was load-bearing.

## What remains

- **Claim 1 on a real search.** `conflicts-between` and `merge-candidates` are built
  and tested; `complementary-pair` finds two frontier members leading different
  cases. The census in
  [experiments/e2-merge.lisp](../experiments/e2-merge.lisp) is written but
  has not yet produced a verdict: with the corrected frontier the two-dial search
  converges to a single non-dominated candidate before it finds complementary
  specialists, so there are no pairs to census. It needs a landscape where two
  lineages genuinely specialise, or a larger budget.
- **A real task rather than a constructed trap.** Everything above shows greedy
  failing where theory says it must. It is not evidence that definition-search
  landscapes have local optima of this shape.
- **Fixture-scored winners against live traffic.** If they do not survive, fixture
  scoring is the wrong objective and the per-session variant path is the only real
  one.

## Kills it

- Frontier and greedy land within noise on a real benchmark at a budget anyone would
  actually pay. The 10× price measured here is the number to beat.
- Two winners routinely touch the same definition with neither body subsuming the
  other. Then claim 1 is dead and the git systems' merge layer was load-bearing.

## Depends on

E1's zygote. Do not build the arena against the serving image — it cannot fork.
