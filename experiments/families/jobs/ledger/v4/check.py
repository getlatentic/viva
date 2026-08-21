import glob, json, pathlib, sys

SCALES = {"unit": 1.0, "milli": 0.001, "kilo": 1000.0}
current = {}
for path in sorted(glob.glob("runs/*.jsonl")):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue                      # torn: ignored, never repaired
        if not isinstance(record, dict) or record.get("kind") != "run":
            continue
        key = record.get("id")
        seq = record.get("seq", 0)
        if key is None:
            continue
        if key not in current or seq > current[key].get("seq", 0):
            current[key] = record

want = 0.0
for record in current.values():
    if record.get("status") == "aborted":
        continue
    cost = record.get("cost") or {}
    scale = SCALES.get(cost.get("scale"))
    if scale is None:
        continue
    want += cost.get("amount", 0) * scale
want = int(want)

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(float(answer.read_text().split()[0]))
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
if got != want:
    sys.exit(f"answer {got} != {want}")
print("ok")
