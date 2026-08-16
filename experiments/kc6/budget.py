#!/usr/bin/env python3
"""The $7 meter. KC6 spends nothing beyond what this approves.

The budget is a hard dollar ceiling, not a projection: the worst-case bracket
($45, heavy shape, uncached, peak) exceeds it several times over, so no
schedule guarantees compliance — only a meter between runs does. The runner
calls this before every run; a non-zero exit means STOP, and the protocol's
truncation priority (amendment 13) decides what the battery loses.

Pricing is deepseek-v4-flash, the only model amendment 13 allows, at the
published rates. Every ambiguity resolves conservatively:

  - peak rates are assumed unless --off-peak is passed by a runner that
    KNOWS it is outside 01:00-04:00 and 06:00-10:00 UTC;
  - an entry without cache accounting is priced as all cache-miss;
  - unknown usage spellings fall back through input_tokens/output_tokens.

    ./budget.py --limit 7.00 TRANSCRIPT_DIR...
    ./budget.py --self-test
"""
import json
import pathlib
import sys

# $ per 1M tokens: (cache hit, cache miss, output)
FLASH = {"peak": (0.014, 0.44, 1.32), "off": (0.007, 0.22, 0.66)}


def entry_tokens(usage):
    """(hit, miss, out) for one usage object, conservatively."""
    hit = usage.get("prompt_cache_hit_tokens", 0) or 0
    if "prompt_cache_miss_tokens" in usage:
        miss = usage["prompt_cache_miss_tokens"] or 0
    else:
        prompt = (usage.get("prompt_tokens", usage.get("input_tokens", 0)) or 0)
        miss = max(prompt - hit, 0)
    out = (usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0)
    return hit, miss, out


def scan(dirs):
    hit = miss = out = 0
    for d in dirs:
        for path in pathlib.Path(d).rglob("*.jsonl"):
            for line in path.read_text(errors="replace").splitlines():
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                payload = entry.get("payload") or {}
                if payload.get("role") != "assistant":
                    continue
                usage = payload.get("usage")
                if not usage:
                    continue
                h, m, o = entry_tokens(usage)
                hit += h; miss += m; out += o
    return hit, miss, out


def dollars(hit, miss, out, when):
    h, m, o = FLASH[when]
    return hit / 1e6 * h + miss / 1e6 * m + out / 1e6 * o


def self_test():
    """The meter failing on what it exists to catch, and staying quiet
    otherwise. A budget check that cannot refuse is a receipt, not a meter."""
    ok = True

    def case(label, passed):
        nonlocal ok
        print(f"  {'caught' if passed else 'MISSED':6}  {label}")
        ok = ok and passed

    # Over the limit refuses.
    big = dollars(0, 20_000_000, 0, "peak")          # 20M miss at peak = $8.80
    case("spend over the limit refuses", big > 7.0)
    # Under the limit approves.
    small = dollars(10_000_000, 500_000, 100_000, "off")
    case("measured-shape spend approves", small < 7.0)
    # No cache fields => priced as all miss, dearer than the cached reading.
    vague = entry_tokens({"prompt_tokens": 1000, "completion_tokens": 10})
    exact = entry_tokens({"prompt_tokens": 1000, "completion_tokens": 10,
                          "prompt_cache_hit_tokens": 900,
                          "prompt_cache_miss_tokens": 100})
    case("missing cache accounting prices conservative",
         dollars(*vague, "peak") > dollars(*exact, "peak"))
    # Off-peak is exactly half of peak.
    case("off-peak halves peak",
         abs(dollars(1e6, 1e6, 1e6, "off") * 2
             - dollars(1e6, 1e6, 1e6, "peak")) < 1e-9)
    # provider spelling fallback
    case("input_tokens spelling counts",
         entry_tokens({"input_tokens": 500, "output_tokens": 5}) == (0, 500, 5))

    print("\nbudget meter", "can refuse and can approve" if ok else "IS BROKEN")
    return 0 if ok else 1


def main(argv):
    if "--self-test" in argv:
        return self_test()
    when, limit, dirs = "peak", 7.00, []
    it = iter(argv)
    for arg in it:
        if arg == "--off-peak":
            when = "off"
        elif arg == "--limit":
            limit = float(next(it))
        else:
            dirs.append(arg)
    if not dirs:
        print(__doc__.strip())
        return 2
    hit, miss, out = scan(dirs)
    spent = dollars(hit, miss, out, when)
    print(f"spent ${spent:.4f} of ${limit:.2f}"
          f"  (hit {hit:,} miss {miss:,} out {out:,}, {when} rates)")
    if spent >= limit:
        print("BUDGET REACHED: stop. The truncation priority decides what "
              "the battery loses; the meter only refuses.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
