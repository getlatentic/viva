from src.billing.invoice import with_vat as invoice_vat
from src.billing.quote import with_vat as quote_vat
bad = []
if invoice_vat(100) != 120.0: bad.append(f"invoice_vat(100) == {invoice_vat(100)}, expected 120.0")
if quote_vat(100) != 120.0: bad.append(f"quote_vat(100) == {quote_vat(100)}, expected 120.0")
import src.billing.quote as q, inspect
if "1.175" in inspect.getsource(q): bad.append("quote.py still hardcodes a VAT rate instead of using VAT_RATE")
print("\n".join(bad) or "OK")
raise SystemExit(1 if bad else 0)
