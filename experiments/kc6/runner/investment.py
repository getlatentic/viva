#!/usr/bin/env python3
"""Per-arm investment rate, amendment 16's secondary metric.

What each cell actually invested in retention: door events from the run's
own ledger, remember calls from the transcripts, MEMORY.md growth from the
final sandbox. Descriptive, per cell and per arm; the primary decision never
reads this, but ergonomics of the mechanisms shows here for free.

    ./investment.py RESULTS_DIR
"""
import json, pathlib, re, sys

def cell_stats(cell):
    created = promoted = 0
    ledger = cell / "journal" / "evolution.jsonl"
    if ledger.exists():
        text = ledger.read_text()
        created = text.count('"improvement.created"')
        promoted = text.count('"improvement.promoted"')
    remembers = 0
    for path in cell.glob("t*-transcripts/*.jsonl"):
        for line in path.read_text(errors="replace").splitlines():
            if '"remember"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            payload = entry.get("payload") or {}
            remembers += sum(1 for block in (payload.get("content") or [])
                             if isinstance(block, dict)
                             and block.get("type") == "tool_call"
                             and block.get("name") == "remember")
    memory_lines = 0
    memory = cell / "t5-sandbox" / ".vivarium" / "MEMORY.md"
    if memory.exists():
        memory_lines = sum(1 for l in memory.read_text().splitlines() if l.strip())
    return created, promoted, remembers, memory_lines

def main(results):
    results = pathlib.Path(results)
    arms = {}
    print(f"{'cell':34}{'created':>8}{'promoted':>9}{'remember':>9}{'memory':>7}")
    for cell in sorted(results.iterdir()):
        m = re.match(r"(f\d[\w-]+)-(A|AN|B|C)-r(\d)$", cell.name)
        if not m or not cell.is_dir():
            continue
        c, p, r, mem = cell_stats(cell)
        arm = m.group(2)
        arms.setdefault(arm, [0, 0, 0, 0, 0])
        for i, v in enumerate((c, p, r, mem)):
            arms[arm][i] += v
        arms[arm][4] += 1
        print(f"{cell.name:34}{c:8}{p:9}{r:9}{mem:7}")
    print()
    for arm, (c, p, r, mem, n) in sorted(arms.items()):
        print(f"arm {arm}: {n} cells — created {c}, promoted {p}, "
              f"remember calls {r}, memory lines {mem}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
