---
name: sum-span-elapsed
description: Total the elapsed time of SPAN records in JSONL trace files under data/, converting units to whole milliseconds.
language: python
---

Use when a task asks for the elapsed time of spans (or any aggregation of
body.span.elapsed) in the JSONL trace files. Only kind=="span" records count;
logs carry elapsed too but must be excluded. Elapsed is
{"value": n, "unit": u} with u in ms/us/s: us floors down to whole ms,
s is 1000ms, and a span with no elapsed contributes 0.

```python
import json, glob

total = 0
for path in sorted(glob.glob('data/*.jsonl')):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get('kind') != 'span':
            continue
        elapsed = rec.get('body', {}).get('span', {}).get('elapsed')
        if elapsed is None:
            continue
        value, unit = elapsed['value'], elapsed['unit']
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
