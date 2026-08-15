import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/money.py"
s = p.read_text()
old = """    base, remainder = divmod(cents, ways)
    return [base + (1 if index < remainder else 0) for index in range(ways)]"""
new = """    return [cents // ways for _ in range(ways)]"""
assert old in s
p.write_text(s.replace(old, new))
