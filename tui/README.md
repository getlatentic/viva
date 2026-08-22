# vivarium-tui

A full-screen client for the vivarium daemon, in Rust, on ratatui.

```
sh tui/install.sh     # builds, and links it onto your PATH
vivarium-tui
```

It needs a daemon: `vivarium daemon start --background`.

The installer is separate from the Lisp one on purpose. This binary needs a
Rust toolchain, and somebody who only wants the engine and the line client
should not be told to install one.

## What it is, and what it is not

It speaks the **existing** socket protocol — line-delimited JSON on
`~/.vivarium/vivariumd.sock`, or `VIVARIUM_SOCKET`. It added nothing to that
protocol. If this program had needed the daemon changed, the boundary would
have been drawn in the wrong place.

`vivarium attach` and `vivarium live` are untouched. The line client pipes,
scripts and diffs, and that is why it exists.

```
        engine (SBCL)
             │  JSON over a unix socket
    ┌────────┼────────┐
  attach   live    vivarium-tui
  (line)   (Lisp)   (Rust)
```

## Keys

| | |
|---|---|
| type, Enter | send a prompt |
| Ctrl-C | stop the running turn; leave when there is none |
| Tab | next open tab |
| Ctrl-N | start a session and open it in a tab |
| Ctrl-W | close the tab — the session keeps running |
| Ctrl-R | re-read the session list |
| Ctrl-P / Ctrl-F | find any session, running or not |
| ↑ from the prompt | move to the session list |
| ↑ ↓ Enter in the list | walk it, open one |
| Esc | back to the prompt |
| PgUp PgDn Home End | scroll; End follows again |
| click, wheel | tabs, `+`, sessions, scrolling |

## Finding a session that is not running

The sidebar answers *what is running*. Most sessions are not: they are files
from yesterday. `Ctrl-P` opens a picker over every recorded session, narrowing
as you type, and Enter continues the one you choose — the daemon reloads it and
republishes the conversation, so it arrives with its history rather than as a
blank pane.

That needed two verbs the socket did not have — `session.recorded` and
`session.search`. Both are facts about the workspace rather than about any
interface, which is why they belong in the daemon: `vivarium sessions` had been
answering the same question from disk all along, and no client could ask it.

## Tabs are sessions, not workspaces

A tab is a session you have **open**, like a browser tab. The sidebar is for
finding a session among all of them; `+` starts one. Two tabs in the same
project are told apart by session id rather than both reading `alpha`.

## What ratatui bought, said honestly

Raw mode, the alternate screen, key and mouse decoding, resize events, screen
diffing, unicode width, borders, wrapping, scroll offsets. Every one of those
was hand-written in Lisp first and every one of them worked — what is gone is
not bugs but *ownership*. The diffing in particular is the same design as
`src/tui/screen.lisp`; that part was never novel.

What it did **not** buy is correctness in the layer above. The bugs this client
has already had — a trimming wrap that rendered the task tree flat, a stale
binary passing a check — are the same class the Lisp client had, and ratatui
does not touch them.

## Checks

```
cargo test --manifest-path tui/Cargo.toml   # model and rendered frames
python3 tui/conformance.py                  # terminal invariants, real daemon
python3 tui/wire_check.py                   # protocol contract, scripted daemon
```

`conformance.py` holds this client to the same invariants as the Lisp one:
resizes leave one frame, paging stops at both ends, an idle client is silent,
and the terminal is given back. `wire_check.py` drives it from a **scripted**
daemon, because the real one answers with whatever a model happens to say — it
cannot produce a subagent, a completed task or a dropped sequence number on
demand, and it costs money to ask.

Both build first. A fix once passed its unit tests while the check kept failing
against the binary from before it.
