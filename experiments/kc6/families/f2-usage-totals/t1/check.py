import json

def compute(root):
    requests = toolcalls = 0
    for line in (root / "transcripts" / "run.jsonl").read_text().splitlines():
        entry = json.loads(line)
        payload = entry.get("payload") or {}
        if payload.get("role") == "assistant":
            requests += 1
            toolcalls += sum(1 for block in (payload.get("content") or [])
                             if isinstance(block, dict)
                             and block.get("type") == "tool_call")
    return f"requests {requests}\ntoolcalls {toolcalls}"


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
