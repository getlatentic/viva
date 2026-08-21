---
name: sum-span-elapsed
description: Total elapsed time of span records across vivarium JSONL trace files (data/*.jsonl)
language: python
---

Use when a task asks to aggregate elapsed times from the JSONL trace files in this workspace. Only kind=="span" records count; a "log" record is not a span. Elapsed lives at body.span.elapsed as {"value": n, "unit": u} with unit "ms", "us" or "s"; microseconds floor-divide to whole ms (under 1000us contributes 0), seconds are 1000ms, and a span with no elapsed counts as 0.

```python
import json, glob

total = 0
for path in sorted(glob.glob('data/*.jsonl')):
    with open(path) as f:
        for line in f:
            rec = json.loads(line)
            if rec.get('kind') != 'span':
                continue
            el = rec.get('body', {}).get('span', {}).get('elapsed')
            if el is None:
                continue
            v, u = el['value'], el['unit']
            total += v if u == 'ms' else (v // 1000 if u == 'us' else v * 1000)
print(total)
```
