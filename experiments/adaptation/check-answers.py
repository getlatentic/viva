"""Did memory carry a PROCEDURE, or an ANSWER?

This is the check that decides whether the experiment measured adaptation or
cheating, and it is written before the first accumulate run so that it cannot be
tuned to the result.

The rule: what an agent writes down after fixing task N may describe how to work
in this repository. It may not contain task M's fix. Each task's fix is exactly
the text that break.py removes, so that text is the answer key, and it is
extracted from break.py rather than restated here -- a copy would drift.

POSITION IS WHAT DECIDES IT. Memory is written after a task and read before the
ones that follow, so a note describing a task ALREADY DONE is journaling and
harmless, while the same note describing a task STILL TO COME is an answer key.
Only the second is contamination, and only the second is counted.

  AHEAD      something carried forward describes a task later in the order
  BEHIND     it describes a task already finished. Reported, not counted.

The first version of this checked only for verbatim code and passed a memory
file that said "the fix is in transfer(): compute source_balance first, raise
Overdraft if cents > source_balance, then mutate". That is the answer in prose,
and a >24-character literal-line test cannot see it. Paraphrase is caught by
identifiers instead: an agent cannot describe a fix usefully without naming what
it touches, so the names ARE the payload.

  usage: check-answers.py --order t1,t2,... <carried-directory> [...]
"""
import pathlib, re, sys

HERE = pathlib.Path(__file__).parent

# Words too ordinary to mean anything on their own: English filler, plus every
# name the project itself defines. A note saying "balance returns integer cents"
# is a description of the public API and belongs in memory; it is not the
# overdraft fix. Derived from the repository rather than hand-listed, so the
# exclusion cannot be quietly widened to make a leak disappear -- and the
# whole-line check below still catches a note that reproduces a function BODY.
STOPWORDS = {"return", "self", "else", "the", "and", "not", "with", "from", "this",
             "that", "when", "which", "value", "values", "index", "number", "using"}


def project_vocabulary():
    names = set()
    for path in (HERE / "repo" / "lib").glob("*.py"):
        for match in re.finditer(r"^\s*(?:def|class)\s+([A-Za-z_][A-Za-z_0-9]*)",
                                 path.read_text(), re.M):
            names.add(match.group(1))
        for match in re.finditer(r'"""(.*?)"""', path.read_text(), re.S):
            names.update(re.findall(r"[A-Za-z_][A-Za-z_0-9]{4,}", match.group(1)))
    return names


def answer_of(task):
    """The code break.py removes: the fix, verbatim."""
    source = (HERE / "tasks" / task / "break.py").read_text()
    match = re.search(r'^old = ("""|\'\'\')(.*?)\1', source, re.S | re.M)
    return match.group(2) if match else ""


def distinctive(answer, common):
    """Fragments of the answer specific enough that seeing one is seeing the fix."""
    fragments = set()
    for token in re.findall(r"[A-Za-z_][A-Za-z_0-9]*", answer):
        if len(token) > 4 and token not in common:
            fragments.add(token)
    for line in answer.splitlines():
        stripped = line.strip()
        if len(stripped) > 24:
            fragments.add(stripped)
    return fragments


def carried_text(directory):
    """Everything that crosses from one task to the next: memory and skills."""
    root = pathlib.Path(directory)
    pieces = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix in (".md", ".lisp", ".txt"):
            pieces.append((path, path.read_text(errors="replace")))
    return pieces


def notes_in_order(text):
    """Memory entries in the order they were written: one per leading '- '."""
    entries, current = [], None
    for line in text.splitlines():
        if line.startswith("- "):
            if current is not None:
                entries.append(current)
            current = line[2:]
        elif current is not None:
            current += " " + line
    if current is not None:
        entries.append(current)
    return entries


def main(argv):
    order = None
    if argv and argv[0] == "--order":
        order = argv[1].split(",")
        argv = argv[2:]
    tasks = sorted(p.name for p in (HERE / "tasks").iterdir() if p.is_dir())
    order = order or tasks
    common = STOPWORDS | project_vocabulary()
    answers = {task: distinctive(answer_of(task), common) for task in tasks}
    ahead = behind = examined = 0

    for directory in argv:
        for path, text in carried_text(directory):
            examined += 1
            # Note N is written after task N and read by task N+1 onward.
            for position, note in enumerate(notes_in_order(text)):
                lowered = note.lower()
                for task in tasks:
                    hits = sorted(f for f in answers[task] if f.lower() in lowered)
                    if not hits:
                        continue
                    when = order.index(task) if task in order else len(order)
                    if when > position:
                        ahead += 1
                        print(f"AHEAD  {path}")
                        print(f"       note {position + 1} describes {task}, which is "
                              f"task {when + 1} and had not been done yet")
                        print(f"       {', '.join(hits[:6])}")
                    else:
                        behind += 1

    print(f"\n{examined} carried file(s), {behind} note(s) describing finished work, "
          f"{ahead} describing work still to come.")
    if ahead:
        print(f"\n{ahead} AHEAD. Memory carried answers into tasks that had not been"
              "\nattempted. Any cost reduction is partly leakage and cannot be reported"
              "\nas adaptation until the two are separated.")
    else:
        print("\nNo note described a task before it was attempted. What crossed"
              "\nbetween tasks was procedure and finished work.")
    return 1 if ahead else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [str(HERE)]))
