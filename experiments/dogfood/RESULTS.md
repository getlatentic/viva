# Does retention pay on real work? — results

25 tasks, five recurring job shapes, one workspace, policy on. Thresholds
quoted from PREAMBLE.md, which was committed before the corpus existed.
Verdict against each claim, then the artifacts in full.

## The four claims

**1. Retention happens — PASS, at the threshold.**
Five artifacts over 25 tasks against a threshold of one per five: four notes
and one tool. Not abundant, but not inert, and the policy needed no prompt
beyond its own.

**2. What it retains is good — PASS, 4 of 5 kept (80%, threshold 50%).**
Reviewed cold against the three questions written before the artifacts
existed. Three notes and the tool survive; one note is deleted. Full review
below.

**3. What is kept gets reused — PASS for the tool, unmeasurable for notes.**
`token-usage-total` was built during `spend-v3` and called **five times by
`spend-v4` and `spend-v5`** — an artifact created on the third encounter with
a recurring job and used on both later ones, which is the amortisation story
observed rather than argued. The notes load into every later prompt by
construction, but "drawn on" is not decidable from a transcript, so they are
reported as unmeasured rather than counted either way.

**4. Reuse pays — FAIL, and split.**
Late variants (4–5) against early (1–2), tokens per task:

```
board      +2.2%      surface   -18.0%      corpus   +8.2%
spend      +9.1%      tlc      +15.6%       threshold -20%
suite     +21.1%
```

Positive is cheaper. The corpus improved 8.2% against a 20% threshold, and
one shape got 18% *worse*. Reported as a split, per the preamble: `suite`
paid, `surface` did not, and averaging them into a win would be the thing the
threshold exists to prevent.

## The verdict

**Retention happens and what it retains is good; it does not yet pay.**

The same shape as KC6's finding, in a different setting and for the same
reason: these jobs take 5–20 seconds, and there is not enough derivation cost
to amortise an artifact against. The one place it clearly paid is the one
place the work was genuinely repetitive and mechanical — `spend`, where a
tool replaced a parse — and `spend-v4` was the cheapest spend task in the run
at 24,972 tokens against a 40–65k band.

That is the honest boundary: **retention pays where the work is mechanical
and recurs; it costs where the work is judgment.** Nothing here supports a
general claim, and the preamble's negative branches are met rather than
explained away.

## The artifact review, in full

**KEPT — transcript structure.** *"only entries with payload.role 'assistant'
carry payload.usage, whose token fields are prompt_cache_hit_tokens,
prompt_cache_miss_tokens, completion_tokens."* True, non-obvious, transfers,
and it is the exact fact this session rediscovered by hand four times.

**KEPT — suite output shape.** *"run.log ends with a `;; Summary:` block;
failure lines carry the test name after `VIVARIUM.TESTS::`."* Same three
answers.

**KEPT — the registry's own bug.** *"token-usage-total resolves its dir
argument against a different cwd than this workspace: a relative path like
'data' silently yields all zeros. Pass an absolute path."* True, and it is a
defect report about vivarium written by vivarium. See below.

**DELETED — the experiment's own layout.** *"task workspaces contain PROMPT,
expectations.txt, logs/, check.py … answer.txt is the deliverable."* True and
useless: it describes the measurement's scaffolding, not the work. Fails
question two — it restates the task — and question three, since none of it
survives the corpus.

**KEPT — the tool.** `token-usage-total`: reads every `*.jsonl` in a
directory, filters `kind == "message"` and `payload.role == "assistant"`,
totals the three fields with absent counting as zero, prints JSON. Correct,
documented, parameterised, and the filter on `kind` is a detail it had to
discover.

## What the dogfood found in the product

The third note is the result that outlives the measurement. Registry tools
ran with their working directory set to **the tool's own folder**, so a
relative path in an argument resolved beside the tool rather than beside the
work — and `token-usage-total`, handed `"data"`, found no files and returned
`{hit: 0, miss: 0, out: 0}`. **A wrong answer that looks like an answer**,
which is the worst failure a tool can have.

The organism's response is the part worth noticing: it wrote itself a note
about passing absolute paths. It worked around the defect instead of
reporting it, which is exactly how a bug becomes folklore.

Fixed: tools now run in the task's directory, with the script's own path
absolutised so it still resolves. A test pins it — a relative `.` must count
the task's files, not the tool's.

## Cost

25 tasks, $0.12 of the $7.00 budget, off-peak, Flash. Two runs: the first is
described below and is not counted as a result.

## The instrument, corrected mid-flight

The first run gave every task its own working directory. Retention in
vivarium is **project-scoped** — `remember` writes `.vivarium/MEMORY.md`
relative to cwd, and skills and tools resolve the same way — so each task got
its own germline and none could see another's. The organism built the same
tool twice under two names in three separate shapes: `sum-token-usage` and
`total-token-usage`, `suite-verdict` and `report-runlog`, `tlc_verdict`
twice.

That is a corpus measuring its own harness, and it was discarded. The second
run gives all 25 jobs one workspace, rotating the task files and keeping
`.vivarium` — one repository, many jobs over time, which is what the claim
was ever about.

It also surfaced a real design question the attachments work will have to
answer: retention follows **cwd**, so an organism pointed at several folders
has several germlines and no way to retain at the machine level, where
sharing would actually happen.
