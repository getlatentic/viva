# The corpus was too easy, and that is the finding

Built to answer #6: does reflection reach tier 3 — a registered tool — and does
a later task call it? Four variants of one shape, the same parse each time,
data growing so doing it by hand stays annoying.

**Result: four solved, nothing retained.** No note, no skill, no tool. The only
tools called were `bash`, `ls` and `write`.

That is the policy working. The task is a one-line sum over JSONL, solved in
five to eight seconds. The prompt says *"most tasks leave nothing worth keeping,
and `nothing to retain` is the correct answer then"*, and the routing rule
prefers the cheap tier until reuse is **already** evident. A one-liner is not
code you would rewrite; it is code you would retype. Declining was right.

So the corpus does not test what it was built to test, and this is the same
mistake in a new place: the instrument was wrong for the question, not the
thing being measured.

## What a corpus that reaches tier 3 needs

Not more repetitions of something cheap. A transformation **expensive to
re-derive**:

- nested or irregular structure, so the parse is not one expression
- edge cases that must be handled the same way every time — absent fields,
  mixed units, entries that look like data and are not
- an answer that is wrong in a quiet way if any of them is missed

The dogfood's `spend` shape had exactly this and did produce a tool: three
token fields, an `assistant`-only filter, absent fields counting as zero. Ours
has one field and no filter.

## Cost

$0.015 for the run, and it bought a negative result about the corpus rather
than an answer about the policy. Worth recording at that price; not worth
re-running until the tasks are harder.
