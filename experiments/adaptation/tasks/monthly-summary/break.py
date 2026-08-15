import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/report.py"
s = p.read_text()
old = """    summary = {}
    for entry in entries:
        summary[entry["month"]] = summary.get(entry["month"], 0) + signed(entry)
    return dict(sorted(summary.items()))"""
new = """    raise NotImplementedError"""
assert old in s
p.write_text(s.replace(old, new))
