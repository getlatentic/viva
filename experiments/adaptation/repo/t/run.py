"""Collect every check_* function from t/cases and run it.

Run from the repository root: the case modules import lib.* by package name.
"""
import importlib, pkgutil, sys, traceback

import t.cases


def cases(only=None):
    found = []
    for module in pkgutil.iter_modules(t.cases.__path__):
        loaded = importlib.import_module(f"t.cases.{module.name}")
        for name in sorted(dir(loaded)):
            if name.startswith("check_") and (only is None or only in f"{module.name}.{name}"):
                found.append((f"{module.name}.{name}", getattr(loaded, name)))
    return found


def main(argv):
    only = argv[0] if argv else None
    failures = []
    selected = cases(only)
    if not selected:
        print(f"no cases match {only!r}")
        return 2
    for name, case in selected:
        try:
            case()
        except Exception:
            failures.append((name, traceback.format_exc(limit=2)))
    for name, detail in failures:
        print(f"FAIL {name}\n{detail}")
    print(f"{len(selected) - len(failures)}/{len(selected)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
