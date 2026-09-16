# viva-tui

The full screen client for the viva daemon, in Rust, on ratatui.

```bash
sh tui/install.sh     # needs a Rust toolchain
viva                  # the launcher finds this binary and runs it
```

`viva` runs this client when it has a terminal, and the line client when a
pipe or a redirect takes its output. Where the binary is absent, `viva` says
how to build it and points to `viva attach`. It starts the daemon if there is
not one.

It speaks line-delimited JSON on `~/.viva/viva.sock`, or on `VIVA_SOCKET`.
`viva attach` and `viva live` speak the same protocol. This client calls
`session.recorded` for a transcript, `session.search` for the finder, and
`session.inspect` for notes, skills, tools and trust from one instant.

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
| `Ctrl-B` | show or hide the sessions column |
| `Up` from the prompt | read back through the conversation |
| `Up` `Down` | scroll the conversation; `Down` past the newest line returns to the prompt |
| `Left` `Right` | cross to the sessions column and back |
| `Up` `Down` `Enter` in the column | walk the list, open one |
| `Backspace` `Delete` in the column, `Ctrl-D` in the picker | delete a session, after asking |
| `Esc` | back to the prompt |
| `PgUp` `PgDn` `Home` `End` | a page, the top, the newest, from anywhere |
| click, wheel | tabs, `+`, sessions, scrolling the pane under the pointer |

Slash commands are a closed set. Press `/` to see it, narrowing as you type.
The client refuses an unknown one rather than sending it to the model.

| command | action |
| --- | --- |
| `/find` | find any session, running or not |
| `/sidebar` | show or hide the sessions column |
| `/new` `/close` | start a session in a new tab; close this tab |
| `/stop` `/cancel` | stop this session's turn, and any loop it set up |
| `/models` `/model` | switch this session's model; a digit takes that one |
| `/learned` `/knows` | what this session has retained |
| `/shell` `/!` | a line starting with `!` runs here; the model does not see it |
| `/refresh` `/help` | re-read the session list; list these |
| `/quit` `/exit` `/detach` `/q` | leave; the session keeps running |

## On screen

A tool call and its result are one block, three lines by default, with a count
of the lines it hides. The mark carries the outcome: `·` running, `✔` done,
`✘` failed. A failed call keeps its reason.

The status line carries the retention counts, including at zero. `Ctrl-L`
opens the detail, gives the scope of each item, and lists anything that failed
the trust check as refused. A tab is a session you have open, like a browser
tab. The sidebar finds a session among all of them, and `+` starts one.

The client lays out a frame once per change, not once per draw, and renders
only the visible rows. Benches hold a streamed token, a scroll step and a tab
switch inside one frame at 60fps, in a conversation of 400 turns. A token and
a scroll step cost the same there as at 10.

## Checks

```bash
cargo test --manifest-path tui/Cargo.toml   # 168 tests: the model, and the frames it draws
python3 tui/conformance.py                  # 46 terminal invariants, real daemon
python3 tui/wire_check.py                   # protocol contract, scripted daemon
```

`conformance.py` holds this client to the same invariants as the Lisp one: a
resize leaves one frame, paging stops at both ends, an idle client writes
nothing, and the client gives the terminal back. `wire_check.py` drives it from
a scripted daemon, because a real one cannot produce a subagent, a completed
task or a dropped sequence number on demand.

Both build first. A unit test can pass against source while a check fails
against the binary beside it.
