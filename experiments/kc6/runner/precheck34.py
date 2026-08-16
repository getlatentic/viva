#!/usr/bin/env python3
"""Pre-checks 3 and 4 at the battery checkpoint: over the battery's own arm-A
cells on the bound three families, before anything past them spends.

Instrumentality (3): counts summed across the nine A-cell ledgers through
instrumentality.py's own measure(); thresholds as pre-registered — at least
50% of created versions resolved, at least 80% of creating tasks resolving.
Nothing created anywhere is a FAIL by the protocol's own line: a ledger that
cannot answer the question is not a pass.

Capability floor (4), operationalized (amendment 14): a family clears the
floor when at least one of its A repeats minted a version that later
resolved AND solved at least one task. Every bound family must clear it.

    ./precheck34.py RESULTS_DIR
"""
import sys, pathlib, importlib.util

kc6 = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("instr", kc6 / "instrumentality.py")
instr = importlib.util.module_from_spec(spec); spec.loader.exec_module(instr)

PILOT = ["f3-agent-surface", "f1-paren-balance", "f4-tlc-verdicts"]

def main(results):
    results = pathlib.Path(results)
    tsv = {}
    lines = (results / "results.tsv").read_text().splitlines()
    header = lines[0].split("\t")
    for line in lines[1:]:
        row = dict(zip(header, line.split("\t")))
        key = (row["arm"], row["family"], row["repeat"])
        tsv.setdefault(key, 0)
        tsv[key] += int(row["solved"])

    created = resolved = tasks_creating = tasks_resolving = 0
    floor = {family: False for family in PILOT}
    for family in PILOT:
        for repeat in "123":
            ledger = results / f"{family}-A-r{repeat}" / "journal" / "evolution.jsonl"
            counts = (instr.measure(instr.read_events([ledger]))
                      if ledger.exists() else None)
            if counts is None:
                print(f"  {family} r{repeat}: no ledger (nothing created)")
                continue
            created += counts["created"]; resolved += counts["resolved"]
            tasks_creating += counts["tasks_creating"]
            tasks_resolving += counts["tasks_resolving"]
            solved = tsv.get(("A", family, repeat), 0)
            print(f"  {family} r{repeat}: created {counts['created']} "
                  f"resolved {counts['resolved']} solved {solved}/5")
            if counts["resolved"] >= 1 and solved >= 1:
                floor[family] = True

    print(f"\npre-check 3, instrumentality over the nine ledgers:")
    if created == 0:
        print("  NOTHING CREATED anywhere: cannot answer the question. FAIL.")
        return 1
    v_rate = resolved / created
    t_rate = tasks_resolving / tasks_creating if tasks_creating else 0.0
    print(f"  versions {resolved}/{created} resolved ({v_rate:.0%}, need 50%)")
    print(f"  tasks {tasks_resolving}/{tasks_creating} resolving ({t_rate:.0%}, need 80%)")
    ok3 = v_rate >= 0.50 and t_rate >= 0.80

    print(f"pre-check 4, the capability floor per family:")
    for family, cleared in floor.items():
        print(f"  {family}: {'cleared' if cleared else 'NOT CLEARED'}")
    ok4 = all(floor.values())

    print("\nPASS: the battery may proceed." if (ok3 and ok4) else
          "\nFAIL: stop here. The finding is about the surface or the model, "
          "and it is a result, not a bug.")
    return 0 if (ok3 and ok4) else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
