from lib.accounts import balance, transfer, distribute, Overdraft

def check_balance_is_cents():
    accounts = {"a": 1000}
    assert balance(accounts, "a") == 1000
    assert isinstance(balance(accounts, "a"), int), "balance must be integer cents"
    assert balance(accounts, "missing") == 0

def check_transfer_moves_money():
    accounts = {"a": 1000, "b": 0}
    transfer(accounts, "a", "b", 250)
    assert accounts == {"a": 750, "b": 250}

def check_transfer_refuses_overdraft():
    accounts = {"a": 100, "b": 0}
    try:
        transfer(accounts, "a", "b", 101)
    except Overdraft:
        assert accounts == {"a": 100, "b": 0}, "a refused transfer must not move money"
        return
    raise AssertionError("transfer allowed an overdraft")

def check_distribute_conserves():
    accounts = {"a": 100, "x": 0, "y": 0, "z": 0}
    distribute(accounts, "a", ["x", "y", "z"], 100)
    assert sum(accounts.values()) == 100, accounts
    assert accounts["a"] == 0, accounts
