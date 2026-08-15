def subtotal(items):
    return sum(item["price"] for item in items)

def total(items, tax_rate):
    return subtotal(items) * tax_rate

def item_count(items):
    return len(items)
