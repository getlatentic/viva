import ast, glob, json, os, pathlib, sys

TYPES = {int: "integer", str: "string", bool: "boolean", float: "number"}


def signature(path):
    tree = ast.parse(open(path).read())
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "run":
            names = [a.arg for a in node.args.args]
            defaults = node.args.defaults
            required = names[: len(names) - len(defaults)]
            typed = {}
            for name, default in zip(names[len(names) - len(defaults):], defaults):
                if isinstance(default, ast.Constant):
                    typed[name] = TYPES.get(type(default.value))
            return names, required, typed
    return [], [], {}


wrong = 0
for directory in sorted(glob.glob("components/*")):
    declared = json.load(open(os.path.join(directory, "declared.json")))
    parameters = declared.get("parameters") or []
    names, required, typed = signature(os.path.join(directory, "run.py"))
    if not parameters:
        continue
    declared_names = [p["name"] for p in parameters]
    bad = any(n not in names for n in declared_names)
    bad = bad or any(r not in declared_names for r in required)
    for p in parameters:
        want = typed.get(p["name"])
        if want and p.get("type") != want:
            bad = True
    if bad:
        wrong += 1

answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(answer.read_text().split()[0])
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
if got != wrong:
    sys.exit(f"answer {got} != {wrong}")
print("ok")
