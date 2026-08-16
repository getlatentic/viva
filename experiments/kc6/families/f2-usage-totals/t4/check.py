import json

def compute(root):
    lines, total = [], 0
    for path in sorted((root / "transcripts").glob("*.jsonl")):
        n = 0
        for line in path.read_text().splitlines():
            entry = json.loads(line)
            if (entry.get("payload") or {}).get("role") == "assistant":
                n += 1
        total += n
        lines.append(f"file {path.name} requests {n}")
    lines.append(f"total requests {total}")
    return "\n".join(lines)


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
