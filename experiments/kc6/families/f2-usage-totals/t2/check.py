import json

def compute(root):
    prompt = completion = 0
    for line in (root / "transcripts" / "run.jsonl").read_text().splitlines():
        entry = json.loads(line)
        payload = entry.get("payload") or {}
        if payload.get("role") != "assistant":
            continue
        usage = payload.get("usage") or {}
        prompt += usage.get("prompt_tokens", usage.get("input_tokens", 0)) or 0
        completion += usage.get("completion_tokens",
                                usage.get("output_tokens", 0)) or 0
    return f"prompt {prompt}\ncompletion {completion}\ntotal {prompt + completion}"


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
