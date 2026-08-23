import glob, json, pathlib, sys

total = 0.0
for path in sorted(glob.glob("accounts/*.jsonl")):
    tiers, entries = None, []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("kind") == "tiers":
            tiers = record.get("tiers") or []
            continue
        entries.append(record)

    if not tiers:
        continue

    def priced(units, used):
        """Tiered cost of UNITS given USED already billed."""
        cost, left, at = 0.0, units, used
        for tier in tiers:
            cap = tier.get("upto")
            room = float("inf") if cap is None else max(0, cap - at)
            take = min(left, room)
            cost += take * tier.get("rate", 0)
            at += take
            left -= take
            if left <= 0:
                break
        return cost

    used, charges, account = 0, {}, 0.0
    for record in entries:
        kind = record.get("kind")
        if kind == "charge":
            if record.get("status") == "pending":
                continue
            cost = priced(record.get("units", 0), used)
            used += record.get("units", 0)
            charges[record.get("id")] = {"cost": cost, "refunded": False}
            account += cost
        elif kind == "refund":
            target = charges.get(record.get("of"))
            if target and not target["refunded"]:
                target["refunded"] = True
                account -= target["cost"]
        elif kind == "credit":
            account -= record.get("amount", 0)
    total += account

want = int(total)
answer = pathlib.Path("answer.txt")
if not answer.exists():
    sys.exit("no answer.txt")
try:
    got = int(float(answer.read_text().split()[0]))
except (ValueError, IndexError):
    sys.exit("answer.txt is not a number")
if got != want:
    sys.exit(f"answer {got} != {want}")
print("ok")
