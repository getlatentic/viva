# viva

viva is an experimental agent harness for persistent, self-extending agents.
Sessions persist beyond the terminal. Agents extend their environment in two
different ways. One is temporary: they compile new behaviour into the running
Common Lisp image. The other is durable: they write notes, skills and tools
into the workspace for later sessions to reuse.

Most harnesses treat a run as disposable. The process starts and the model
works with the tools it was given. When the run ends, whatever was useful
survives only as files or conversation history.

The experiment is whether agents benefit from turning the work they do into
capabilities they can reuse. The alternative is solving the same class of
problem from a fixed harness every time. The answer is not assumed. Each
experiment fixes its comparison and its kill criterion before it runs, and the
repository keeps the negative results beside the positive ones.

![Sessions on the left, the transcript on the right, each tool call a titled rule with its result beneath it](docs/viva.png)

## Install

```bash
# macOS on Apple silicon or Linux on x86_64, WSL included; run again to upgrade
curl -fsSL https://raw.githubusercontent.com/getlatentic/viva/main/get.sh | sh
```

```bash
# anywhere else, from source
brew install sbcl                    # or: apt install sbcl
curl -fsSL https://sh.rustup.rs | sh # Rust, for the full-screen client
git clone https://github.com/getlatentic/viva && cd viva
sh install.sh && sh tui/install.sh   # Quicklisp, viva on PATH, the client
```

```bash
mkdir -p ~/.viva && echo '{ "deepseek": { "apiKey": "sk-..." } }' > ~/.viva/auth.json
chmod 600 ~/.viva/auth.json
viva                                 # opens this directory's session
```

## Use

| command | what it does |
| --- | --- |
| `viva` | open this directory's session in the full-screen client, or start one |
| `viva attach [SESSION]` | the same sessions as plain lines, for pipes and scripts |
| `viva do "PROMPT"` | one prompt and its answer, with no session |
| `viva sessions --search TEXT` | find a recorded conversation; `--all` looks in every project |
| `viva learned` | the notes, skills and tools this project has kept |
| `viva config` | every setting, its value, and the file that set it |
| `viva trust` | let this project's own extensions and tools run |
| `viva mcp` | serve this project's tools over MCP |
| `viva daemon status` | the process that sessions run in |

Sessions run in a daemon. Closing the client leaves a turn running, and `viva`
rejoins the session later. If the daemon stops, the session comes back under
the same id, but the turn that was running is lost. `viva help` lists every
flag, and [tui/README.md](tui/README.md) lists the full-screen client's keys.

## Capabilities and extensions

An agent keeps what it learns as files, and you can write the same files by
hand. Each kind works from a project's `.viva/` and from `~/.viva/` for every
project. For skills and tools, the project's copy wins on a name clash.

| kind | file | what the model gets |
| --- | --- | --- |
| note | `.viva/MEMORY.md` | the text, in its prompt |
| skill | `.viva/skills/<name>/SKILL.md` | the name and description; it reads the body when one matches |
| tool | `.viva/tools/<name>/tool.json` | a tool it can call |
| extension | `.viva/extensions/<name>.lisp` | what the file registers: tools, hooks, commands, providers |
| capability | `~/.viva/capabilities/` | functions it compiled, when `self-modify` is on |

A project's own tools and extensions run only after `viva trust` in that
project. Until then, `viva mcp` there lists no tools.

### Tools

A tool is a directory with a manifest and a script in any language. The
arguments arrive as JSON on standard input, and what the script prints is the
result. `.viva/tools/word_count/tool.json`:

```json
{
  "name": "word_count",
  "description": "Count the words in a piece of text.",
  "version": 1,
  "exec": ["python3", "run.py"],
  "parameters": [
    {"name": "text", "type": "string", "description": "the text to count", "required": true}
  ]
}
```

`.viva/tools/word_count/run.py`:

```python
import json, sys
print(len(json.load(sys.stdin)["text"].split()))
```

After `viva trust`, `viva learned` lists it, the agent can call it, and
`viva mcp` serves it to any MCP client. Over MCP, `{"text": "one two three"}`
returns `3`. [docs/tool-registry.md](docs/tool-registry.md) has the full format.

### Extensions

An extension is a Lisp file that registers what it adds when it loads. This one
adds a tool:

```lisp
(in-package #:viva.extension)

(defextension "ping"
  :description "A tool that answers pong."
  (register-tool
   (make-instance 'viva.tool:function-tool
                  :name "ping"
                  :description "Answer pong."
                  :parameters '()
                  :body (lambda (arguments context)
                          (declare (ignore arguments context))
                          "pong"))))
```

`(on :before-request #'function)` adds a hook instead. A `:tool-call` hook can
refuse a call before it runs. `viva do --extension DIR` loads a directory of
extensions for one run. Five worked ones ship in
[examples/extensions/](examples/extensions): curator, guard, recall, skillsmith
and trace.

### Capabilities

Two behaviours stay off until the `capabilities` setting names them:

| name | what the agent can do |
| --- | --- |
| `self-modify` | compile a function into the running process, call it, keep it across restarts, and take it back |
| `loop` | send itself the next prompt, so work carries on past a turn; `/stop` or ctrl-c ends it |

```bash
echo 'capabilities = self-modify,loop' >> ~/.viva/config   # sessions the daemon starts
viva do --capabilities on,loop "PROMPT"                     # one run
```

A project can ask for them in its own `.viva/config` once it is trusted. An
entry can also be the path of a Lisp file you wrote.

## Configure

Settings are `key = value` lines. A project's `.viva/config` overrides
`~/.viva/config`, the environment overrides both, and a flag overrides all
three. `viva config` shows which one decided each value:

```text
setting        value                from
model          deepseek             ~/.viva/config
limit          -                    the built-in default
retain         -                    the built-in default
capabilities   self-modify,loop     ~/.viva/config
```

Keys never go in a config file, because people commit a project's config. They
go in `~/.viva/auth.json`, one entry per provider:

| provider | entry |
| --- | --- |
| `deepseek`, `openai`, `openrouter`, `bedrock` | `{ "apiKey": "..." }` |
| `watsonx` | `{ "apiKey": "...", "models": ["<your gateway's alias>"] }`, plus `endpoint` for your region |
| `local` (llama.cpp on port 8099), `ollama` (port 11434) | `{}`, or `VIVA_LOCAL_ENDPOINT` or `OLLAMA_ENDPOINT` in the environment; they need no key |

An entry's `endpoint` reaches another deployment, and `models` replaces the
list it offers. Every model answers to `provider/id`, as in
`viva do --model deepseek/deepseek-v4-flash`. For watsonx, viva mints IBM's
access token from the key it holds. [examples/config/](examples/config) has a
`config` and an `auth.json` to copy.

## Develop

```text
bin/viva          the launcher
src/core/         messages, tools, the agent loop
src/workspace/    skills, registry, memory, extensions, sessions
src/daemon/       sessions as actors, the socket, the task tree
tui/              the Rust full-screen client, and the checks that drive it
spec/             TLA+ specifications
experiments/      pre-registrations, runs and results
tools/            the image build, and the checks that need a terminal
docs/             design decisions and comparisons
```

```bash
viva test                                   # the Lisp suite
cargo test --manifest-path tui/Cargo.toml   # the client
./spec/verify.sh                            # the TLA+ specifications
```

CI runs all three on macOS and Linux.

## Experiments

| question | answer so far | results |
| --- | --- | --- |
| Does it retain useful work? | Yes: 5 artifacts over 25 tasks, and 4 of 5 passed a cold review | [dogfood](experiments/dogfood/RESULTS.md) |
| Does retention pay? | Not yet: the corpus improved 8.2% against a 20% threshold, and one job shape got 18% worse | [dogfood](experiments/dogfood/RESULTS.md) |
| Does live self-modification pay? | No: about 23% more tokens even when unused, and 43% to 73% more when used | [kc6](experiments/kc6/RESULTS.md) |
| Does a model keep things unprompted? | No: zero `remember` calls across 45 task-runs per arm | [kc6](experiments/kc6/RESULTS.md) |

[docs/self-improvement-model.md](docs/self-improvement-model.md) states the
model behind them.

## Acknowledgements

- The agent loop is a port of [Pi](https://github.com/badlogic/pi-mono), and
  [docs/harness-lineage.md](docs/harness-lineage.md) says what came from it.
- Skills follow Anthropic's Agent Skills format, and tools follow MCP.
- The full-screen client draws with [ratatui](https://ratatui.rs) and parses
  markdown with pulldown-cmark. The engine runs on SBCL.
