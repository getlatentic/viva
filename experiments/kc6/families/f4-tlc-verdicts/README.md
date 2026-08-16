# Family 4: TLC output to holds-or-violates

The friction: a TLC run's verdict is buried in verbose output, and this
project needed a config-to-expectation table before thirteen configs could be
one command (`spec/verify.sh`) — including the rule that a WITNESS that stops
violating is evidence rot, not a pass. The logs here are authored in the
exact shapes this session's real runs produced: clean holds, invariant
violations with counterexample traces, temporal violations, parse errors,
and a deadlock.

Reference answers are hand-written from the authored logs; each check parses
independently by the PROMPT's rules; the gate's pass-after leg reconciles the
two derivations.
