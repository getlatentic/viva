#!/usr/bin/env python3
"""Pre-check three: were the versions the agent created ever actually USED?

KC6 compares an organism that can rewrite itself against one that cannot. If
the agent creates versions and nothing ever resolves to them, the arm-A
treatment is a paragraph in a system prompt and the experiment measures a
placebo. This joins each improvement.activated to the improvement.resolved
events that follow it in the same ledger, and reports the two rates the
protocol pre-registered.

The join is only sound because the ledger is ordered and the owner records use
after the activation that caused it -- a worker journalling its own use would
race the owner's publish. tests/daemon.lisp asserts that ordering at the
ledger, which is the file this program reads.

    ./instrumentality.py LEDGER.jsonl [LEDGER.jsonl ...]
    ./instrumentality.py --self-test

Exit 0 if both pre-registered thresholds are met, 1 if not, 2 on bad input.
"""
import json
import pathlib
import sys

RESOLVED_RATE = 0.50   # of created versions, at least one resolution
TASK_RATE = 0.80       # of tasks that created a version, at least one resolution


def read_events(paths):
    """Every ledger line, in file order, as (name, data)."""
    events = []
    for path in paths:
        text = pathlib.Path(path).read_text(errors="replace")
        for line in text.splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            name = entry.get("event")
            if name:
                events.append((name, entry.get("data") or {}))
    return events


def measure(events):
    """Created versions, those resolved after their activation, and by task.

    A resolution BEFORE the version was activated is not evidence of use --
    it would mean the join is reading a different causal story than the one
    the protocol claims -- so position in the ledger decides, not membership.
    """
    created = set()
    # version -> ledger index at which it first became REACHABLE. Two channels
    # make a version reachable and both count: a task pin (activated) and the
    # promoted default (promoted). Counting only activations missed promotion
    # entirely -- which is the channel the protocol's transfer metric rests on,
    # since a held-out family resolves promoted defaults and pins nothing.
    reachable_at = {}
    task_of = {}
    resolved = set()
    tasks_creating = set()
    tasks_resolving = set()
    doors = set()

    for index, (name, data) in enumerate(events):
        version = data.get("version")
        task = data.get("task")
        if name == "improvement.door":
            doors.add(data.get("door"))
        elif name == "improvement.created":
            created.add(version)
        elif name == "improvement.activated":
            reachable_at.setdefault(version, index)
            task_of[version] = task
            if task is not None:
                tasks_creating.add(task)
        elif name == "improvement.promoted":
            reachable_at.setdefault(version, index)
        elif name == "improvement.resolved":
            if version in reachable_at and index > reachable_at[version]:
                resolved.add(version)
                if task is not None:
                    tasks_resolving.add(task)

    return {
        # The set, not the last one seen. A ledger holding two different doors
        # is more than one run, and every count below it is a blend of arms.
        # Taking the last would have answered confidently about a mixture --
        # which it did, on the suite's own ledger, the first time this ran.
        "doors": doors,
        "created": len(created),
        "reachable": len(reachable_at),
        "resolved": len(resolved & created),
        "tasks_creating": len(tasks_creating),
        "tasks_resolving": len(tasks_resolving & tasks_creating),
    }


def report(counts):
    created = counts["created"]
    tasks = counts["tasks_creating"]
    version_rate = counts["resolved"] / created if created else 0.0
    task_rate = counts["tasks_resolving"] / tasks if tasks else 0.0
    doors = counts["doors"]

    # REFUSE before reporting. Every branch below this either judges a single
    # run or declines; none of them may return 0 without having checked
    # something, which is how the first version of this passed a mixed ledger.
    if len(doors) > 1:
        print(f"MIXED LEDGER: doors {sorted(str(d) for d in doors)}. This file "
              f"holds more than one run and every count in it blends arms. "
              f"Point this at one run's ledger.", file=sys.stderr)
        return 2
    if not doors:
        print("NO ARM RECORDED: this ledger has no improvement.door event, so "
              "the arm it came from is unknown and the check cannot be "
              "attributed. Re-run against a ledger written by this build.",
              file=sys.stderr)
        return 2

    door = next(iter(doors))
    print(f"door                 {door or 'unrecorded'}")
    print(f"versions created     {created}")
    print(f"versions reachable   {counts['reachable']}   "
          f"(activated or promoted)")
    print(f"versions resolved    {counts['resolved']}   "
          f"{version_rate:.0%} (need {RESOLVED_RATE:.0%})")
    print(f"tasks creating       {tasks}")
    print(f"tasks resolving      {counts['tasks_resolving']}   "
          f"{task_rate:.0%} (need {TASK_RATE:.0%})")

    if door == "closed":
        # Not a pass: arm B is the wrong ledger for this question, and saying
        # so with a zero exit is how a mis-pointed pre-check reads as green.
        print("\nARM B: a closed door creates no resolutions by proven law "
              "(ClosedDoorIsInert). This check applies to arm A; nothing was "
              "verified here.", file=sys.stderr)
        return 2
    if created == 0:
        print("\nNOTHING CREATED: this ledger cannot answer the question. "
              "Not a pass.")
        return 1

    ok = version_rate >= RESOLVED_RATE and task_rate >= TASK_RATE
    print("\nPASS: created versions are genuinely resolved by later turns."
          if ok else
          "\nFAIL: the agent creates versions that nothing runs. KC6 would "
          "measure a prompt, not the machinery. Fix the harness first.")
    return 0 if ok else 1


def self_test():
    """The checker must be able to fail, so here it is failing.

    Written after three attack tests in this project passed against the code
    they were meant to catch. A checker whose FAIL branch has never executed
    is a checker whose FAIL branch does not work.
    """
    def event(name, **data):
        return (name, data)

    used = [
        event("improvement.door", door="open"),
        event("improvement.created", version=1),
        event("improvement.activated", version=1, task="t1"),
        event("improvement.resolved", version=1, task="t1"),
    ]
    assert measure(used)["resolved"] == 1, "a plain use was not counted"

    unused = used[:3]
    assert measure(unused)["resolved"] == 0, "an unused version counted as used"
    assert report(measure(unused)) == 1, "the placebo case did not fail"

    # Order is load-bearing: a resolution recorded BEFORE its activation is
    # not evidence of use, and this is the one the ordering test defends.
    inverted = [
        event("improvement.door", door="open"),
        event("improvement.created", version=1),
        event("improvement.resolved", version=1, task="t1"),
        event("improvement.activated", version=1, task="t1"),
    ]
    assert measure(inverted)["resolved"] == 0, "an out-of-order use counted"

    # A task that created and never resolved drags the task rate down.
    mixed = used + [
        event("improvement.created", version=2),
        event("improvement.activated", version=2, task="t2"),
    ]
    counts = measure(mixed)
    assert counts["tasks_creating"] == 2 and counts["tasks_resolving"] == 1, counts
    assert report(counts) == 1, "50% of tasks resolving passed an 80% bar"

    # THE ONE THIS CHECKER ACTUALLY GOT WRONG. Pointed at the suite's own
    # ledger -- many runs, both arms, one file -- the first version read the
    # last door event, announced "arm B, not my business", and exited 0. A
    # pre-check with a path that returns green without checking anything is
    # the failure it exists to prevent, so both refusals are asserted here.
    two_runs = used + [event("improvement.door", door="closed")]
    assert report(measure(two_runs)) == 2, "a mixed-arm ledger was judged"
    doorless = [event("improvement.created", version=1)]
    assert report(measure(doorless)) == 2, "an unattributable ledger was judged"
    assert report(measure([event("improvement.door", door="closed")])) == 2, \
        "arm B's ledger reported a pass"

    print("\ninstrumentality self-test: the checker fails when it should")
    return 0


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    if argv[0] == "--self-test":
        return self_test()
    missing = [p for p in argv if not pathlib.Path(p).exists()]
    if missing:
        print(f"no such ledger: {', '.join(missing)}", file=sys.stderr)
        return 2
    return report(measure(read_events(argv)))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
