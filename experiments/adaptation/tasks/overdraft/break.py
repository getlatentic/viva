import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/accounts.py"
s = p.read_text()
old = """    if balance(accounts, source) < cents:
        raise Overdraft(f"{source} has {balance(accounts, source)}, needs {cents}")
"""
assert old in s
p.write_text(s.replace(old, ""))
