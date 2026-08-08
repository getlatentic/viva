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
