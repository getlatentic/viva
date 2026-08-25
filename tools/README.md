# Checks that need a real terminal

Three things this project cannot test from its own suite, because a test run
has no controlling terminal and an in-process assertion cannot see what a
terminal actually received.

| script | answers |
|---|---|
| `pty-size-check.sh` | does `terminal-size` read the **real** size? |
| `pty-live-check.sh` | does `viva live` draw, type, send, scroll and hand the terminal back? |
| `pty-conformance.sh` | do the terminal **invariants** hold — erase, resize, selection, paging? |

Run them after any change to `src/tui/` or `src/cli/live.lisp`:

```
./tools/pty-size-check.sh && ./tools/pty-live-check.sh && ./tools/pty-conformance.sh
```

## Why these are separate from the suite

`viva test` has no tty, so `terminal-size` returns its fallback and a
broken `ioctl` is indistinguishable from a working one. Worse, an in-process
test can assert what the program *meant* to draw and never what the terminal
*received* — and the gap between those two is where every bug in this TUI has
lived.

## The harness is a model, and it has been wrong

`pty-conformance.sh` documents exactly which escape sequences its terminal
model implements and which it knowingly ignores. That list is not decoration.
Three separate faults in these harnesses have hidden or invented failures:

- the replay ignored `ESC[2J`, so it accumulated every frame ever drawn and
  reported corruption the terminal never had;
- it decoded byte by byte, so multi-byte box characters became replacement
  marks and a correct frame looked broken;
- it had no pending buffer, so a sequence split across two reads had its tail
  painted onto the screen as literal text.

Each one reads exactly like a rendering bug. **A model that is dirtier than
reality cannot tell you reality is clean**, and one that is cleaner cannot tell
you it is dirty — the conformance model deliberately keeps content across a
resize for that second reason, because clearing there would pass whether or not
the program under test ever cleared the terminal itself.

If the TUI emits a sequence the model does not know, the conformance run fails
rather than ignoring it. That is the check that stops this list from growing
silently.

## Proving a check can fail

Every one of these has been mutation-tested: the fix is removed, the check is
run, and it must fail. Removing the screen's invalidation produces

```
FAIL  34x100: 2 input prompts after resize
```

which is the original reported bug — two frames on screen at once.
