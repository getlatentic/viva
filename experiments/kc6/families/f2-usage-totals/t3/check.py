import json

def compute(root):
    valid = requests = 0
    for line in (root / "transcripts" / "run.jsonl").read_text().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        valid += 1
        if (entry.get("payload") or {}).get("role") == "assistant":
            requests += 1
    return f"valid {valid}\nrequests {requests}"


def main():
    import pathlib, sys
    expected = compute(pathlib.Path("."))
    answer_path = pathlib.Path("answer.txt")
    if not answer_path.exists():
        print("FAIL: no answer.txt"); return 1
    got = "\n".join(line.rstrip() for line in
                     answer_path.read_text().strip().splitlines())
    if got == expected:
        print("ok"); return 0
    print("FAIL: answer.txt does not match")
    print("--- expected ---"); print(expected)
    print("--- got ---"); print(got)
    return 1

if __name__ == "__main__":
    import sys; sys.exit(main())
