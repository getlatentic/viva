import pathlib, re

MINT = re.compile(r"Created version (\d+) of ([^\s.]+)\.")

def mints(text):
    """(component, version) in order of appearance."""
    return [(name, int(number)) for number, name in MINT.findall(text)]

def latest(text):
    """component -> latest minted version."""
    table = {}
    for name, version in mints(text):
        table[name] = version
    return table

def compute(root):
    table = latest((root / "tool-output.txt").read_text())
    return f"version {table['reshape']}"


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
