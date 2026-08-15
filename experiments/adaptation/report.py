"""Read results.tsv and say what it does and does not support.

The headline number is not the solve rate -- both arms are expected to solve
most tasks, because the tasks are ordinary. It is the COST: whether the work
needed per task falls across the sequence when memory carries forward, and does
not when it is wiped.

A first-half / second-half split rather than a regression line: with six tasks
per sequence a slope is noise wearing a coat, and the halves at least say which
direction the noise is pointing.
"""
import sys, collections


def read(path):
    rows = []
    with open(path) as handle:
        header = handle.readline().rstrip("\n").split("\t")
        for line in handle:
            values = line.rstrip("\n").split("\t")
            if len(values) != len(header):
                continue
            row = dict(zip(header, values))
            for key in ("sequence", "position", "solved", "requests", "toolcalls",
                        "seconds", "remembered"):
                row[key] = int(row[key] or 0)
            rows.append(row)
    return rows


def mean(values):
    return sum(values) / len(values) if values else 0.0


def main(path):
    rows = read(path)
    if not rows:
        print("no results")
        return 1
    arms = sorted({row["arm"] for row in rows})
    positions = sorted({row["position"] for row in rows})
    half = (max(positions) + 1) // 2

    print(f"{'arm':<12}{'solved':>9}{'calls/task':>12}{'first half':>12}"
          f"{'second half':>13}{'change':>9}")
    for arm in arms:
        mine = [row for row in rows if row["arm"] == arm]
        early = [row["toolcalls"] for row in mine if row["position"] <= half]
        late = [row["toolcalls"] for row in mine if row["position"] > half]
        change = mean(late) - mean(early)
        print(f"{arm:<12}{sum(r['solved'] for r in mine):>4}/{len(mine):<4}"
              f"{mean([r['toolcalls'] for r in mine]):>12.1f}"
              f"{mean(early):>12.1f}{mean(late):>13.1f}{change:>+9.1f}")

    print(f"\n{'':14}" + "".join(f"{p:>7}" for p in positions) + "   (tool calls by position)")
    for arm in arms:
        line = []
        for position in positions:
            at = [row["toolcalls"] for row in rows
                  if row["arm"] == arm and row["position"] == position]
            line.append(f"{mean(at):>7.1f}")
        print(f"{arm:<14}" + "".join(line))

    print(f"\n{'':14}" + "".join(f"{p:>7}" for p in positions) + "   (memory lines carried in)")
    for arm in arms:
        line = []
        for position in positions:
            at = [row["remembered"] for row in rows
                  if row["arm"] == arm and row["position"] == position]
            line.append(f"{mean(at):>7.1f}")
        print(f"{arm:<14}" + "".join(line))

    failures = [row for row in rows if not row["solved"]]
    if failures:
        print("\nunsolved:")
        for row in failures:
            print(f"  {row['arm']:<11} seq {row['sequence']} pos {row['position']} "
                  f"{row['task']}  ({row['requests']} requests)")

    carrying = [row for row in rows if row["arm"] in ("accumulate", "nudged")]
    wrote = [row for row in carrying if row["remembered"]]
    if carrying and not wrote:
        print("\nThe agent never used `remember`. That is a finding about the default,"
              "\nnot a failed experiment: with nothing carried forward the two arms are"
              "\nthe same experiment run twice, and any difference between them is the"
              "\nnoise floor. The next question is whether a line in the system prompt"
              "\nchanges it -- which is a different measurement, stated separately.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "results.tsv"))
