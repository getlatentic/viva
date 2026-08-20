import pathlib, sys
want = """Sprint 2 1
Sprint 3 5
total 6"""
got = pathlib.Path("answer.txt").read_text().strip() if pathlib.Path("answer.txt").exists() else ""
if "\n".join(l.rstrip() for l in got.splitlines()) == want.strip():
    print("ok"); sys.exit(0)
print("FAIL: expected\n" + want.strip() + "\ngot\n" + got); sys.exit(1)
