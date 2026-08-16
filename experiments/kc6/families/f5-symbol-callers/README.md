# Family 5 (held out): a symbol's definition and callers

The friction: who actually calls this, across packages — where plain grep
over-matches same-named symbols, misses local-nickname references, and counts
comments. The receipt: the `call-component`-has-no-caller finding took three
searches, and task four here is that finding in miniature.

The check is the derivation: it builds the packages, re-reads every file
under its own package context, and counts operator-position occurrences with
QUOTE and FUNCTION subtrees excluded. Reference answers are hand-computed;
the gate's pass-after leg reconciles the two derivations.

Held out (amendment 11): authored after the scored four were frozen, excluded
from pilots, included in the battery and the primary sign test.
