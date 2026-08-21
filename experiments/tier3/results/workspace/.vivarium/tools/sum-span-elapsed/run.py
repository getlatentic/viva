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