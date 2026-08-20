import pathlib, sys
expected = pathlib.Path("solution_expected.txt").read_text().strip() if pathlib.Path("solution_expected.txt").exists() else None
want = """hit 160384
miss 35974
out 11584"""
got = pathlib.Path("answer.txt").read_text().strip() if pathlib.Path("answer.txt").exists() else ""
if "\n".join(l.strip() for l in got.splitlines()) == want:
    print("ok"); sys.exit(0)
print("FAIL: expected\n" + want + "\ngot\n" + got); sys.exit(1)
