# What I have learned working here

- The test suite is `./check`, run from the repository root; it is a wrapper around `python3 -m t.run` and takes a case-name filter, so `./check money` runs one file's cases.
- Every amount in this project is an integer number of cents. `lib/money.py` holds the helpers for converting and formatting them. Nothing here uses floats for money.
- `vendor/` is a stale copy kept only so old imports parse. Nothing under `lib/` imports it, so editing anything in there changes no behaviour and no test.
- The code lives in `lib/`, and the cases that exercise it live in `t/cases/`, one file per module.
