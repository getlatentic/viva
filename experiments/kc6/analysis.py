#!/usr/bin/env python3
"""The KC6 analysis: a program over results.tsv, as pre-registered.

Primary: A vs C paired by family — cost per solved task in tokens, and
late-position (4-5) solve rate. Decision: one-sided sign test at n = 6
(all six families must agree that A helps), effect floor of a 30% token
reduction per solved task or +0.20 late solve rate. Arm-B control at n = 3:
A at least matches B on the bound three, no family showing B better by the
effect size. Secondary: per-arm investment, transfer described, never tested.

    ./analysis.py results/results.tsv
"""
import sys, pathlib, collections

def rows(path):
    lines = pathlib.Path(path).read_text().splitlines()
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]

def main(path):
    data = rows(path)
    agg = collections.defaultdict(lambda: dict(tokens=0, solved=0, runs=0,
                                               late_solved=0, late_runs=0,
                                               early_solved=0, early_runs=0,
                                               seconds=0))
    for row in data:
        cell = agg[(row["arm"], row["family"])]
        cell["tokens"] += int(row["prompt"]) + int(row["completion"])
        cell["solved"] += int(row["solved"])
        cell["runs"] += 1
        cell["seconds"] += int(row["seconds"])
        position = int(row["position"])
        if position >= 4:
            cell["late_solved"] += int(row["solved"]); cell["late_runs"] += 1
        if position <= 2:
            cell["early_solved"] += int(row["solved"]); cell["early_runs"] += 1

    families = sorted({family for _, family in agg}, )
    def tps(arm, family):
        cell = agg[(arm, family)]
        return cell["tokens"] / cell["solved"] if cell["solved"] else float("inf")
    def late(arm, family):
        cell = agg[(arm, family)]
        return cell["late_solved"] / cell["late_runs"] if cell["late_runs"] else 0.0

    print("PRIMARY, A vs C paired by family")
    print(f"{'family':22}{'A tok/solved':>13}{'C tok/solved':>13}{'delta':>8}"
          f"{'A late':>8}{'C late':>8}{'A helps?':>9}")
    agree = 0
    effects = []
    for family in families:
        a, c = tps("A", family), tps("C", family)
        delta = (c - a) / c if c else 0.0
        al, cl = late("A", family), late("C", family)
        helps = a < c or al > cl
        agree += helps
        effects.append((family, delta, al - cl))
        print(f"{family:22}{a:13,.0f}{c:13,.0f}{delta:8.1%}{al:8.0%}{cl:8.0%}"
              f"{'yes' if helps else 'NO':>9}")
    print(f"\nsign test: {agree}/6 families agree A helps "
          f"(unanimity required; p = 0.016 when 6/6)")
    meets = [f for f, d, ls in effects if d >= 0.30 or ls >= 0.20]
    print(f"effect floor (>=30% tokens/solved or +0.20 late solve): "
          f"{len(meets)}/6 families meet it: {', '.join(meets) or '-'}")

    print("\nARM-B CONTROL (bound three, consistency at n=3)")
    control_ok = True
    for family in ["f3-agent-surface", "f1-paren-balance", "f4-tlc-verdicts"]:
        a, b = tps("A", family), tps("B", family)
        worse = (a - b) / b if b else 0.0
        flag = "ok" if a <= b else ("TOLERABLE" if worse < 0.30 else "B BETTER BY EFFECT SIZE")
        if worse >= 0.30:
            control_ok = False
        print(f"  {family:22} A {a:10,.0f}  B {b:10,.0f}  A vs B {worse:+.1%}  {flag}")

    print("\nSECONDARY")
    for arm in ["A", "AN", "B", "C"]:
        total_tokens = sum(cell["tokens"] for (a, _), cell in agg.items() if a == arm)
        total_solved = sum(cell["solved"] for (a, _), cell in agg.items() if a == arm)
        total_runs = sum(cell["runs"] for (a, _), cell in agg.items() if a == arm)
        if total_runs:
            print(f"  arm {arm}: {total_solved}/{total_runs} solved, "
                  f"{total_tokens:,} tokens, {total_tokens/max(total_solved,1):,.0f}/solved")

    print("\nVERDICT INPUTS: unanimity", agree == 6,
          "| effect floor met on the agreeing set:", len(meets),
          "| control:", "pass" if control_ok else "fail")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
