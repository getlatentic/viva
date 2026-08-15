from src.util.rates import VAT_RATE

def with_vat(amount):
    return round(amount * (1 + VAT_RATE), 2)
