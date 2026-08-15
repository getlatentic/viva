"""DEPRECATED. The pre-cents money module, kept only so old exports still parse.

Nothing in lib/ imports this. It works in floats and rounds with round(), which
is exactly why it was replaced.
"""

def split_evenly(amount, ways):
    return [round(amount / ways, 2)] * ways

def format_cents(amount):
    return "%.2f" % amount

def to_cents(text):
    return float(text)
