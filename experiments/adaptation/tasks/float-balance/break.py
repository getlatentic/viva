import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/accounts.py"
s = p.read_text()
old = """def balance(accounts, name):
    return accounts.get(name, 0)"""
new = """def balance(accounts, name):
    return float(accounts.get(name, 0))"""
assert old in s
p.write_text(s.replace(old, new))
