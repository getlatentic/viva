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


# ---------------------------------------------------------------------------
# Family `manifest`
# ---------------------------------------------------------------------------

import ast

TYPES = {int: "integer", str: "string", bool: "boolean", float: "number"}


def signature(path):
    tree = ast.parse(open(path).read())
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "run":
            names = [a.arg for a in node.args.args]
            defaults = node.args.defaults
            required = names[: len(names) - len(defaults)]
            typed = {}
            for name, default in zip(names[len(names) - len(defaults):], defaults):
                if isinstance(default, ast.Constant):
                    typed[name] = TYPES.get(type(default.value))
            return names, required, typed
    return [], [], {}


def manifest_total(directory, *, one_direction=False, grep_the_file=False,
                   flag_empty=False, ignore_types=False):
    wrong = 0
    for where in sorted(glob.glob(os.path.join(directory, "components", "*"))):
        declared = json.load(open(os.path.join(where, "declared.json")))
        parameters = declared.get("parameters") or []
        source_path = os.path.join(where, "run.py")
        names, required, typed = signature(source_path)
        if grep_the_file:
            # The mistake: any name mentioned anywhere counts as accepted, so a
            # docstring is treated as an interface.
            text = open(source_path).read()
            names = list({n for n in ["path", "depth", "verbose", "pattern",
                                      "limit", "name"] if n in text})
        if not parameters:
            if flag_empty:
                wrong += 1
            continue
        declared_names = [p["name"] for p in parameters]
        bad = any(n not in names for n in declared_names)
        if not one_direction:
            bad = bad or any(r not in declared_names for r in required)
        if not ignore_types:
            for p in parameters:
                want = typed.get(p["name"])
                if want and p.get("type") != want:
                    bad = True
        if bad:
            wrong += 1
    return wrong


MANIFEST_CARELESS = [
    ("checks one direction only", dict(one_direction=True)),
    ("greps the file instead of reading the signature", dict(grep_the_file=True)),
    ("flags components that declare nothing", dict(flag_empty=True)),
    ("ignores type disagreement", dict(ignore_types=True)),
]

SOLVERS = {"ledger": (ledger_total, CARELESS),
           "manifest": (manifest_total, MANIFEST_CARELESS)}


def main():
    family, directory = sys.argv[1], sys.argv[2]
    if family not in SOLVERS:
        sys.exit(f"no solver for family {family}")
    solver, careless_solvers = SOLVERS[family]
    if "--careless-count" in sys.argv:
        print(len(careless_solvers))
        return
    if "--careless" not in sys.argv:
        print(solver(directory))
        return
    right = solver(directory)
    for _, options in careless_solvers:
        value = solver(directory, **options)
        if value != right:
            print(value)


if __name__ == "__main__":
    main()
