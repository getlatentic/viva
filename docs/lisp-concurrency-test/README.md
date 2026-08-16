# Task-tree delivery record

Delivered externally; integrated 2026-08-16. `tasktree.lisp` now lives at
`src/daemon/tasktree.lisp` (the `=>` export it flagged is fixed in the kernel,
so its workaround import is removed), the specs at `spec/TaskTree*.tla|cfg`.
All four TLC configurations re-verified on this machine: safety and liveness
green, both witnesses producing their violations. The supervisor wiring the
table's effects to real threads is `src/daemon/supervisor.lisp`.

Integration found three wiring bugs on the mechanics side, none in the
delivered table: a positional/keyword confusion that silently dropped every
task completion (an OUTCOME is a keyword, so `collect until keyword` truncated
the message), a per-name effect shape misread that published refusals to a
task named :SPAWN-REFUSED, and a predicted-rather-than-minted spawn identity
that raced the supervisor -- three rapid spawns could hand a caller its
sibling's id. Identity is now minted by the owner and returned through a reply
mailbox riding the message.
