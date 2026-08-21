#!/usr/bin/env python3
"""The reference solver, and the careless ones the gate must reject.

The careless solvers are the point. Each is a rule from the PROMPT dropped --
not a random wrong number, but the number a solver reaches by missing exactly
one thing. If any of them scores what the correct solver scores, that rule is
not load-bearing in this variant and the variant does not test it.
"""
import glob, json, os, sys

SCALES = {"unit": 1.0, "milli": 0.001, "kilo": 1000.0}


def ledger_records(directory, repair_torn=False):
    for path in sorted(glob.glob(os.path.join(directory, "runs", "*.jsonl"))):
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                if repair_torn:
                    # What "repairing" looks like: salvage the first plausible
                    # object. This is the mistake, not a fallback.
                    start = line.find("{")
                    if start >= 0:
                        try:
                            yield json.loads(line[start:] + "}")
                        except ValueError:
                            pass


def ledger_total(directory, *, keep_notes=False, first_retry=False,
                 count_aborted=False, ignore_scale=False, repair_torn=False):
    current = {}
    for record in ledger_records(directory, repair_torn=repair_torn):
        if not isinstance(record, dict):
            continue
        if not keep_notes and record.get("kind") != "run":
            continue
        if keep_notes and record.get("kind") not in ("run", "note"):
            continue
        key = record.get("id")
        if key is None:
            continue
        seq = record.get("seq", 0)
        if key not in current:
            current[key] = record
        elif first_retry:
            if seq < current[key].get("seq", 0):
                current[key] = record
        elif seq > current[key].get("seq", 0):
            current[key] = record

    total = 0.0
    for record in current.values():
        if not count_aborted and record.get("status") == "aborted":
            continue
        cost = record.get("cost") or {}
        if ignore_scale:
            total += cost.get("amount", 0)
            continue
        scale = SCALES.get(cost.get("scale"))
        if scale is None:
            continue
        total += cost.get("amount", 0) * scale
    return int(total)


CARELESS = [
    ("counts notes as runs", dict(keep_notes=True)),
    ("keeps the first retry", dict(first_retry=True)),
    ("counts aborted runs", dict(count_aborted=True)),
    ("ignores the scale", dict(ignore_scale=True)),
    ("repairs torn lines", dict(repair_torn=True)),
]


def main():
    family, directory = sys.argv[1], sys.argv[2]
    if "--careless-count" in sys.argv:
        print(len(CARELESS))
        return
    careless = "--careless" in sys.argv
    if family != "ledger":
        sys.exit(f"no solver for family {family}")
    if not careless:
        print(ledger_total(directory))
        return
    right = ledger_total(directory)
    for _, options in CARELESS:
        value = ledger_total(directory, **options)
        if value != right:
            print(value)


if __name__ == "__main__":
    main()
