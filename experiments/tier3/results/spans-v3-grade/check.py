import glob, json, sys, pathlib
want = 0
for path in sorted(glob.glob("data/*.jsonl")):
    for line in open(path):
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("kind") != "span":
            continue
        elapsed = (record.get("body") or {}).get("span", {}).get("elapsed")
        if not elapsed:
            continue
        want += elapsed["value"] * {"ms": 1, "us": 0, "s": 1000}[elapsed["unit"]]
answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(answer.read_text().split()[0])
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
sys.exit(0 if got == want else f"got {got}, want {want}")
