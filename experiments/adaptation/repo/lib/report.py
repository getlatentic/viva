"""Reporting over a list of entries.

An entry is {"month": "2026-01", "cents": 1234, "kind": "charge"|"refund"}.
A refund's cents are stored positive and subtract from a total.
"""

from lib.money import format_cents


def signed(entry):
    return -entry["cents"] if entry["kind"] == "refund" else entry["cents"]


def total(entries):
    return sum(signed(entry) for entry in entries)


def format_amount(cents):
    """A human-readable amount, e.g. 1234 -> "$12.34", -50 -> "-$0.50"."""
    text = format_cents(abs(cents))
    return f"-${text}" if cents < 0 else f"${text}"


def monthly_summary(entries):
    """{month: total_cents}, months with no entries omitted, keys sorted."""
    summary = {}
    for entry in entries:
        summary[entry["month"]] = summary.get(entry["month"], 0) + signed(entry)
    return dict(sorted(summary.items()))
