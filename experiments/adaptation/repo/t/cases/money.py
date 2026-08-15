from lib.money import to_cents, format_cents, split_evenly

def check_to_cents():
    assert to_cents("12.34") == 1234
    assert to_cents("5") == 500
    assert to_cents("0.07") == 7

def check_format_cents():
    assert format_cents(1234) == "12.34"
    assert format_cents(7) == "0.07"
    assert format_cents(-50) == "-0.50"

def check_split_evenly_conserves():
    for cents, ways in [(100, 3), (10, 4), (7, 7), (1, 3), (0, 2)]:
        parts = split_evenly(cents, ways)
        assert len(parts) == ways, (cents, ways, parts)
        assert all(isinstance(part, int) for part in parts), (cents, ways, parts)
        assert sum(parts) == cents, f"split_evenly({cents}, {ways}) sums to {sum(parts)}"

def check_split_evenly_order():
    assert split_evenly(100, 3) == [34, 33, 33]
