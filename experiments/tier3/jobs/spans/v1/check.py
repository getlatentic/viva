import glob, json, sys, pathlib
want = 0
for path in sorted(glob.glob("data/*.jsonl")):
    for line in open(path):
        if line.strip():
            want += json.loads(line)["attrs"]["duration_ms"]
got = pathlib.Path("answer.txt")
if not got.exists():
    sys.exit("no answer.txt")
try:
    sys.exit(0 if int(got.read_text().split()[0]) == want else f"got {got.read_text().strip()}, want {want}")
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
