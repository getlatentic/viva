"""Money. Every amount in this project is an integer number of cents.

Nothing here returns or accepts a float. Rounding is decided once, at the point
of splitting, and never left to binary floating point.
"""

def to_cents(text):
    whole, _, fraction = text.partition(".")
    fraction = (fraction + "00")[:2]
    return int(whole) * 100 + int(fraction)

def format_cents(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}{cents // 100}.{cents % 100:02d}"

def split_evenly(cents, ways):
    """Split CENTS into WAYS parts that sum back to CENTS.

    The remainder goes to the earliest parts, one cent each, so no money is
    created or destroyed by the split.
    """
    if ways < 1:
        raise ValueError("ways must be at least 1")
    base, remainder = divmod(cents, ways)
    return [base + (1 if index < remainder else 0) for index in range(ways)]
