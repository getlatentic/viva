# The families

Authoring and grading rules, common to all six.

**Grading is pristine-plus-outputs.** The runner grades in a fresh copy of
the task's committed files, overlaid with ONLY the paths named in the task's
`graded` manifest — the agent's declared outputs. Everything else is restored
before `./check` runs, so mutating a task's inputs (transcripts, harness
sources, the check itself) changes nothing about the grade. Every PROMPT says
so, to keep any arm from wasting requests on a door that is painted on.

**The gate.** `./verify-family.sh <family>` — every check must fail on the
initial state, pass on the reference solution, and (where the output is
answer.txt) fail again when the answer is corrupted. A family is FROZEN when
its gate is green; frozen families do not change without an amendment.

**Split and order** (amendment 11, fixed before family one existed): scored
families are 1-4; held-out are 5-6, authored last, excluded from pilots and
authoring knowledge, included in the battery and the primary n = 6 sign test.
Battery order: 3, 1, 4, 2, 6, 5. Arm B and the pilot run on families 3, 1, 4
(amendment 12).
