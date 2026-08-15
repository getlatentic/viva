import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "lib/report.py"
s = p.read_text()
old = '''    text = format_cents(abs(cents))
    return f"-${text}" if cents < 0 else f"${text}"'''
new = """    raise NotImplementedError"""
assert old in s
p.write_text(s.replace(old, new))
