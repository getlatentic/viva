# Two corpora, two negative results, and a working router

Built to answer #6: does reflection reach **tier 3** — a registered tool — and
does a later task call it?

## First corpus: too easy

Four variants, one shape, a one-line sum over JSONL. **Four solved, nothing
retained.** That is the policy working: the prompt says most tasks leave
nothing worth keeping, and a one-liner is not code you would rewrite, it is
code you would retype. The instrument was wrong for the question.

## Second corpus: expensive to re-derive

Same shape, rebuilt so the parse actually costs something — nested at
`body.span.elapsed`, three units where microseconds round down to zero, absent
fields counting as zero, and **decoy `log` records carrying an elapsed value at
the same path**, so a parse that skips the kind check silently over-counts.

The gate discriminates all three ways: the correct answer passes, counting logs
fails, ignoring units fails. (The first version's decoy put its value at a
different path, so the kind check was never load-bearing — a gate that could
not fail.)

**Four solved, and it retained: a skill, `sum-span-elapsed`, plus one note.**

## So: tier 2, not tier 3, and that is the rule working

The routing rule is *evidence of reuse*: code you might want again is a skill,
code you have **already** wanted again is a tool. Four encounters of one shape
produce a skill. They do not produce a tool, because by the time the skill
exists the re-derivation cost is gone — which is exactly what the skill is for.

Reaching tier 3 needs the skill to be **written early and then reached for**,
so reuse is evident *while the corpus is still running*: more encounters after
the skill exists, or a second shape that needs the same transformation. Six to
eight variants, not four.

## What this bought

The router demonstrably routes by cost: trivial work retains nothing, expensive
work retains a skill. That is two of three tiers observed under controlled
conditions. Tier 3 remains unobserved on demand and #6 stays open.

$0.035 across both runs, off-peak, and the runner refuses to start inside a
peak window.

## Third run: eight variants, and tier 3 is still not reached

Eight encounters of the same expensive parse. Eight solved. Retained: the same
one skill, `sum-span-elapsed`. No tool, at any point.

This is no longer a fact about the corpus. It is a fact about the rule.

**Tier 2 absorbs the pressure that would produce tier 3.** The routing rule
promotes on *evidence of reuse* — code you have already wanted again is a tool.
But the moment a skill exists, the re-derivation cost it was measuring is gone:
every later encounter is cheap, so the evidence that would justify a tool never
accumulates. The cheaper tier is not a step towards the expensive one, it is a
substitute for it.

So tier 3 is probably not reachable from the reflection prompt by repetition,
however long the corpus. Something has to count the skill's **usage** and
promote on that — which is exactly backlog #8, "Graduation: reuse past
threshold promotes a snippet into the registry". This run is an argument that
#8 is not a convenience on top of the router but the only mechanism that gets
to tier 3 at all.

Worth stating against our own interest: #6 asks reflection to reach tier 3 by
policy, and three runs at rising difficulty and length say it does not. The
issue may be mis-specified rather than unimplemented.

**What did work, twice over:** the router routes by cost. Trivial work retains
nothing. Expensive work retains a skill, on the first corpus that made the
parse genuinely expensive, and the skill it wrote names every rule that made it
expensive — the span-only filter, the unit conversion, the microsecond floor.

$0.075 across three runs, all off-peak, all gated.
