from src.stats import median, mean
cases = [([3, 1, 2], 2), ([1, 2, 3, 4], 2.5), ([5], 5), ([4, 1, 3, 2, 5], 3)]
bad = [f"median({v}) == {median(v)}, expected {e}" for v, e in cases if median(v) != e]
if mean([1, 2, 3]) != 2: bad.append("mean is broken")
print("\n".join(bad) or "OK")
raise SystemExit(1 if bad else 0)
