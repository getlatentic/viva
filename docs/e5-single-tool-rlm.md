# E5 — single-tool RLM

**Status: wire format built and measured; the arm comparison is still open.**
[sexp.lisp](../src/core/sexp.lisp) reads model-emitted forms and generates
GBNF; [experiments/e5-wire-format.lisp](../experiments/e5-wire-format.lisp)
runs both formats against gpt-oss-20b. 224 assertions green.

## The natural Lisp shape

A tool call is a function call and its schema is a lambda list. `(shipping-cost
:weight 7)` rather than `{"name": ..., "arguments": {...}}`; keyword arguments are
named parameters; the signature is the schema, which is the same lambda list
[derive.lisp](../src/image/derive.lisp) already reads for the JSON path. A form
converts into the same arguments table JSON produces, so tools, schemas and
validation are shared and only the wire format differs.

## Three findings, one of which weakens the case

**The escaping tax is real but small.** A 225-character definition becomes 233
characters as a JSON string — **+3.6%, six escapes**. The "two layers, two ways to be
wrong" argument stands as a structural point, but the size cost is not an argument.
The JSON arm emitted a readable definition on the first attempt.

**A custom grammar must live inside the model's own output protocol.** A bare
s-expression GBNF made llama-server return **500, "the model produced output that
does not match the expected peg-native format"** — the grammar forbade the harmony
channel markers the server then tried to parse. Prefixing the root with
`<|channel|>final<|message|>` fixes it. This is consistent with llama.cpp's own
generated tool grammars, which carry those markers. `*channel-prefix*` is
configurable rather than hardcoded, because it is a property of the model's template
and not of Lisp.

**Grammar-constrained s-expressions work.** With the prefix, gpt-oss-20b produced a
parseable call with the definition as a live form — read directly, no unescaping:

```
parsed:    install
note:      "Computes total cost from a list of plists ... treating NIL price as zero."
source is: a form, read directly
```

Its Lisp was worse than its JSON-arm Lisp — a malformed `reduce` with the initial
value in the wrong place — which is the likeliest way this arm loses and exactly what
[the method](#method) says to measure first.

## Safety, which is not optional here

`read` on model output is the dangerous part and the tests pin it: `*read-eval*` is
off so `#.(error "pwned")` is refused, symbols intern into a sandbox package so
naming something cannot touch a package the image uses, and a length cap applies
before the read.

One subtlety worth keeping: the sandbox must import `cl:t` and `cl:nil`. A package
inheriting nothing reads the model's `nil` as a fresh symbol named `"NIL"`, which is
**true** — so every boolean argument would silently mean its opposite.



The cheapest experiment here and the most self-contained. Nothing depends on it and
it depends on nothing.

## Claim

Replace the fixed tool schema with **one** tool — evaluate a form in the image — and
the agent does better than with a hand-designed tool set, because it composes what
it needs instead of picking from what was anticipated.

This is [prime-agent](https://www.primeintellect.ai/blog/prime-agent)'s Recursive
Language Model with a persistent IPython kernel as the only tool. The Lisp version
is stronger in one specific way: the form the model writes is the same data
structure the image manipulates, so the agent can construct, inspect and rewrite
its own actions before running them. In Python that requires string-building or
`ast`.

## Method

Two harnesses over the same image and the same task set:

- **A — control: [Pi](https://github.com/badlogic/pi-mono), unmodified.** Four tools
  (`read`, `write`, `edit`, `bash`), sub-1000-token system prompt, extensions and
  skills resolved at startup. Drive genera-lab through its RPC mode. Pi is the exact
  embodiment of the condition prime-agent attacks — everything fixed before the run
  — and it is a known-strong baseline, so it makes an honest control.
- **B — treatment: one tool**, `(eval <form>)` in a package exposing the same
  operations as ordinary functions. Results bind to variables in a persistent
  environment so context holds references, not payloads. This is prime-agent's RLM
  with the image standing in for the IPython kernel.

Compare task success and token spend, model held constant.

**Do not port Pi to Lisp to get arm A.** If the control is a reimplementation and B
wins, the result cannot distinguish "beat Pi" from "beat my port of Pi". Run the
real thing.

Pi already distinguishes steering (Enter) from follow-up (Alt+Enter) and stores
sessions as a JSONL tree with `id`/`parentId` and in-place branching — so it is also
the natural baseline for [E3](e3-subturn-steering.md) and a reference data model for
[E2](e2-archive-tree.md)'s archive. Its docs are explicit that it has no
self-modification, which makes it a clean control for [E4](e4-self-editing-object.md)
too.

## Why it may matter more than it looks

The observation underneath prime-agent's design is that **most harnesses resolve
prompts, tools and schemas at startup**, because they were built for models that
needed the scaffolding. If that is now a limitation rather than a support, the fixed
schema is the first thing to drop — and an image where every operation is already a
callable function is the cheapest place to drop it.

Note their caveat, which cuts both ways: no model has been trained around this
paradigm. The headroom is unproven in both directions.

## Kills it

- The model writes materially worse Common Lisp than it writes tool calls, and the
  error rate eats the flexibility. This is the likeliest failure and it should be
  measured first, on its own, before building harness B.
- Free-form eval makes trajectories unauditable — an operator cannot tell what the
  agent did without reading Lisp. If the ledger cannot reconstruct the session
  legibly, the flexibility is not worth the opacity.
- Single-tool works only with a large context budget, because results must stay
  addressable. If context pressure forces payload inlining, the design collapses
  back into ordinary tool calls.

---

# E5 redesigned — two variables were hiding inside one question

**Amended 2026-08-11.** Everything above compares a JSON envelope against an
s-expression envelope over the *same fixed registry*. That is a question about
**representation**. The story's headline claim — one `eval` tool beats a fixed
schema — is a question about **action power**. Running them as one arm would
answer neither: if Lisp wins, nothing distinguishes

```
{"function":"shipping-cost","args":[5,":remote"]}      a better representation
```
from
```
(loop for q in *quotes* unless ... collect ...)        a vastly larger action space
```

So the variables are separated, and **E5a holds power constant while varying
representation only.**

## E5a — representation, at equal power

| arm | what the model emits | how it executes |
|---|---|---|
| **FIXED** | named JSON tools | registered callbacks |
| **JSON-AST** | `{"function": ..., "args": [...]}` | harness builds the form, applies it |
| **JSON-SEXP** | `{"form": "(shipping-cost 5 :remote)"}` | reader → apply |
| **RAW-SEXP** | `(shipping-cost 5 :remote)` | reader → apply |

**THE RULE THAT MAKES IT INTERPRETABLE: every dynamic arm is restricted to a
plain function-call expression.** No `loop`, `let`, `lambda`, `setf`, `progn`,
`defun`, no nesting that computes. One operator, literal arguments. Any arm that
gets more computational power than the others is measuring power, not shape.

That restriction is not new work: it is exactly the discipline
[inspect.lisp](../src/image/inspect.lisp) already enforces — one lookup or one
call of an existing function, literals or handles as arguments, expressions
refused with *"This tool does not evaluate expressions."*

### The progression reads cleanly

```
JSON-AST  --remove the hand-rolled AST encoding-->  JSON-SEXP
JSON-SEXP --remove the tool-call envelope-------->  RAW-SEXP
```

| result | conclusion |
|---|---|
| all three alike | syntax does not matter; keep JSON |
| `JSON-SEXP > JSON-AST` | Lisp representation matters, structured calling is fine |
| `RAW-SEXP > JSON-SEXP` | the tool-call envelope itself has measurable impedance |
| `JSON-SEXP ≈ RAW-SEXP > JSON-AST` | **keep provider-native JSON, put Lisp inside it** |

The last row is the prior worth stating in advance: encoding a Lisp AST *as
JSON* is ceremony, because Lisp already has an AST syntax.

## E5b — action space: dynamic registry against live language

**This is the consequential arm, and the one that can invalidate B14's oracle.**
E5a cannot: it forbids, by design, the very thing that separates a registry from
a language. Saying otherwise was an error in the first draft of this section —
the axes were separated above and then quietly recombined in the sequencing.

Three levels already exist in this repo, and only the first has ever been scored:

```
LEVEL 1  FIXED REGISTRY     startup tools only              every run to date
LEVEL 2  DYNAMIC REGISTRY   install DEFUN -> derive schema  self.lisp:register-tool
                            -> register -> new tool next    + derive.lisp,
                            request                          never scored
LEVEL 3  LANGUAGE           install DEFUN -> call it. No    what E5 is really
                            registration concept exists      asking about
```

| arm | how a new DEFUN becomes usable |
|---|---|
| **STATIC** | it cannot — the control |
| **REGISTER** | `register-tool`: derive a schema, expose it as a named tool |
| **EVAL** | emit `(diagnose-x ...)` directly |

**Held constant: the same generated function body, the same task, model, context
and evaluation. The candidate is generated during the episode, never
preinstalled.** Both dynamic arms emit a plain call — power is equal, exactly as
in E5a. Only the entry mechanism differs, which is what makes the comparison
architectural rather than syntactic.

**Do not use `impact_map` for this.** A small task where the agent plainly
benefits from naming a repeated helper is enough, and keeps B14's oracle
uncontaminated.

### The metric this arm needs

**Abstraction activation latency** — from DEFUN created to first successful use:

```
REGISTER   definition -> schema derivation -> registration -> model sees the
           schema -> call
EVAL       definition -> call
```

plus task success, requests, tokens, invalid actions, **could-not-act**, and
schema/registration failures.

### What each outcome decides

| result | consequence for B14 Gate 3 |
|---|---|
| `REGISTER ≈ EVAL` | the registry costs nothing real. Keep `impact_map` as a dynamically acquired **tool** |
| `EVAL` wins | do **not** run Gate 3 with a tool oracle. The oracle becomes a Lisp abstraction, and CONTROL gets whatever action space E5 established |
| `REGISTER` wins | a schema with a name, description and typed arguments is *cognitively* different from a function that merely exists — and the skill/tool distinction must **not** be collapsed |

That third row is the one worth wanting. It would mean the registry earns its
ceremony at the agent level, despite the ceremony.

## E5c — power, and then abstraction

Only after E5b. Unlock `let`, `loop`, `mapcar`, `remove-if`, `progn`, then
`defun`, and ask whether the programming language is a better action space than a
catalogue of operations.

## What collapses in B15, stated precisely

The first draft said E5c collapses B15's skill-vs-tool choice. Too broad. What
may disappear is one specific boundary:

```
ordinary function   vs   registered tool
```

which is plausibly a **registry implementation detail inherited from Pi**, not a
real distinction between kinds of improvement. These stay distinct in any harness:

```
POLICY / SKILL     "inspect live state when the source looks correct"
                   "infer a population predicate rather than patching instances"
ABSTRACTION        (defun impact-map ...)
HARNESS            how observation, context, evaluation and persistence work
```

So B15's question becomes cleaner rather than smaller: *should I improve what I
know to do, what computations I can name cheaply, how my own runtime operates —
or nothing?* If E5b shows the tool/function boundary is ceremony, B15 sheds a
category it inherited rather than losing one it needed.

## Measure errors, not just score

Per arm: task score, requests, tokens, wall time, **invalid action rate, parse
failures, schema failures, wrong argument shape, runtime errors**, actions per
successful repair, and **action-expression complexity** — how much
representation the model must emit for equivalent work.

One category is added from B14's experience and is not optional: **"could not
act"**, distinct from "acted wrongly". In B14 an agent installed a correct repair
and had no way to run it; that is neither a parse failure nor a wrong answer, and
an aggregate score cannot tell them apart. See
[b14-preregistration.md](b14-preregistration.md).

## State of play — three of four arms already exist

| arm | status |
|---|---|
| FIXED | built; every scored run to date |
| RAW-SEXP | **built** — `sexp.lisp` `read-form` + `call-arguments` map a form onto the same arguments table JSON produces, and it is restricted to a call form by construction |
| JSON-AST | **built by accident**, as `call_function` in `inspect.lisp`: `{"name", "args"}` → `(apply symbol args)`. Needs keyword arguments to be a full arm |
| JSON-SEXP | **missing**, and small — `read-form` already exists, so it is an envelope around it |

E5a is therefore much closer to runnable than the story implies.

## Order of work

```
B14 corrected Gate 1/2        no oracle built yet -- the result survives
        |                     either architecture
        v
E5a  representation           which encoding for equivalent calls
        |
        v
E5b  action space             dynamic registry vs live language
        |                     THE decision experiment
        v
architectural decision
        |
        +-- registry earns it  -> B14 Gate 3 with impact_map as a TOOL
        |
        +-- language wins      -> B14 Gate 3 with impact_map as an ABSTRACTION
        |
        v
B15  self-improvement, in the action space the evidence supports
```

**B14's Gate 1 and Gate 2 run first and are not blocked by any of this.** They
ask whether the task contains a reliably solvable repeated investigation burden
under the restricted observational regime, which is true or false regardless of
how actions are later encoded. Only **Gate 3** — the oracle ceiling — depends on
the action space, because a ceiling measured in the wrong one is a ceiling
measured for nothing.
