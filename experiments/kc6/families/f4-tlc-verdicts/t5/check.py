import pathlib, re

def verdict(text):
    if "is violated." in text or "Temporal properties were violated" in text:
        return "violates"
    if "No error has been found." in text:
        return "holds"
    return "error"

def invariant(text):
    found = re.search(r"Error: Invariant (\S+) is violated\.", text)
    return found.group(1) if found else "-"

def trace_length(text):
    return sum(1 for line in text.splitlines() if re.match(r"State \d+", line))

def compute(root):
    expected = {}
    for line in (root / "expectations.txt").read_text().splitlines():
        name, want = line.split()
        expected[name] = want
    lines, rotted = [], "-"
    for name in sorted(expected):
        text = (root / "logs" / (name + ".log")).read_text()
        actual = verdict(text)
        lines.append(f"{name} {actual}")
        if expected[name] == "violates" and actual == "holds":
            rotted = name
    lines.append(f"rotted {rotted}")
    return "\n".join(lines)


def main():
    import pathlib, sys
    expected = compute(pathlib.Path("."))
    answer_path = pathlib.Path("answer.txt")
    if not answer_path.exists():
        print("FAIL: no answer.txt"); return 1
    got = "\n".join(line.rstrip() for line in
                     answer_path.read_text().strip().splitlines())
    if got == expected:
        print("ok"); return 0
    print("FAIL: answer.txt does not match")
    print("--- expected ---"); print(expected)
    print("--- got ---"); print(got)
    return 1

if __name__ == "__main__":
    import sys; sys.exit(main())
