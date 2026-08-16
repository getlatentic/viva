# Family 2: usage totals out of JSONL

The friction: pulling request counts, token totals, and cache splits out of
JSONL transcripts. The receipt: this exact parse was written four separate
times in one session — the harness's count_events, two cost scripts, and the
live-run measurements — each time slightly differently.

Five tasks, one friction, different particulars; the traps are the real ones
(provider-variant key names, malformed lines, role-in-payload decoys,
multi-file aggregation, the cache split). The agent writes `answer.txt` in
the exact format the PROMPT states; `./check` recomputes from the transcripts
with the specified rules and compares. `solution/answer.txt` is derived from
the check's own parser, and the gate's corrupted leg proves the check reads
the answer rather than waving at it.
