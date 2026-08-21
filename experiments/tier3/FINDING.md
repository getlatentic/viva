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
