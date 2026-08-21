#!/usr/bin/env python3
"""Author the `ledger` and `manifest` families.

A generator rather than fifty hand-written files, for three reasons. The
corrupted-fails gate needs to damage a task's data in a controlled way, which
means the data has to be describable. Six variants of one shape have to differ
in size and content without differing in *kind*, or the family is six shapes.
And a family regenerated from a seed is a family somebody else can reproduce.

Deterministic: every variant seeds its own Random. No wall-clock, no os.urandom.
"""
import json, os, pathlib, random, shutil, stat, sys

ROOT = pathlib.Path(__file__).resolve().parent


def write(path: pathlib.Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


# ---------------------------------------------------------------------------
# Family `ledger`: total a numeric column across append-only logs that two
# writers touched. Receipt: experiments/families/RECEIPTS.md.
# ---------------------------------------------------------------------------

LEDGER_PROMPT = """\
The directory `runs/` holds append-only log files that more than one writer
appended to. Total the `cost` of every VALID, CURRENT entry and write that
single number to answer.txt, rounded DOWN to a whole number.

The rules, all of which matter and all of which are silent when broken:

  - each line is one JSON object; a line that does not parse is TORN and must
    be ignored, never repaired and never counted
  - only entries whose kind is "run" count. A "note" entry also carries a
    `cost` field and is not a run
  - a run is identified by its `id`. The SAME id may appear more than once,
    because a writer retried. Keep only the entry with the highest `seq` for
    that id and ignore the rest
  - a run whose `status` is "aborted" contributes 0, whatever its cost says
  - cost arrives as {"amount": n, "scale": s} where s is "unit", "milli" or
    "kilo". milli is n/1000, kilo is n*1000

Grading runs against a pristine copy of runs/ plus your answer.txt.
"""

LEDGER_CHECK = '''\
import glob, json, pathlib, sys

SCALES = {"unit": 1.0, "milli": 0.001, "kilo": 1000.0}
current = {}
for path in sorted(glob.glob("runs/*.jsonl")):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue                      # torn: ignored, never repaired
        if not isinstance(record, dict) or record.get("kind") != "run":
            continue
        key = record.get("id")
        seq = record.get("seq", 0)
        if key is None:
            continue
        if key not in current or seq > current[key].get("seq", 0):
            current[key] = record

want = 0.0
for record in current.values():
    if record.get("status") == "aborted":
        continue
    cost = record.get("cost") or {}
    scale = SCALES.get(cost.get("scale"))
    if scale is None:
        continue
    want += cost.get("amount", 0) * scale
want = int(want)

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(float(answer.read_text().split()[0]))
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
if got != want:
    sys.exit(f"answer {got} != {want}")
print("ok")
'''


def ledger_variant(index: int, runs: int, files: int) -> dict:
    """One variant's data plus the number a correct solution reaches."""
    rng = random.Random(1000 + index)
    entries, ids = [], []
    for n in range(runs):
        key = f"r{index}-{n:03d}"
        ids.append(key)
        scale = rng.choice(["unit", "milli", "kilo"])
        amount = rng.randint(1, 900)
        status = "aborted" if rng.random() < 0.15 else "done"
        entries.append({"kind": "run", "id": key, "seq": 1,
                        "status": status,
                        "cost": {"amount": amount, "scale": scale}})
        # A retry supersedes it, sometimes.
        if rng.random() < 0.3:
            entries.append({"kind": "run", "id": key, "seq": 2,
                            "status": "done" if status == "aborted" else status,
                            "cost": {"amount": rng.randint(1, 900),
                                     "scale": rng.choice(["unit", "milli", "kilo"])}})
        # A note carrying a cost at the same path: the decoy.
        if rng.random() < 0.4:
            entries.append({"kind": "note", "id": key, "seq": 1,
                            "text": "retried",
                            "cost": {"amount": rng.randint(1, 900), "scale": "kilo"}})
    rng.shuffle(entries)

    lines = [json.dumps(entry) for entry in entries]

    # Torn lines: what two writers produce. Two kinds, and the second is the
    # one that makes the rule load-bearing.
    #
    # A tear that leaves unsalvageable text is ignored by every solver alike,
    # so a family with only those does not test "never repair a torn line" at
    # all -- the first draft of this generator produced exactly that, and the
    # gate said so: `repairs torn lines` scored identically in all six
    # variants. That is tier3's dead decoy repeating itself.
    #
    # So some tears are REPAIRABLE INTO A WRONG RECORD: a retry at a seq above
    # anything real, truncated before its final brace. A solver that appends
    # the missing brace gets a valid entry that wins the deduplication and
    # changes the total. A solver that obeys the rule never sees it.
    torn_at = sorted(rng.sample(range(len(lines)), max(1, len(lines) // 12)))
    for at in torn_at:
        cut = rng.randint(3, max(4, len(lines[at]) - 3))
        lines[at] = lines[at][cut:] if rng.random() < 0.5 else lines[at][:cut]

    for key in rng.sample(ids, max(1, len(ids) // 6)):
        bait = json.dumps({"kind": "run", "id": key, "seq": 99, "status": "done",
                           "cost": {"amount": rng.randint(400, 900), "scale": "kilo"}})
        lines.append(bait[:-1])          # one brace short of valid

    chunks = [[] for _ in range(files)]
    for n, line in enumerate(lines):
        chunks[n % files].append(line)
    return {"files": chunks, "entries": entries}


def build_ledger(base: pathlib.Path, variants: int = 6) -> None:
    for index in range(1, variants + 1):
        made = ledger_variant(index, runs=8 + index * 4, files=2 + index % 3)
        job = base / "ledger" / f"v{index}"
        if job.exists():
            shutil.rmtree(job)
        for n, chunk in enumerate(made["files"]):
            write(job / "runs" / f"writer-{n}.jsonl", "\n".join(chunk) + "\n")
        write(job / "PROMPT", LEDGER_PROMPT)
        write(job / "check.py", LEDGER_CHECK)
        write(job / "check", "#!/bin/sh\n# Computed from the pristine data, never from a stored answer:\n"
                             "# the grader copies the job WITHOUT solution/.\nexec python3 check.py\n",
              executable=True)


# ---------------------------------------------------------------------------
# Family `manifest`: does a declaration match the thing it declares?
# Receipt: #41, and five functions I called on 2026-08-21 that did not exist.
# ---------------------------------------------------------------------------

MANIFEST_PROMPT = """\
The directory `components/` holds one subdirectory per component. Each has a
`declared.json` naming the parameters that component claims to take, and a
`run.py` implementing it.

Count the components whose DECLARATION DISAGREES WITH THEIR IMPLEMENTATION and
write that single number to answer.txt.

The implementation's truth is the signature of its `run` function, and nothing
else in the file. A component disagrees if ANY of these hold:

  - it declares a parameter the signature does not accept
  - the signature REQUIRES a parameter (no default) that the declaration does
    not name -- this direction is the expensive one and is easy to miss
  - the declaration's type for a parameter disagrees with the default in the
    signature: an int default means "integer", a str default means "string",
    a bool default means "boolean"

Two things that are NOT disagreements:

  - a component that declares no parameters at all. It claims nothing, so it
    cannot claim wrongly
  - a name that appears only in a docstring, a comment or a string. Only the
    signature counts

Grading runs against a pristine copy of components/ plus your answer.txt.
"""

MANIFEST_CHECK = '''\
import ast, glob, json, os, pathlib, sys

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


wrong = 0
for directory in sorted(glob.glob("components/*")):
    declared = json.load(open(os.path.join(directory, "declared.json")))
    parameters = declared.get("parameters") or []
    names, required, typed = signature(os.path.join(directory, "run.py"))
    if not parameters:
        continue
    declared_names = [p["name"] for p in parameters]
    bad = any(n not in names for n in declared_names)
    bad = bad or any(r not in declared_names for r in required)
    for p in parameters:
        want = typed.get(p["name"])
        if want and p.get("type") != want:
            bad = True
    if bad:
        wrong += 1

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(answer.read_text().split()[0])
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
if got != wrong:
    sys.exit(f"answer {got} != {wrong}")
print("ok")
'''

TYPE_FOR = {"int": "integer", "str": "string", "bool": "boolean"}
DEFAULTS = {"int": "0", "str": '""', "bool": "False"}


FAULTS = ["undeclared-required", "declares-unknown", "wrong-type",
          "docstring-decoy", "no-parameters", "none"]


def manifest_component(rng, index, fault=None):
    """One component, and whether it is a genuine disagreement."""
    pool = ["path", "depth", "verbose", "pattern", "limit", "name"]
    kinds = {"path": "str", "depth": "int", "verbose": "bool",
             "pattern": "str", "limit": "int", "name": "str"}
    taken = rng.sample(pool, rng.randint(1, 3))
    required = taken[: rng.randint(0, len(taken))]
    optional = [n for n in taken if n not in required]

    args = ", ".join(required + [f"{n}={DEFAULTS[kinds[n]]}" for n in optional])
    fault = fault or rng.choice(FAULTS)
    # A fault that needs a required parameter cannot land on a component that
    # has none, and silently becoming "none" is how a rule stops being tested.
    if fault == "undeclared-required" and not required:
        required, optional = taken[:1], taken[1:]
        args = ", ".join(required + [f"{n}={DEFAULTS[kinds[n]]}" for n in optional])
    if fault == "wrong-type" and not optional:
        required, optional = taken[:-1], taken[-1:]
        args = ", ".join(required + [f"{n}={DEFAULTS[kinds[n]]}" for n in optional])

    declared = [{"name": n, "type": TYPE_FOR[kinds[n]]} for n in taken]
    disagrees = False

    if fault == "undeclared-required" and required:
        declared = [d for d in declared if d["name"] != required[0]]
        disagrees = bool(declared)          # declaring nothing claims nothing
    elif fault == "declares-unknown":
        spare = [n for n in pool if n not in taken]
        if spare:
            declared.append({"name": spare[0], "type": TYPE_FOR[kinds[spare[0]]]})
            disagrees = True
    elif fault == "wrong-type" and optional:
        for d in declared:
            if d["name"] == optional[0]:
                d["type"] = "string" if d["type"] != "string" else "integer"
                disagrees = True
    elif fault == "no-parameters":
        declared = []
    elif fault == "docstring-decoy":
        spare = [n for n in pool if n not in taken]
        # DECLARED, absent from the signature, and mentioned in the docstring.
        # The correct reading is a disagreement -- the component claims a
        # parameter it cannot take. A solver that greps the file sees the name
        # and concludes it is accepted, so it does NOT flag it. That gap is
        # what makes "only the signature counts" load-bearing; the first draft
        # put the decoy on an undeclared name, where it changed nothing and the
        # gate said so.
        if spare:
            declared.append({"name": spare[0], "type": TYPE_FOR[kinds[spare[0]]]})
            disagrees = True
            fault = ("docstring", spare[0])

    decoy = fault[1] if isinstance(fault, tuple) else None
    doc = f'"""Runs the thing.{f" Ignores {decoy}." if decoy else ""}"""'
    source = f"def run({args}):\n    {doc}\n    return 0\n"
    return {"declared": {"name": f"c{index}", "parameters": declared},
            "source": source, "disagrees": disagrees}


def build_manifest(base: pathlib.Path, variants: int = 6) -> None:
    for index in range(1, variants + 1):
        rng = random.Random(2000 + index)
        job = base / "manifest" / f"v{index}"
        if job.exists():
            shutil.rmtree(job)
        # EVERY fault kind at least once, then the rest at random. A variant
        # that happens to contain no type disagreement does not test the type
        # rule, and six variants each missing a different rule is a family that
        # tests nothing reliably.
        count = 6 + index * 3
        plan = list(FAULTS) + [rng.choice(FAULTS) for _ in range(count - len(FAULTS))]
        rng.shuffle(plan)
        for n, kind in enumerate(plan):
            made = manifest_component(rng, n, fault=kind)
            where = job / "components" / f"c{n:02d}"
            write(where / "declared.json", json.dumps(made["declared"], indent=2) + "\n")
            write(where / "run.py", made["source"])
        write(job / "PROMPT", MANIFEST_PROMPT)
        write(job / "check.py", MANIFEST_CHECK)
        write(job / "check", "#!/bin/sh\n# Computed from the pristine data, never from a stored answer.\n"
                             "exec python3 check.py\n", executable=True)


if __name__ == "__main__":
    build_ledger(ROOT)
    build_manifest(ROOT)
    print("wrote", ROOT / "ledger", "and", ROOT / "manifest")
