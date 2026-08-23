import glob, json, pathlib, sys

events = []
for path in sorted(glob.glob("events/*.jsonl")):
    offset, skew, index = 0, 0, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("kind") == "clock":
            offset = record.get("offset", 0)
            skew = record.get("skew", 0)
            continue
        if record.get("kind") != "event":
            continue
        true_at = record.get("at", 0) + offset + index * skew
        index += 1
        events.append((record.get("id"), record.get("rev", 0), true_at))

current = {}
for key, rev, at in events:
    if key is None:
        continue
    if key not in current or rev > current[key][0]:
        current[key] = (rev, at)

times = sorted(at for _, at in current.values())
sessions, active = 0, 0
start = previous = None
for at in times:
    if start is None:
        start = previous = at
        sessions = 1
        continue
    if at - previous > 120:
        active += previous - start
        sessions += 1
        start = at
    previous = at
if start is not None:
    active += previous - start

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
parts = answer.read_text().split()
if len(parts) < 2:
    sys.exit("answer.txt needs two numbers")
try:
    got = (int(parts[0]), int(float(parts[1])))
except ValueError:
    sys.exit("answer.txt is not two numbers")
if got != (sessions, active):
    sys.exit(f"answer {got} != {(sessions, active)}")
print("ok")
