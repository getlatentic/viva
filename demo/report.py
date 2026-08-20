#!/usr/bin/env python3
"""What did the organism keep, and did anything use it?

Reads only what the run left behind: the workspace's .vivarium/, and the
transcripts of the five tasks. Nothing is inferred -- a tool counts as reused
when a transcript shows the model calling it by name, and a note counts as
carried when it is in the memory file a later task was given.

Reports honestly when nothing was retained. A demo that can only describe
success is an advertisement.
"""
import json
import pathlib
import subprocess
import sys
import textwrap


def transcript_entries(directory):
    for path in sorted(directory.rglob("*.jsonl")):
        for line in path.read_text(errors="replace").splitlines():
            try:
                yield json.loads(line)
            except ValueError:
                continue


def tool_calls(directory):
    """Every tool the model actually called, in order, by name."""
    names = []
    for entry in transcript_entries(directory):
        payload = entry.get("payload") or {}
        for item in payload.get("content") or []:
            if isinstance(item, dict) and item.get("type") == "tool_call":
                names.append(item.get("name"))
    return names


def usage(directory):
    hit = miss = out = 0
    for entry in transcript_entries(directory):
        used = ((entry.get("payload") or {}).get("usage")) or {}
        hit += used.get("prompt_cache_hit_tokens", 0)
        miss += used.get("prompt_cache_miss_tokens", 0)
        out += used.get("completion_tokens", 0)
    return hit, miss, out


def input_kilobytes(jobs, variant):
    """How much data this chore was handed. The denominator."""
    folder = jobs / variant / "data"
    if not folder.exists():
        return 0.0
    return sum(f.stat().st_size for f in folder.glob("*.jsonl")) / 1024


def heading(text):
    print(f"\n{text}\n{'-' * len(text)}")


def main():
    work = pathlib.Path(sys.argv[1])
    root = pathlib.Path(sys.argv[2])
    # Transcripts live OUTSIDE the workspace: the agent works in `work`, and a
    # record of what it just did, sitting in the folder it is searching, is
    # both a distraction and -- in a scored setting -- the answer key.
    transcripts = pathlib.Path(sys.argv[3])
    jobs = root / "experiments/dogfood/jobs/spend"
    germline = work / ".vivarium"
    variants = [d for d in sorted(transcripts.iterdir()) if d.is_dir()] if transcripts.exists() else []

    # ---------------------------------------------------------- what was kept
    heading("What it decided to keep")

    tools = sorted(p for p in (germline / "tools").glob("*/tool.json")) if (germline / "tools").exists() else []
    skills = sorted((germline / "skills").glob("*/SKILL.md")) if (germline / "skills").exists() else []
    memory = germline / "MEMORY.md"

    if not tools and not skills and not memory.exists():
        print("Nothing. Five tasks, and it judged none of them worth remembering.")
        print("That is a real outcome and the policy allows it: parsimony is the")
        print("rule, and most work leaves nothing that transfers. It is also the")
        print("result this demo would rather not show, so it is shown plainly.")

    for manifest in tools:
        spec = json.loads(manifest.read_text())
        print(f"a tool:  {spec['name']}")
        for line in textwrap.wrap(spec["description"].strip(), 66):
            print(f"         {line}")
        print(f"         in {manifest.parent.relative_to(work)}/")

    for skill in skills:
        print(f"a skill: {skill.parent.name}")
        print(f"         {skill.parent.relative_to(work)}/")

    if memory.exists():
        lines = [l.rstrip() for l in memory.read_text().splitlines() if l.strip()]
        if lines:
            print("notes:")
            for line in lines:
                print(f"         {line}")

    # ------------------------------------------------------- was it used again
    heading("Was any of it used again?")

    tool_names = {json.loads(m.read_text())["name"] for m in tools}
    reuse = {}
    for variant in variants:
        for name in tool_calls(variant):
            if name in tool_names:
                reuse.setdefault(name, []).append(variant.name)

    if reuse:
        for name, wheres in reuse.items():
            where = ", ".join(sorted(set(wheres)))
            print(f"{name} was called {len(wheres)} time(s), in {where}.")
            print("It did not exist when the run began: the organism wrote it")
            print("partway through, then reached for it instead of doing the work")
            print("by hand again.")
    elif tool_names:
        print("A tool was written and never called. On this run retention did not")
        print("pay -- the cost was paid and the saving never arrived.")

    # A note cannot be observed being "used" the way a tool call can. What CAN
    # be shown is that it is there: this asks vivarium what the NEXT task in
    # this directory would be handed, live, and costs nothing -- listing what
    # is loaded makes no model request.
    if memory.exists():
        loaded = subprocess.run(
            [str(root / "bin/vivarium"), "shell", "--cwd", str(work)],
            input="/memory\n/exit\n", capture_output=True, text=True, timeout=180)
        carried = "What I have learned" in loaded.stdout
        print(f"The note above is{'' if carried else ' NOT'} in what the next task here")
        print("would be given -- asked of vivarium just now, not inferred.")
        if carried:
            print(f"Every task after the one that wrote it ran with it in hand.")
            print("Unlike a tool call, a note's use cannot be counted directly:")
            print("it is in the prompt, and whether it saved thinking is not")
            print("visible in a transcript. The token column below is the only")
            print("honest evidence either way.")

    if not tool_names and not memory.exists():
        print("Nothing was kept, so there was nothing to use.")

    # ------------------------------------------------------------- what it cost
    heading("What it cost")

    # PER KILOBYTE OF INPUT, not per task. The five chores are deliberately not
    # the same size -- the largest has twice the data of the smallest -- so
    # comparing raw totals across them measures the data, not the learning. The
    # first draft of this report did exactly that and produced a confident
    # number that meant nothing.
    print(f"{'task':6} {'hit':>9} {'miss':>8} {'out':>7} {'tokens':>9} {'data':>7} {'tok/KB':>7}")
    rates = []
    for variant in variants:
        hit, miss, out = usage(variant)
        total = hit + miss + out
        kb = input_kilobytes(jobs, variant.name)
        rate = total / kb if kb else 0
        rates.append((variant.name, rate))
        print(f"{variant.name:6} {hit:9,} {miss:8,} {out:7,} {total:9,} "
              f"{kb:6.0f}K {rate:7.0f}")

    if len(rates) >= 4:
        early = sum(r for _, r in rates[:2]) / 2
        late = sum(r for _, r in rates[-2:]) / 2
        if early:
            change = (late - early) / early * 100
            direction = "cheaper" if change < 0 else "dearer"
            print(f"\nPer kilobyte of input, the last two tasks are "
                  f"{abs(change):.0f}% {direction} than the first two.")
            print("One task per point, so read that as a direction and not a")
            print("measurement -- two runs of this demo gave 3% and 46%. The")
            print("25-task study below is where the real number is.")

    spent = subprocess.run(
        [sys.executable, str(root / "experiments/kc6/budget.py"),
         "--limit", "99", "--off-peak", str(transcripts)],
        capture_output=True, text=True)
    if spent.returncode == 0 and spent.stdout.strip():
        print(spent.stdout.strip().splitlines()[-1].replace(" of $99.00", ""))

    heading("Where to look")
    print(f"the germline   {germline}")
    print(f"transcripts    {transcripts}")
    print("the measured study behind this: experiments/dogfood/RESULTS.md")
    print("\nThe honest summary of that study: retention happens, and what it")
    print("keeps is good, but across 25 mixed tasks it cost 8% more tokens than")
    print("it saved. It pays on mechanical work that recurs -- which is the")
    print("shape above -- and loses on work that is mostly judgement.")


if __name__ == "__main__":
    main()
