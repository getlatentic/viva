"""Did memory carry a PROCEDURE, or an ANSWER?

This is the check that decides whether the experiment measured adaptation or
cheating, and it is written before the first accumulate run so that it cannot be
tuned to the result.

The rule: what an agent writes down after fixing task N may describe how to work
in this repository. It may not contain task M's fix. Each task's fix is exactly
the text that break.py removes, so that text is the answer key, and it is
extracted from break.py rather than restated here -- a copy would drift.

Reported, never silently tolerated:

  LEAK       an answer's distinctive code appears in something carried forward
  NARROW     a note names a task's defect specifically enough to skip finding it
             again. Not disqualifying on its own -- "amounts are integer cents"
             is a real project convention AND a hint at float-balance -- but it
             belongs in the write-up rather than in a footnote nobody reads.

  usage: check-answers.py <carried-directory> [...]
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


def main(directories):
    tasks = sorted(p.name for p in (HERE / "tasks").iterdir() if p.is_dir())
    common = STOPWORDS | project_vocabulary()
    answers = {task: distinctive(answer_of(task), common) for task in tasks}
    leaks = narrow = 0
    examined = 0

    for directory in directories:
        for path, text in carried_text(directory):
            examined += 1
            lowered = text.lower()
            for task in tasks:
                hits = sorted(f for f in answers[task] if f.lower() in lowered)
                if not hits:
                    continue
                code_like = [f for f in hits if len(f) > 24]
                if code_like:
                    leaks += 1
                    print(f"LEAK   {path}")
                    print(f"       carries {task}'s fix verbatim:")
                    for fragment in code_like[:3]:
                        print(f"         {fragment}")
                else:
                    narrow += 1
                    print(f"NARROW {path}")
                    print(f"       names {task}: {', '.join(hits[:5])}")

    print(f"\n{examined} carried file(s) examined, {len(tasks)} answers checked.")
    if leaks:
        print(f"{leaks} LEAK(S). The accumulate arm was handed answers, not procedure;"
              "\nany cost reduction it shows is worth nothing until this is fixed.")
    elif narrow:
        print(f"No verbatim answers. {narrow} note(s) name a task specifically enough"
              "\nto be worth quoting in the write-up.")
    else:
        print("No answers carried. What crossed between tasks was procedure.")
    return 1 if leaks else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [str(HERE)]))
