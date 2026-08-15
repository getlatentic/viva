from lib.report import total, format_amount, monthly_summary

ENTRIES = [
    {"month": "2026-01", "cents": 1000, "kind": "charge"},
    {"month": "2026-01", "cents": 250, "kind": "refund"},
    {"month": "2026-02", "cents": 400, "kind": "charge"},
    {"month": "2026-02", "cents": 400, "kind": "refund"},
]

def check_total_nets_refunds():
    assert total(ENTRIES) == 750, total(ENTRIES)

def check_format_amount():
    assert format_amount(1234) == "$12.34"
    assert format_amount(-50) == "-$0.50"
    assert format_amount(0) == "$0.00"

def check_monthly_summary():
    assert monthly_summary(ENTRIES) == {"2026-01": 750, "2026-02": 0}

def check_monthly_summary_is_sorted():
    entries = [{"month": "2026-03", "cents": 1, "kind": "charge"},
               {"month": "2026-01", "cents": 2, "kind": "charge"}]
    assert list(monthly_summary(entries)) == ["2026-01", "2026-03"]
