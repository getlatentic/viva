# E6 — production harness teardown

**Status: partial.** Codex read from source. Claude Code confirmed extractable but
not yet extracted.

Not a build — a read. Two production harnesses are on this machine and both are
legible. Everything E3 and E5 assume about how a request gets assembled should be
checked against them rather than guessed.

## Codex — done

Source vendored at `~/workspace/harness-test/vendor/codex`, commit f5a938ad60.
Findings on steering are in [E3](e3-subturn-steering.md). Still worth reading:

- how the turn loop decides a turn is over (`core/src/tasks/regular.rs`)
- what `TurnContext` freezes at turn start vs. reads per request — this is the exact
  question E3 turns on
- `hook_runtime.rs` — there is already an interception layer for pending input
- `code-mode` and `code-mode-runtime` crates: Codex appears to have its own
  answer to E5's single-tool question. Read before building harness B.

## Claude Code — extractable

```
/Users/dev/.local/share/claude/versions/2.1.210
Mach-O 64-bit executable arm64, 241 MB
strings -a → 611,581 lines, JS bundle in plaintext
```

Bun-compiled single-file executable, so the bundle sits in the binary uncompressed.
An earlier "zero strings" result was a wrong path (`~/.local/bin/2.1.210` does not
exist; the real one is under `~/.local/share/claude/versions/`).

Worth extracting for one question only: **what is fixed at turn start and what is
re-read per request.** That is the baseline E3 has to beat, and it is a fact about
these two programs, not something to reason about from first principles.

## Kills it

Nothing to kill — this is measurement. The only failure mode is spending time
reverse-engineering beyond the question, so keep it to request assembly and turn
boundaries.
