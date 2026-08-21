# The tool registry

Behaviour the organism retained, as files it can call. Kill criterion six
settled where retained code lives: compiling it into the image lost 0/6 and
died with the process, so what survives is a script on disk plus a manifest.

## Layout

A tool is a directory containing `tool.json` and whatever it runs. Loaded
from the machine's registry then the project's, later winning by name — the
same resolution skills and templates already use.

```
~/.vivarium/tools/<name>/       the machine's
<cwd>/.vivarium/tools/<name>/   the project's, and it wins
    tool.json
    run.py                      any language; the model picks
```

## The manifest

```json
{
  "name": "usage_totals",
  "description": "Sum prompt, completion and cache tokens from a JSONL transcript.",
  "version": 1,
  "exec": ["python3", "run.py"],
  "parameters": [
    {"name": "path", "type": "string", "description": "transcript to read", "required": true}
  ]
}
```

`name` is alphanumeric with dashes and underscores. `exec` is a non-empty
array of strings, run from the tool's own directory. `parameters` accepts
`string`, `integer`, `number`, `boolean` — scalars only for now, and an
unknown type is a refusal rather than a guess. The parameter list becomes a
JSON Schema through the same builder every shipped tool uses, so a registry
tool reaches the model by exactly the path the others do.

## The calling convention: JSON on stdin, result on stdout

Arguments arrive as one JSON object on standard input. Anything the tool
prints is the result; a non-zero exit makes it an error result carrying that
output, and a tool that crashes is the organism's mistake to see, never the
run's death.

**Not argv, deliberately.** Arguments crossing a shell is the exact bug class
this project has already paid for twice — a delimiter eaten once by a Lisp
string and again by `sh`. A JSON object on a pipe has no quoting layer to
lose, and the suite proves it with a value carrying quotes, spaces, a
semicolon and `rm -rf /`.

## What a tool inherits

A whitelist: `PATH`, `HOME`, `LANG`, `LC_ALL`, `TMPDIR`, plus `VIVARIUM_CWD`
naming the task's working directory. Nothing else — blacklisting credentials
would mean enumerating every name a provider might ever use, a list that is
wrong the moment somebody adds one. A tool that genuinely needs a secret
should be handed it as a parameter, which the transcript records, rather than
by ambient inheritance, which it does not.

Tools run from their own directory, not the task's, so a tool's helper files
resolve relative to itself. The task's cwd is available as `VIVARIUM_CWD`.

## Loading, and refusal

Loaded per tool-set construction rather than cached, so a tool written during
one task is callable in the next without a restart — the point of retention
living in files. A malformed manifest is refused **with a reason** and
produces no tool: half-loading would show the model a name it cannot call
and a failure it cannot diagnose. Reasons land in `agent-registry-warnings`
so a caller can show them, because a tool that failed to load looks exactly
like a tool nobody wrote.

## Serving the registry over MCP

```bash
vivarium mcp --cwd /path/to/project
```

Speaks MCP over stdio — one JSON object per line — so a tool the organism
wrote is callable from any client that speaks the protocol, not only from
inside vivarium. This is why the manifest was JSON from the start: the
parameter list becomes an `inputSchema` through the same builder every
shipped tool uses, so `tools/list` is a projection of the registry rather
than a translation of it.

Client configuration is one entry:

```json
{
  "mcpServers": {
    "vivarium-tools": {
      "command": "/path/to/vivarium/bin/vivarium",
      "args": ["mcp", "--cwd", "/path/to/project"]
    }
  }
}
```

**The error split is normative and load-bearing.** A tool that ran and failed
comes back as a *result* with `isError: true`, so the model can read it and
try something else. Failing to *find* the tool, or a malformed request, is a
protocol *error object*. A client that cannot tell "your tool broke" from
"there is no such tool" cannot report either honestly.

**Entries are read once, at startup.** A served surface that changed under a
client mid-session would be lying about what it advertised; the protocol has
a `listChanged` notification for that, and this server does not claim it.
Restart the server to pick up new tools.

Nothing prints to standard output but a reply — a stray format statement
corrupts the stream for the client.

## The exec surface, stated plainly

A registry tool is a script this process runs. That is the point of it, and
it is also the whole risk, so here is exactly what is and is not true.

**It is not a sandbox.** A tool runs as you, with your filesystem access.
KC6 proved the practical form of this: an agent handed a confined `:root`
still read sibling directories through `bash`, because confinement applies
to vivarium's own file tools and not to subprocesses. A registry tool is a
subprocess. If it can be run, it can read what you can read.

The trust boundary is therefore **who wrote the tool**, and that is the
control:

- **Only trusted projects.** `.vivarium/tools/` in a cloned repository is
  its author's code. It does not load until that project root is trusted,
  and the trust record lives in `~/.vivarium/trusted.sexp` — outside every
  project, so a project cannot trust itself. The refusal is a warning rather
  than silence, because a control that looks like "there was nothing there"
  is not a control. The machine's own `~/.vivarium/tools/` is always
  permitted: it is yours, and requiring you to trust yourself would only
  teach the habit of clicking through the question that matters.
- **Paths are canonicalised on both sides** — symlinks resolved, trailing
  slash stripped. On macOS `/var` is a symlink to `/private/var`, so without
  this a project trusted by one path is refused by the other, and a security
  control that fails confusingly gets disabled by whoever is trying to work.
- **Containment is containment.** `/foo` does not contain `/foobar`.

**What a tool inherits** is a whitelist: `PATH`, `HOME`, `LANG`, `LC_ALL`,
`TMPDIR`, and `VIVARIUM_CWD`. Not a scrub list — blacklisting credentials
means enumerating every name a provider might use and being wrong when one
is added. A secret a tool genuinely needs should arrive as a parameter,
which the transcript records, not by ambient inheritance, which it does not.

**What a tool can spend** is bounded: 120 seconds, then it is killed; and
output is truncated at the same limit every other tool uses, with the cut
announced rather than silent.

**When a tool breaks**, the failure is a result the model can read — exit
code and output — never the death of the run or of the MCP server. Over MCP
that failure is `isError: true` inside a result, while a *missing* tool is a
protocol error, because a client that cannot tell those apart cannot report
either honestly.

**No network assumptions.** Vivarium neither grants nor blocks a tool's
network access; a tool has whatever the machine gives it. If that matters
for your setting, confine the whole process — vivarium does not claim a
boundary it does not enforce.

## What a manifest promises, and how that is checked (#41)

A `tool.json` is written by a model and describes a script the same model
wrote. Until this existed, nothing checked that the two agreed — and the way
they disagree is expensive. The manifest omits a parameter the script
requires, the model cannot send what it was never told about, and the failure
surfaces inside somebody else's traceback, in a later task, to a different
agent than the one that wrote it. In-image tools never had this problem:
`derive.lisp` reads the schema off the live function, so it cannot go stale.
File-backed tools gave that property up.

**The seam is a declared calling convention, not a probe with real
arguments.** A script that takes parameters must answer a describe request:

```
stdin   {"vivarium":"describe"}
stdout  {"parameters":[{"name":"path","type":"string","required":true}]}
exit    0, and nothing else happens
```

The script is then the authority on its own interface and the manifest is a
cache of it, so there is no second copy free to drift. The alternative —
calling the tool with invented arguments to see whether it complains — runs
the tool *for effect* at registration, which is a side effect nobody asked
for.

**A tool that declares no parameters is not probed.** There is nothing for it
to lie about, and every tool graduation writes is of that shape, so the cost
of the check falls exactly on the tools that carry the risk.

**Refusals name the field.** Both directions are checked and they fail
differently:

| what is wrong | what registration says |
|---|---|
| the manifest declares `x`, the script does not accept it | `the manifest declares "x" but the script does not accept it` |
| the manifest calls `x` a string, the script an integer | `the manifest calls "x" a string; the script calls it an integer` |
| the script *requires* `x`, the manifest omits it | `the script requires "x", which the manifest does not declare` |

The third is the expensive one and the reason this exists.

**At registration, not at load and not at first call.** Registration is when
the model that wrote both files is still there to fix them. The script is
written first and the manifest last, so a refusal leaves a directory the
loader ignores rather than a manifest naming an unchecked script.

**Staleness is the load-time half.** A manifest records a digest of the
script beside it. If the script has changed since, the tool is *reported* —
`counter is stale: run.py has changed since its manifest was written` — and
not offered to the model. A manifest with no digest makes no claim and is
left alone, because every tool written before this existed is of that kind
and a check that broke them would be a check that defeated itself.

The digest is FNV-1a: it notices that a script changed, and does not pretend
to defend against somebody who wants it to appear unchanged. The registry
already refuses to load an untrusted project at all; that is where the
security boundary is.
