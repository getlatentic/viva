# B16 — Substrate: is SBCL still the right runtime, now that threads are not the ceiling?

**Pre-registered 2026-09-10, before any data exists.** The comparison, the
thresholds and the kill criterion are fixed here and do not move afterwards.

## Why this is open at all

Two earlier results left the substrate question unresolved rather than settled,
and the manifesto says so in its own words.

**KC6 fired.** Live self-modification produced no measurable gain over external
skills and tools — 0 of 6 families favoured the live image, with the door
genuinely used (47 capabilities minted, 10 promoted) at 1.9x the cost of text
retention. The manifesto's own consequence: *"SBCL loses its main
justification and the architecture question reopens."*

**B8 fired the other way.** BEAM was probed on the reason people reach for it
and lost to plain `fork`: 3 of 10 fault classes contained outright against
fork's 10, with the uncontained ones — VM-global tables, unbounded binaries,
native code — exactly the ones a code-generating agent can reach. A
non-yielding NIF produced a node that ignored SIGTERM for 4m43s against a 15s
limit.

So the incumbent lost its justification and the challenger lost its probe.
**SBCL is currently the substrate by inertia, not by evidence**, and that is the
honest state to reason from.

## What changed on 2026-09-10

BEAM's strongest remaining argument for *this* workload was scheduling: viva ran
one OS thread per session, and the daemon stopped answering near 750 sessions
where BEAM does hundreds of thousands. That argument is now weaker, because the
ceiling moved without changing runtime.

Measured, ten-core machine, before and after parking idle sessions:

| sessions | threads before | threads after | footprint before | after |
| --- | --- | --- | --- | --- |
| 250 | 256 | 6 | 171 MB | 138 MB |
| 500 | 506 | 6 | 704 MB | 172 MB |
| 1000 | *stopped answering* | 6 | — | 223 MB |

Threads are flat. Whatever now limits the daemon at 1000 sessions is
`session.list` rendering every cell into one response, which is an API shape and
runtime-independent.

**This is the reason to pre-register rather than decide.** The obvious move
after a win like that is to conclude the substrate question is closed. It is
not: parking answered the thread argument and says nothing about the other two.

## B8 tested a port, not a design — and that is the flaw to fix here

Re-reading B8's fault table before building on it. Ten fault classes, three
contained. But of the seven uncontained:

- **Three are the same NIF**, at `+S 1`, across every scheduler, and across every
  dirty scheduler. A NIF is native code sharing the VM, and OTP's own guidance
  is that a long-running NIF wedges the scheduler. The idiom for untrusted or
  generated native code is a **port** — a separate OS process — precisely
  because a NIF is not contained and never claimed to be. Counting one
  documented anti-pattern three times inflates the failure column.
- **Atom-table exhaustion** is reachable only by minting atoms from untrusted
  input, which the idiom also forbids.
- **Binaries above the heap cap** is a fair hit with no idiomatic answer.
- **Killing the code server** is a fair hit.

Within the idiom the count is closer to three of five than three of ten. And
B8's own sentence, which the summary of it dropped: *"Fork gets the same
containment by killing a process; BEAM gets it while keeping the system up."*
Fork wins that column by giving up the liveness a live-image organism exists
for.

**What B8 did not test is the thing an OTP engineer would build.** It injected
faults into one node holding everything — viva's current shape, ported. It did
not test a generated component in its **own node** over distribution, native
code behind a **port**, or supervision strategies chosen for the failure shape.
Those are the first three things the idiom prescribes, and none was measured.

So B8 is evidence about a naive port, not about BEAM. That is the flaw this
pre-registration must not repeat.

## And today's wall is a point for BEAM that B8 never collected

Measured 2026-09-10, fixing viva's session ceiling: the daemon dies at around
1100 sessions with `1205 is not of type (UNSIGNED-BYTE 10)` — a descriptor
number that no longer fits the ten bits `select` allows. Per-session cost was
one thread and two file descriptors; both are now released when a session is
quiet, which moved the wall from ~600 to ~1100 and made threads flat at 6.

The remaining ceiling is `select` itself, and it is a class of problem the BEAM
runtime does not have. B8 never collected this because it measured containment,
not scale. **A substrate comparison that omits it is as partial as B8 was.**

## The claim, stated so it can lose

> With threads no longer the ceiling, BEAM's remaining advantages over SBCL —
> per-process heaps that avoid a global collection pause, and versioned hot code
> loading — do not change viva's measured behaviour enough to justify a runtime
> move.

If that is right, SBCL stays and the question closes properly for the first
time. If it is wrong, the manifesto's reopened question has an answer.

## Arms

1. **SBCL as it stands**, after the parking work.
2. **Idiomatic BEAM**, designed by someone who writes OTP — generated components
   in their own nodes, ports for native code, supervision strategies chosen per
   failure shape. Not viva transliterated.
3. **BEAM as B8 built it**, kept as the control, so the difference between "BEAM"
   and "BEAM used properly" is itself a measured quantity rather than an
   argument.

Arm 3 exists because the honest reading of B8 is that it measured arm 3 and
reported it as arm 2.

## What must be measured, and nothing else

**1. The collection pause under load.** SBCL has one shared heap and a
stop-the-world collector. At 1000 sessions the daemon has one heap for every
session's conversation. BEAM gives each process its own heap and collects them
independently.

*Hypothesis worth killing:* the residual failure at 1000 sessions is partly a
global GC pause, not only `session.list`.

*How:* instrument collection pause time against session count, before and after
fixing `session.list`. If pauses stay flat as sessions grow, the per-process
heap argument does not apply to this workload and one of BEAM's two remaining
advantages is void.

**2. Hot code loading, honestly compared.** `create_capability` compiles into
the running image with no versioning, no two-generation window, and no rollback.
OTP has all three and has had them for decades. But B8 already found OTP trusts
`code_change/3` the way Cordis trusts its inverse: a wrong migration keeps
serving and reports nothing.

*Hypothesis worth killing:* versioned hot loading is materially safer than what
viva does, rather than differently unsafe.

*How:* the B8 fault battery, re-run against the mechanism rather than the
containment boundary. Same fault classes, same counting.

## The kill criterion, as a number

**If neither advantage produces a measured difference of 20% or more on a
workload viva actually runs, the substrate question closes in SBCL's favour and
does not reopen without new evidence.**

Symmetrically: if the GC pause grows with session count *and* per-process heaps
would remove it, that is a reason to migrate, and the cost of migration is then
a schedule question rather than an architecture one.

## What this design cannot do, said out loud

It cannot compare the two runtimes on developer velocity, hiring, library
ecosystems, or how pleasant either is to work in. Those matter and are not
measurable here, so they are not smuggled in as though they were.

It cannot settle whether a rewrite is affordable. It can only say whether one is
*justified*, which is the half that has evidence attached.

And it cannot be run on borrowed conclusions. B8's numbers were about
containment; KC6's were about retention. Neither answers this, which is why this
is a new pre-registration and not a re-reading of old ones.

## Threats

**The measurement that flatters the incumbent.** viva is instrumented in SBCL
and not in BEAM, so it is far cheaper to produce a favourable SBCL number than a
fair BEAM one. Any comparison that runs only on this side of the fence is
evidence about instrumentation, not about runtimes.

**The sunk cost of a working system.** 1,986 tests, 33 conformance invariants
and 23 TLA+ configurations exist in Lisp. That is a real reason not to move and
not a reason the claim above is true. Keep them apart.

**A win that answers the wrong question.** Parking removed the thread ceiling
today. It would be easy to read that as the substrate question being settled. It
settles one of three arguments.
