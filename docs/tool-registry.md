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
