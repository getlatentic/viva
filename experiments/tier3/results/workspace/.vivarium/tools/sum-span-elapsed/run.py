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