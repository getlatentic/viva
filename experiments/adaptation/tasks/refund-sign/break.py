import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/report.py"
s = p.read_text()
old = '''    return -entry["cents"] if entry["kind"] == "refund" else entry["cents"]'''
new = '''    return entry["cents"]'''
assert old in s
p.write_text(s.replace(old, new))
