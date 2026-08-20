import pathlib, sys
want = """passed 1250
failed 3
failing a registry tool cannot read credentials"""
got = pathlib.Path("answer.txt").read_text().strip() if pathlib.Path("answer.txt").exists() else ""
if "\n".join(l.rstrip() for l in got.splitlines()) == want.strip():
    print("ok"); sys.exit(0)
print("FAIL: expected\n" + want.strip() + "\ngot\n" + got); sys.exit(1)
