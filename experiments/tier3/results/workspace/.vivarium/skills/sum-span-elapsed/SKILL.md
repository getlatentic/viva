---
name: sum-span-elapsed
description: When a task must total (or otherwise reduce) elapsed times in vivarium trace JSONL files, honoring the span-only rule and ms/us/s unit conversion with us rounding down.
language: python
---

Use this when processing the JSONL traces in data/: only kind=="span" counts,
elapsed lives at body.span.elapsed, "us" floors to whole ms, "s" = 1000 ms,
and a span with no elapsed counts as 0. Run the snippet from the workspace
root; it prints the total in whole milliseconds.

```python
import json, glob

total = 0
for f in sorted(glob.glob('data/*.jsonl')):
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get('kind') != 'span':
            continue
        elapsed = rec.get('body', {}).get('span', {}).get('elapsed')
        if elapsed is None:
            continue
        value = elapsed['value']
        unit = elapsed['unit']
        if unit == 'ms':
            total += value
        elif unit == 'us':
            total += value // 1000
        elif unit == 's':
            total += value * 1000
        else:
            raise ValueError(unit)
print(total)
```
