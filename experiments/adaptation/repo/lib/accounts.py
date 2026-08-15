"""Accounts, keyed by name, holding integer cents."""

from lib.money import split_evenly


class Overdraft(Exception):
    pass


def balance(accounts, name):
    return accounts.get(name, 0)


def transfer(accounts, source, destination, cents):
    if cents < 0:
        raise ValueError("cannot transfer a negative amount")
    if balance(accounts, source) < cents:
        raise Overdraft(f"{source} has {balance(accounts, source)}, needs {cents}")
    accounts[source] = balance(accounts, source) - cents
    accounts[destination] = balance(accounts, destination) + cents
    return accounts


def distribute(accounts, source, destinations, cents):
    """Move CENTS from SOURCE, split as evenly as money allows."""
    for name, part in zip(destinations, split_evenly(cents, len(destinations))):
        transfer(accounts, source, name, part)
    return accounts
