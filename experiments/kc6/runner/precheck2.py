#!/usr/bin/env python3
"""Pre-check 2, non-collapse: arm A never-evolving must match arm B.

The machinery's PRESENCE must not tax outcomes: AN carries the tools and a
policy not to use them; B carries the tools and a door that refuses them.
Thresholds, pre-registered: within 5% on wall clock and 2% on tokens,
computed as |AN - B| / mean(AN, B); solve rates reported for judgment
against repeat noise.

    ./precheck2.py RESULTS.tsv
"""
import sys, pathlib

def rows(path):
    lines = pathlib.Path(path).read_text().splitlines()
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]

def main(path):
    pilot_families = {"f3-agent-surface", "f1-paren-balance", "f4-tlc-verdicts"}
    totals = {"AN": [0, 0, 0, 0], "B": [0, 0, 0, 0]}  # seconds tokens solved runs
    for row in rows(path):
        if row["arm"] in totals and row["family"] in pilot_families:
            t = totals[row["arm"]]
            t[0] += int(row["seconds"])
            t[1] += int(row["prompt"]) + int(row["completion"])
            t[2] += int(row["solved"])
            t[3] += 1
    for arm, (secs, toks, solved, n) in sorted(totals.items()):
        print(f"  {arm}: {n} task-runs, {secs}s, {toks:,} tokens, {solved} solved")
    if not all(t[3] for t in totals.values()):
        print("INCOMPLETE: both arms need pilot rows"); return 2
    def gap(i):
        a, b = totals["AN"][i], totals["B"][i]
        return abs(a - b) / ((a + b) / 2) if (a + b) else 0.0
    wall, tokens = gap(0), gap(1)
    print(f"  wall gap {wall:.1%} (limit 5%)   token gap {tokens:.1%} (limit 2%)")
    print(f"  solve rates: AN {totals['AN'][2]}/{totals['AN'][3]}  B {totals['B'][2]}/{totals['B'][3]} (judge against repeat noise)")
    ok = wall <= 0.05 and tokens <= 0.02
    print("PASS: the machinery's presence is not a material tax." if ok else
          "FAIL: presence alone moves the needle; report it as a tax.")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
