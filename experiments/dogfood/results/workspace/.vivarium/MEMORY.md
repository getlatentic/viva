# What I have learned working here

- Agent-run transcripts in data/ are JSONL: each line has kind (header/message) and payload; only entries with payload.role "assistant" carry payload.usage, whose token fields are prompt_cache_hit_tokens, prompt_cache_miss_tokens, completion_tokens.
- Test-suite output in run.log ends with a `;; Summary:` block (Passed/Failed/Skipped counts); failure lines carry the test name after `VIVARIUM.TESTS::`.
- Dogfood experiment task workspaces (results/workspace) contain PROMPT (the task), expectations.txt (name -> expected verdict), logs/ (one raw data file per config), check.py (the local grader; ./check runs it), and answer.txt is the deliverable.
- token-usage-total (a built-in capability) resolves its dir argument against a different cwd than this workspace: a relative path like "data" silently yields all zeros. Pass an absolute path, e.g. /Users/dev/workspace/vivarium/experiments/dogfood/results/workspace/data, and it sums hit/miss/out correctly.
