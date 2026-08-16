import json
from decimal import Decimal, ROUND_HALF_UP

def compute(root):
    hit = miss = out = 0
    for line in (root / "transcripts" / "run.jsonl").read_text().splitlines():
        entry = json.loads(line)
        payload = entry.get("payload") or {}
        if payload.get("role") != "assistant":
            continue
        usage = payload.get("usage")
        if not usage:
            continue
        entry_hit = usage.get("prompt_cache_hit_tokens", 0) or 0
        hit += entry_hit
        if "prompt_cache_miss_tokens" in usage:
            miss += usage["prompt_cache_miss_tokens"]
        else:
            miss += (usage.get("prompt_tokens", 0) or 0) - entry_hit
        out += usage.get("completion_tokens", 0) or 0
    rate = (int((Decimal(100) * Decimal(hit) / Decimal(hit + miss))
                .quantize(Decimal(1), rounding=ROUND_HALF_UP))
            if (hit + miss) else 0)
    return f"hit {hit}\nmiss {miss}\nout {out}\nhitrate {rate}%"


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
