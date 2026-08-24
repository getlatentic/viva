# vivarium-tui

The full screen client for the viva daemon, in Rust, on ratatui.

```bash
sh tui/install.sh     # needs a Rust toolchain
viva                  # the launcher finds this binary and runs it
```

`viva` runs this client when it has a terminal. Piped or redirected it stays
the line client, which is the form that scripts and diffs. Where the binary is
absent, `viva tui` says so and runs the Lisp full screen client instead.

It starts the daemon if there is not one. `daemon start` is idempotent, so the
client makes sure rather than asking.

## The protocol is the daemon's

It speaks line-delimited JSON on `~/.vivarium/vivariumd.sock`, or on
`VIVARIUM_SOCKET`. `viva attach` and `viva live` speak the same protocol.

```
        engine (SBCL)
             |  JSON over a unix socket
    +--------+--------+
  attach    live    vivarium-tui
  (line)   (Lisp)     (Rust)
```

Two verbs exist for this client: `session.recorded` and `session.search`. Both
are facts about the workspace rather than about any interface, so they live in
the daemon. `session.inspect` answers notes, skills, tools and trust from one
instant.

## Keys

| key | action |
| --- | --- |
| type, Enter | send a prompt |
| `Ctrl-C` | stop the running turn; leave when there is none |
| `Tab` | next open tab |
| `Ctrl-N` `Ctrl-W` | start a session in a tab; close the tab |
| `Ctrl-R` | re-read the session list |
| `Ctrl-O` | show every line a tool printed, or the first three |
| `Ctrl-L` | what this session has learned: notes, skills, tools |
| `Ctrl-P` `Ctrl-F` | find any session, running or not, in every directory |
| `Up` from the prompt | move to the session list |
| `Up` `Down` `Enter` | walk the list, open one |
| `Esc` | back to the prompt |
| `PgUp` `PgDn` `Home` `End` | scroll; `End` follows again |
| click, wheel | tabs, `+`, sessions, scrolling |

Slash commands are a closed set. Press `/` to see it, narrowing as you type.
The client refuses an unknown one rather than sending it to the model.

| command | action |
| --- | --- |
| `/find` | find any session, running or not |
| `/sessions` `/sidebar` | show or hide the list of running sessions |
| `/new` `/close` | start a session in a new tab; close this tab |
| `/learned` `/knows` | what this session has retained |
| `/shell` `/!` | a line starting with `!` runs here; the model does not see it |
| `/refresh` `/help` | re-read the session list; list these |
| `/quit` `/exit` `/detach` `/q` | leave; the session keeps running |

The menu, the dispatcher and `/help` read one table, and a test walks it to
assert that every offered name and alias resolves.

## On screen

A tool call and its result are one block, three lines by default. The client
counts the lines it hides. Showing three of four hundred teaches a reader that
the command printed three. The mark carries the outcome: `·` running, `✔`
done, `✘` failed. A failed call keeps its reason.

The status line always carries the retention counts, including at zero.
`Ctrl-L` opens the detail and gives the scope of each item. A machine level
tool loads in every directory you open, and a project level one does not. The
panel lists anything that failed the trust check as refused.

A tab is a session you have open, like a browser tab. The sidebar finds a
session among all of them, and `+` starts one.

## Speed

The client lays out a frame once per change, not once per draw, and renders
only the visible rows.

| what | release build |
| --- | --- |
| one streamed token, 10 turns | 0.72 ms |
| one streamed token, 400 turns | 0.70 ms |
| one frame, 240 entries | 0.78 ms |
| one scroll step, 10 and 400 turns | 0.76 ms and 0.69 ms |
| idle for two seconds | 0 bytes |

Flat is the part that matters: the length of a conversation costs nothing to
draw. `cargo test --release` holds it to that.

## Checks

```bash
cargo test --manifest-path tui/Cargo.toml   # 85 tests: model and rendered frames
python3 tui/conformance.py                  # 33 terminal invariants, real daemon
python3 tui/wire_check.py                   # protocol contract, scripted daemon
```

`conformance.py` holds this client to the same invariants as the Lisp one: a
resize leaves one frame, paging stops at both ends, an idle client writes
nothing, and the client gives the terminal back. `wire_check.py` drives it from
a scripted daemon. A real daemon cannot produce a subagent, a completed task or
a dropped sequence number on demand, and asking it costs money.

Both build first. A unit test can pass against source while a check fails
against the binary beside it.
