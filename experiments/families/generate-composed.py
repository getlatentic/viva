#!/usr/bin/env python3
"""The four families authored for the composition regime.

Separate from `generate.py`, which authored `ledger` and `manifest` before the
depth-two requirement was written down. These four are built against the
amended criteria in docs/b15-preregistration.md:

  - TWO reusable transformations per family, not one, so a task can need both
    composed. Depth one is just graduation; depth two is the claim.
  - hard enough that the model does not solve a variant in a single request.
    RECEIPTS.md records that ledger and manifest solve 12 of 12 mostly in one,
    which is a ceiling on what they can show: derivation that takes one request
    leaves almost nothing for retention to save.
  - every rule exercised in every variant, so a variant cannot quietly stop
    testing one of them.

Deterministic: every variant seeds its own Random. No wall-clock, no urandom.
"""
import json
import pathlib
import random
import shutil
import stat

ROOT = pathlib.Path(__file__).resolve().parent / "jobs"


def load_solvers():
    """solve.py's reference and careless solvers, imported rather than copied."""
    import importlib.util
    here = pathlib.Path(__file__).resolve().parent / "solve.py"
    spec = importlib.util.spec_from_file_location("family_solvers", here)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def discriminating(module, family: str, job: pathlib.Path) -> bool:
    """Does every careless solver score differently here?

    THE GENERATOR CHECKS ITS OWN GATE. Fixing a variant the gate rejected, only
    for the next seed to produce the same weakness somewhere else, is
    whack-a-mole -- and each round leaves a rule silently untested until the
    gate happens to notice. Asserting it while generating makes the property
    structural rather than lucky.
    """
    solver, careless = module.SOLVERS[family]
    right = solver(str(job))
    return all(solver(str(job), **options) != right for _, options in careless)


def build_variant(family, builder, job, seeds):
    """Build JOB with the first seed whose data exercises every rule."""
    module = load_solvers()
    for attempt, seed in enumerate(seeds):
        if job.exists():
            shutil.rmtree(job)
        builder(seed)
        if discriminating(module, family, job):
            return attempt
    raise SystemExit(
        f"{family}/{job.name}: no seed in {len(seeds)} made every rule load-bearing. "
        "The family's rules overlap; change the shape rather than the seed."
    )


def write(path: pathlib.Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def emit(job: pathlib.Path, prompt: str, check: str) -> None:
    write(job / "PROMPT", prompt)
    write(job / "graded", "answer.txt\n")
    write(job / "check.py", check)
    write(job / "check",
          "#!/bin/sh\n# Computed from the pristine data, never from a stored answer.\n"
          "exec python3 check.py\n", executable=True)


# ---------------------------------------------------------------------------
# `windows`: sessionise events whose clocks disagree.
#
# T1 normalise a timestamp: per-file offset, plus a skew record that applies to
#    one writer only.
# T2 keep the current revision of an event id.
# Composed: total active seconds needs both -- deduping before normalising
#    picks the wrong survivor when two revisions straddle an offset.
# ---------------------------------------------------------------------------

WINDOWS_PROMPT = """\
`events/` holds one file per writer. Report TWO numbers to answer.txt on one
line, separated by a space: the number of sessions, then the total active
seconds across all of them.

  - each line is one JSON object; a line that does not parse is TORN and is
    ignored, never repaired
  - `at` is seconds since the epoch AS THAT WRITER'S CLOCK SAW IT. Each file
    begins with a `{"kind": "clock", ...}` line giving that writer's `offset`,
    which must be ADDED to every `at` in the file to reach true time
  - a writer whose clock line also carries `"skew": n` drifts: the correction
    for its k-th event (0-based, counting only kind "event") is offset + k*n
  - only entries of kind "event" are events. A "heartbeat" carries an `at` and
    is NOT an event: it neither opens a session nor extends one
  - the same `id` may appear more than once; keep only the highest `rev`. A
    lower rev may appear LATER in the file
  - sessions are built from the surviving events in TRUE time order: a session
    continues while consecutive events are <= 120 seconds apart, and a gap
    greater than that starts a new one
  - a session's active seconds is its last true time minus its first; a session
    of one event contributes 0

Grading runs against a pristine copy of events/ plus your answer.txt.
"""

WINDOWS_CHECK = '''\
import glob, json, pathlib, sys

events = []
for path in sorted(glob.glob("events/*.jsonl")):
    offset, skew, index = 0, 0, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("kind") == "clock":
            offset = record.get("offset", 0)
            skew = record.get("skew", 0)
            continue
        if record.get("kind") != "event":
            continue
        true_at = record.get("at", 0) + offset + index * skew
        index += 1
        events.append((record.get("id"), record.get("rev", 0), true_at))

current = {}
for key, rev, at in events:
    if key is None:
        continue
    if key not in current or rev > current[key][0]:
        current[key] = (rev, at)

times = sorted(at for _, at in current.values())
sessions, active = 0, 0
start = previous = None
for at in times:
    if start is None:
        start = previous = at
        sessions = 1
        continue
    if at - previous > 120:
        active += previous - start
        sessions += 1
        start = at
    previous = at
if start is not None:
    active += previous - start

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
parts = answer.read_text().split()
if len(parts) < 2:
    sys.exit("answer.txt needs two numbers")
try:
    got = (int(parts[0]), int(float(parts[1])))
except ValueError:
    sys.exit("answer.txt is not two numbers")
if got != (sessions, active):
    sys.exit(f"answer {got} != {(sessions, active)}")
print("ok")
'''


def build_windows(base: pathlib.Path, variants: int = 6) -> None:
    for index in range(1, variants + 1):
        job = base / "windows" / f"v{index}"
        build_variant("windows", lambda seed: _windows_variant(job, index, seed),
                      job, [3000 + index + n * 97 for n in range(40)])


def _windows_variant(job: pathlib.Path, index: int, seed: int) -> None:
        rng = random.Random(seed)
        writers = 2 + index % 3
        # ONE BASE TIME for every writer, so their events INTERLEAVE. With each
        # writer in its own stretch of the day, a per-file offset shifts a whole
        # block and changes no gap within it -- the offset rule stopped being
        # load-bearing and the gate said so. Overlapping ranges make an offset
        # genuinely reorder events against the other writers.
        base_time = rng.randint(1_700_000_000, 1_700_050_000)
        # And every rule is exercised at least once per variant. A variant whose
        # writers all happen to have zero skew does not test the skew rule, and
        # six variants each missing a different rule is a family that tests
        # nothing reliably.
        # Cycled rather than sliced: `writers` can exceed the list, and a slice
        # then leaves the later writers with no offset at all.
        offsets = [[3600, -1800, 7200][n % 3] for n in range(writers)]
        skews = [[1, 0, -1][n % 3] for n in range(writers)]
        if writers > 1:
            rng.shuffle(offsets)
            rng.shuffle(skews)
        if all(value == 0 for value in skews):
            skews[0] = 1
        for writer in range(writers):
            lines = []
            offset = offsets[writer]
            skew = skews[writer]
            clock = {"kind": "clock", "offset": offset}
            if skew:
                clock["skew"] = skew
            lines.append(json.dumps(clock))
            at = base_time + rng.randint(0, 400)
            seen_heartbeat = seen_torn = seen_revision = False
            for n in range(8 + index * 4):
                at += rng.choice([5, 30, 90, 200, 400])
                key = f"w{writer}-{n:03d}"
                lines.append(json.dumps(
                    {"kind": "event", "id": key, "rev": 1, "at": at}))
                # A superseding revision, sometimes out of order.
                if rng.random() < 0.25 or (n == 2 and not seen_revision):
                    seen_revision = True
                    later = json.dumps(
                        {"kind": "event", "id": key, "rev": 2, "at": at + rng.randint(1, 40)})
                    if rng.random() < 0.5:
                        lines.append(later)
                    else:
                        lines.insert(max(1, len(lines) - 2), later)
                # The decoy: a heartbeat with a timestamp that is not an event.
                # Placed far enough out that counting it would open a session,
                # so the rule changes the answer rather than only the arithmetic.
                if rng.random() < 0.35 or (n == 3 and not seen_heartbeat):
                    seen_heartbeat = True
                    lines.append(json.dumps({"kind": "heartbeat", "at": at + 400}))
                # A torn line.
                if rng.random() < 0.12 or (n == 4 and not seen_torn):
                    seen_torn = True
                    lines.append('{"kind": "event", "id": "torn", ')
            write(job / "events" / f"w{writer}.jsonl", "\n".join(lines) + "\n")
        emit(job, WINDOWS_PROMPT, WINDOWS_CHECK)


# ---------------------------------------------------------------------------
# `invoices`: tiered charges, refunds that reference them.
#
# T1 the tiered price of a quantity, given cumulative units already billed.
# T2 the net of a charge after refunds, where a refund of an already-refunded
#    charge is void.
# Composed: the account total needs both, and refunds must be applied to the
#    TIERED price rather than the list price.
# ---------------------------------------------------------------------------

INVOICES_PROMPT = """\
`accounts/` holds one file per account. Write the total owed across ALL
accounts to answer.txt, rounded DOWN to a whole number.

  - each line is one JSON object; a line that does not parse is ignored
  - `tiers` (the first line of each file) is a list of {"upto": u, "rate": r}
    in ascending order, with the last having no `upto`, meaning the rest.
    Units are billed cumulatively PER ACCOUNT in file order: the first units
    fall in the first tier until `upto` is exhausted, then the next tier
  - a `charge` has an `id` and `units`. Its price is the tiered cost of its
    units, continuing the account's running total
  - a charge whose `status` is "pending" is NOT billed and does NOT consume
    tier capacity
  - a `refund` has `of`, naming a charge id, and refunds that charge in full.
    A refund naming a charge that does not exist, is pending, or has already
    been refunded is VOID and does nothing
  - a `credit` entry looks similar and is not a refund: it subtracts its
    `amount` from the account total directly, and never consumes tier capacity

Grading runs against a pristine copy of accounts/ plus your answer.txt.
"""

INVOICES_CHECK = '''\
import glob, json, pathlib, sys

total = 0.0
for path in sorted(glob.glob("accounts/*.jsonl")):
    tiers, entries = None, []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("kind") == "tiers":
            tiers = record.get("tiers") or []
            continue
        entries.append(record)

    if not tiers:
        continue

    def priced(units, used):
        """Tiered cost of UNITS given USED already billed."""
        cost, left, at = 0.0, units, used
        for tier in tiers:
            cap = tier.get("upto")
            room = float("inf") if cap is None else max(0, cap - at)
            take = min(left, room)
            cost += take * tier.get("rate", 0)
            at += take
            left -= take
            if left <= 0:
                break
        return cost

    used, charges, account = 0, {}, 0.0
    for record in entries:
        kind = record.get("kind")
        if kind == "charge":
            if record.get("status") == "pending":
                continue
            cost = priced(record.get("units", 0), used)
            used += record.get("units", 0)
            charges[record.get("id")] = {"cost": cost, "refunded": False}
            account += cost
        elif kind == "refund":
            target = charges.get(record.get("of"))
            if target and not target["refunded"]:
                target["refunded"] = True
                account -= target["cost"]
        elif kind == "credit":
            account -= record.get("amount", 0)
    total += account

want = int(total)
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


def build_invoices(base: pathlib.Path, variants: int = 6) -> None:
    for index in range(1, variants + 1):
        job = base / "invoices" / f"v{index}"
        build_variant("invoices", lambda seed: _invoices_variant(job, index, seed),
                      job, [4000 + index + n * 89 for n in range(40)])


def _invoices_variant(job: pathlib.Path, index: int, seed: int) -> None:
        rng = random.Random(seed)
        for account in range(2 + index % 3):
            tiers = [{"upto": rng.choice([50, 100, 200]), "rate": rng.choice([5, 8, 10])},
                     {"upto": rng.choice([400, 600]), "rate": rng.choice([2, 3, 4])},
                     {"rate": 1}]
            lines = [json.dumps({"kind": "tiers", "tiers": tiers})]
            issued = []
            issued_refund = False
            for n in range(6 + index * 3):
                key = f"c{account}-{n:03d}"
                # A pending charge EARLY, before the tiers are exhausted. Left
                # to chance it landed late in v1, where consuming its capacity
                # changed nothing -- the rule was in the prompt and not in the
                # answer, and the gate said so.
                pending = (n == 1) or rng.random() < 0.18
                lines.append(json.dumps({
                    "kind": "charge", "id": key,
                    "units": rng.randint(5, 140),
                    **({"status": "pending"} if pending else {}),
                }))
                if not pending:
                    issued.append(key)
                if (rng.random() < 0.3 or (n == 3 and not issued_refund)) and issued:
                    issued_refund = True
                    lines.append(json.dumps({"kind": "refund", "of": rng.choice(issued)}))
                if rng.random() < 0.15:
                    # Void by construction: names a charge that never exists.
                    lines.append(json.dumps({"kind": "refund", "of": f"missing-{n}"}))
                if rng.random() < 0.2:
                    lines.append(json.dumps({"kind": "credit", "amount": rng.randint(1, 30)}))
                if rng.random() < 0.1:
                    lines.append('{"kind": "charge", "id": "torn"')
            write(job / "accounts" / f"a{account}.jsonl", "\n".join(lines) + "\n")
        emit(job, INVOICES_PROMPT, INVOICES_CHECK)


if __name__ == "__main__":
    build_windows(ROOT)
    build_invoices(ROOT)
    print("wrote", ROOT / "windows", "and", ROOT / "invoices")
