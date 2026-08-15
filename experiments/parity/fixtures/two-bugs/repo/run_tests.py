from src.cart import subtotal, total, item_count
items = [{"price": 10.0, "quantity": 2}, {"price": 5.0, "quantity": 3}]
bad = []
if subtotal(items) != 35.0: bad.append(f"subtotal == {subtotal(items)}, expected 35.0 (price times quantity)")
if round(total(items, 0.2), 2) != 42.0: bad.append(f"total == {total(items, 0.2)}, expected 42.0 (subtotal plus tax)")
if item_count(items) != 5: bad.append(f"item_count == {item_count(items)}, expected 5 (total quantity)")
print("\n".join(bad) or "OK")
raise SystemExit(1 if bad else 0)
