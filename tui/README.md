# vivarium-tui

A full-screen client for the vivarium daemon, in Rust, on ratatui.

```
sh tui/install.sh     # builds it
vivarium
```

Bare `vivarium` opens it. Typing the name of the thing should open the thing —
`vivarium tui` asks a person to choose between two clients before they have
seen either. `vivarium tui` and `vivarium live` still name it explicitly.

**Only when there is a terminal.** Piped or redirected, `vivarium` stays the
line client it has always been: that is the form that scripts and diffs, and a
full-screen program in a pipe draws into a buffer nobody reads.

`vivarium` is the only command. The launcher finds this binary in the tree and
runs it — there is no second name to install, find, keep in step or explain,
and the person typing it does not care which language drew the frame. `live` is
the older name for the same thing.

The routing happens in the shell launcher, **before** SBCL loads: reaching the
binary through the Lisp CLI worked and cost a minute of quickload first, to
hand the terminal to a program that starts in milliseconds. It is 18ms now.

It starts the daemon if there is not one — `daemon start` is idempotent, so the
client makes sure rather than telling you about our architecture.

Where the Rust binary has not been built, `vivarium tui` says so and runs the
Lisp full-screen client instead. A checkout with no cargo must still have one.

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
| Ctrl-L | what this session has learned — notes, skills, tools |
| Ctrl-P / Ctrl-F | find any session, running or not |
| ↑ from the prompt | move to the session list |
| ↑ ↓ Enter in the list | walk it, open one |
| Esc | back to the prompt |
| PgUp PgDn Home End | scroll; End follows again |
| click, wheel | tabs, `+`, sessions, scrolling |

## What it has learned is on screen

The status line carries the counts always — `learned 3 notes · 2 skills · 1
tool` — including at zero. A fresh project retaining nothing is exactly when
somebody most needs to learn that the harness retains at all; hiding the row
until it is non-empty hides the feature from everyone who has not used it yet.

`Ctrl-L` opens the detail: each retained thing, its scope, and what it is for.
Scope matters and is shown, because a machine-level tool loads in **every**
project you open and a project-level one does not.

Anything refused for trust is listed **as refused**, not folded in. "There is a
tool here" and "the agent can call it" are different facts, and a client that
merges them makes an untrusted project look equipped.

It is one request — `session.inspect` answers notes, skills, tools and trust
from a single instant. Four questions about one moment answered by four round
trips would be four different moments.

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

## Slash commands are never prompts

| | |
|---|---|
| `/quit` `/exit` `/detach` | leave; the session keeps running |
| `/new` `/close` | a session in a new tab; close this tab |
| `/find [text]` | find any session, running or not |
| `/refresh` `/help` | re-read the session list; list these |

**Press `/` and the list appears**, narrowing as you type, with what each one
does beside it. A closed set nobody can see is barely better than no set: you
would have to already know the words to find out the words exist. Tab
completes, Enter runs, Esc dismisses, and the menu leaves once you start typing
an argument — a menu over the top of `/find vite` is in the way rather than in
help.

The menu, the dispatcher and `/help` all read **one table**. Three copies is
three chances for the menu to offer something the dispatcher refuses, and since
refusing an unknown command is the whole feature, that would be the feature
attacking itself. A test walks the table and asserts every offered name and
alias resolves.

**A closed set, and an unknown one is refused rather than forwarded.** The
first version had no slash handling at all, so `/quit` went to the model as a
prompt — and the model politely said goodbye while the client stayed exactly
where it was. That is a paid request answered by a guess at what somebody
meant. A slash in the *middle* of a line is still a line: `read src/main.rs`
goes to the model.

## Tabs are sessions, not workspaces

A tab is a session you have **open**, like a browser tab. The sidebar is for
finding a session among all of them; `+` starts one. Two tabs in the same
project are told apart by session id rather than both reading `alpha`.

## Speed

A frame is laid out once per change, not once per draw, and only the visible
rows are rendered. Before that, every keypress re-wrapped the whole
conversation — twice, because asking a paragraph how tall it is wraps it as
well — so a long session was slower than a short one at exactly the moment
somebody noticed.

| | before | after |
|---|---|---|
| 120 turns, one frame | 26 ms | 0.49 ms |
| 10 turns | 2.5 ms | 0.48 ms |
| 200 turns | 43 ms | 0.49 ms |

Flat, which is the part that matters: the length of a conversation no longer
costs anything to draw. And the loop draws only when something changed, so an
idle client writes **0 bytes**. `cargo test --release` holds both to numbers.

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
