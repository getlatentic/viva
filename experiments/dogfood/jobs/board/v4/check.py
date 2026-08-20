import pathlib, sys
want = """Sprint 2 3
Sprint 3 2
Sprint 4 1
total 6"""
got = pathlib.Path("answer.txt").read_text().strip() if pathlib.Path("answer.txt").exists() else ""
if "\n".join(l.rstrip() for l in got.splitlines()) == want.strip():
    print("ok"); sys.exit(0)
print("FAIL: expected\n" + want.strip() + "\ngot\n" + got); sys.exit(1)
