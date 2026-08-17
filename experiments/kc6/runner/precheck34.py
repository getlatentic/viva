#!/usr/bin/env python3
"""Pre-checks 3 and 4 at the battery checkpoint — channel-aware since
amendment 17, because the policy's f1/f2 split proved retention follows
content shape: knowledge retains as text, transformations compile. A floor
that demanded compilation from knowledge-shaped families would fail the
policy for being right.

Anti-placebo teeth, kept: SOMETHING must be retained (a battery where
nothing is retained in any channel measures a prompt), and WHERE the door
was used, the door-instrumentality thresholds apply unchanged — at least
50% of created versions resolved, at least 80% of creating tasks resolving.

Floor (4'): every bound family clears when at least one of its A repeats
solved at least one task AND retained through either channel — a resolved
capability, or at least one remember call.

    ./precheck34.py RESULTS_DIR
"""
import sys, pathlib, json

PILOT = ["f3-agent-surface", "f1-paren-balance", "f4-tlc-verdicts"]

def door_counts(ledger):
    if not ledger.exists():
        return 0, 0
    text = ledger.read_text()
    return text.count('"improvement.created"'), text.count('"improvement.resolved"')

def remember_calls(cell):
    calls = 0
    for path in cell.glob("t*-transcripts/*.jsonl"):
        for line in path.read_text(errors="replace").splitlines():
            if '"remember"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            payload = entry.get("payload") or {}
            calls += sum(1 for block in (payload.get("content") or [])
                         if isinstance(block, dict)
                         and block.get("type") == "tool_call"
                         and block.get("name") == "remember")
    return calls

def main(results):
    results = pathlib.Path(results)
    solved_by = {}
    lines = (results / "results.tsv").read_text().splitlines()
    header = lines[0].split("\t")
    for line in lines[1:]:
        row = dict(zip(header, line.split("\t")))
        key = (row["arm"], row["family"], row["repeat"])
        solved_by[key] = solved_by.get(key, 0) + int(row["solved"])

    created = resolved = text_total = 0
    creating_tasks = resolving_tasks = 0
    floor = {family: False for family in PILOT}
    print(f"{'cell':30}{'created':>8}{'resolved':>9}{'remember':>9}{'solved':>7}")
    for family in PILOT:
        for repeat in "123":
            cell = results / f"{family}-A-r{repeat}"
            c, r = door_counts(cell / "journal" / "evolution.jsonl")
            t = remember_calls(cell)
            s = solved_by.get(("A", family, repeat), 0)
            created += c; resolved += r; text_total += t
            if c:
                creating_tasks += 1
                if r:
                    resolving_tasks += 1
            print(f"{family + ' r' + repeat:30}{c:8}{r:9}{t:9}{s:7}/5")
            if s >= 1 and ((c and r) or t):
                floor[family] = True

    print("\npre-check 3', retention instrumentality (channel-aware):")
    if created == 0 and text_total == 0:
        print("  NOTHING RETAINED in any channel: the battery would measure "
              "a prompt. FAIL.")
        return 1
    ok3 = True
    if created:
        v_rate = resolved and resolved / created or 0.0
        t_rate = resolving_tasks / creating_tasks if creating_tasks else 0.0
        print(f"  door: {resolved}/{created} versions resolved ({v_rate:.0%}, need 50%); "
              f"{resolving_tasks}/{creating_tasks} creating cells resolving ({t_rate:.0%}, need 80%)")
        ok3 = v_rate >= 0.50 and t_rate >= 0.80
    else:
        print(f"  door unused in the bound three; text retention nonzero "
              f"({text_total} calls) — door instrumentality defers to the "
              f"transformation families (f2, f6), noted, not failed")
    print(f"  text: {text_total} remember calls across the nine cells")

    print("pre-check 4', the floor (either channel + a solve), per family:")
    for family, cleared in floor.items():
        print(f"  {family}: {'cleared' if cleared else 'NOT CLEARED'}")
    ok4 = all(floor.values())

    print("\nPASS: the battery may proceed." if (ok3 and ok4) else
          "\nFAIL: stop here, by protocol.")
    return 0 if (ok3 and ok4) else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
