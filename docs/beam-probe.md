# B8 — BEAM probe: does supervision beat fork for containing a bad mutation?

**Status: done. Recommendation — do not switch, and do not treat "let it crash"
as containment. BEAM contains the faults an agent is least likely to produce and
does not contain the ones it is most likely to produce.**

Three axes, no task-set port. Each read against a number that already existed.

| | |
|---|---|
| runtime | Erlang/OTP **29** (erts 17.0.3), Elixir 1.20.2, macOS 27.0.0 arm64 |
| probes | [probes/beam/](probes/beam/) — `./run_faults.sh`, `migration_probe`, `impedance_probe` |
| baseline | SBCL fork, measured in [E1](README.md): a child that corrupts its own heap cannot touch the parent, **for any fault class**, at 28–32 ms per trial |

---

# Axis 1 — the fault boundary

The instrument is a **bystander**: an unrelated supervised process that ticks
every 10 ms and appends each tick to a file, so its progress is readable even
when the node dies without reporting. Supervision promises the victim is
replaced. The agent needs the node to still be there. Those are different
claims, and the tick count separates them.

Baseline is ~110 ticks over the 1200 ms run.

| fault | node | ticks | contained? |
|---|---|---|---|
| ordinary exception | survived | **108** | **yes** — victim restarted once, bystander untouched |
| runaway Erlang loop | survived | **110** | **yes** — reduction counting preempts it; nothing to restart |
| heap allocation, `max_heap_size` set | survived | **106** | **yes** — process killed on the first chunk |
| binary allocation, no cap | survived | 96 | **no ceiling** — 3.25 GB allocated unopposed |
| binary allocation, `max_heap_size` set | survived | 102 | **no** — 4.29 GB, the cap never fired |
| code server killed | **DIED** | 10 | **no** |
| atom-table exhaustion | **DIED** | 11 | **no** |
| non-yielding NIF, `+S 1` | **WEDGED** | 10 | **no**, and worse — see below |
| non-yielding NIF × every scheduler | **WEDGED** | 10 | **no**, and worse — see below |
| the same NIF × every **dirty** scheduler | survived | **58–78** | **partly** — node lives, degraded; see below |

## What the gradient says

**BEAM contains process-local failure and CPU monopolisation.** The first two
rows are real wins and they are not nothing: a supervisor replaced the crashed
victim without the bystander missing a tick, and a tight Erlang loop cannot
starve a scheduler because reduction counting preempts every loop that stays
inside the VM. Fork gets the same containment by killing a process; BEAM gets it
while keeping the system up.

**It does not contain VM-global resources.** The atom table is not garbage
collected and not partitioned per process, so one component exhausts it for
everybody — `no more index entries in atom_tab (max=65536)`, node gone in 0.53 s.
The code server is a named singleton every module load passes through, and a
component can simply kill it: `kernel_sup` reports the child terminated and the
node follows.

## The per-process memory ceiling covers less than its name suggests

This corrected a reading I had already made. `max_heap_size` looked like
containment until the arms were separated:

```
binaries, cap set    4.29 GB  -- the full probe budget, cap never fired
binaries, no cap     3.25 GB  -- indistinguishable
heap data, cap set   killed on the first chunk
```

`max_heap_size` bounds the process **heap**, and binaries over 64 bytes are
reference-counted **outside** it. So BEAM's only per-process memory ceiling does
not bound the allocation an agent generating a buffer is most likely to make.
The cap is real and works for what it covers; what it covers is not the
dangerous case.

## The NIF result is worse than "not contained"

A NIF runs outside reduction counting, so nothing preempts it. With one
scheduler, one non-yielding NIF wedges the node. With one call per scheduler, it
wedges every node regardless of scheduler count.

**And the wedged node could not be killed by SIGTERM.** Measured, not inferred:
one such node survived SIGTERM and ran **4m43s against a 15 s limit**, and died
instantly on SIGKILL. Every scheduler was in native code, so nothing was left to
run the signal handling. The driver now uses `timeout -k 4` and reports exit 137
against 124 to record which signal was needed.

For a system whose premise is that an agent writes its own code, this is the row
that matters most: the moment generated code includes anything native, the
containment story is not weaker than fork's — it is absent, and the usual
recovery lever does not work either.

### The mitigation exists, and an agent can decline it

Dirty schedulers are separate OS threads from the normal ones, so the obvious
defence is to force generated native code onto them. Measured rather than left
as a suggestion: the **identical** busy loop, flagged `ERL_NIF_DIRTY_JOB_CPU_BOUND`
and saturating all ten dirty CPU schedulers.

```
normal schedulers saturated   node wedged, ignored SIGTERM,   10 ticks
dirty schedulers saturated    node survived and reported,     58-78 ticks
                                                              (two runs)
```

**That moves the worst row.** Wedged-and-unkillable becomes alive-and-degraded —
and the degradation is ordinary CPU contention, ten busy dirty threads against
ten cores, not a scheduling failure. The spread across runs is wide enough that
the tick count should be read as "clearly degraded, clearly alive" rather than as
a rate. So the NIF case is defensible.

But the flag lives in the NIF's own `ErlNifFunc` table. **It is the component
author's declaration, and there is no VM option that forces it.** An agent
writing its own NIF simply omits it and gets the wedged row back.

That is the third time this programme has met the same shape:

```
B12   the inverse         author-supplied, unverified   -> silent bad unload
B8/3  code_change/3       author-supplied, unverified   -> silent bad migration
B8/1  the dirty flag      author-declared, unenforced   -> unkillable node
```

Every mitigation in both runtimes is opt-in by the component being contained.
That is a sound design when the author is a person under review and a different
proposition when the author is the system itself.

> **Read against E1's baseline:** SBCL's fork contains all ten of these by
> construction, because the child is a separate OS process. BEAM contains three
> outright and one conditionally, where the condition is the generated
> component's own cooperation. That is the opposite of the conventional reading,
> and it is the reading the conventional one skips because it stops at row one.

**What this does not say:** that BEAM's isolation is bad engineering. It is
intra-VM isolation and it is excellent at what it is — the gradient is a
statement about which boundary you are buying, not about quality. It also does
not say the dangerous rows are common in ordinary Erlang systems; they are not.
They are specifically the rows an autonomous code generator can reach.

---

# Axis 2 — mutation impedance

The whole transaction, not "Lisp forms versus Erlang tuples":

```
propose -> representation -> parse -> transform -> compile -> load ->
locate the affected process -> activate -> inspect
```

Scored separately for the two workloads, because vivarium does both and one
averaged number would hide the effect.

## Generation — the story's outcome (a), confirmed

```
representation the agent writes    source text
abstract format reached the agent  false
steps                              file:write_file, compile:file, code:load_binary
```

Writing a definition that did not exist requires nothing to be read back, so the
representation question never arises. The model emits text, three library calls
install it, and the abstract format is not involved. **Erlang's
non-homoiconicity is architecturally conspicuous and costs nothing here.**

## Transformation — where a structural representation should pay

Changing a definition that exists means reading it back out of the running
system first, and BEAM's answer depends on a compile flag chosen earlier:

| | recoverable from the runtime | fidelity |
|---|---|---|
| compiled without `debug_info` | **nothing** | the source is unrecoverable; the agent must have kept it, or go back to the file |
| compiled with `debug_info` | **abstract format** | 5 forms, structurally transformable, reprintable as source — but not the source the agent wrote |

**The round trip is lossy either way**, and in the default case it is total. A
self-modifying system that has to consult its own source tree has left the image
model, which is the comparison being made. SBCL's round trip is not lossy in the
same sense: a form read back is the same kind of object the agent produced.

**Stated as narrowly as it was measured.** This is an availability-and-fidelity
result about what the runtime supplies. The downstream claim — that a structural
representation *materially reduces agent errors* on transformation — is **not
tested here**. Testing it needs the harness pointed at both substrates on matched
tasks, and B8's own acceptance criterion forbids porting the task set to get
there. That gap is real and is the reason this axis stops short of the story's
outcome (b) rather than claiming it.

---

# Axis 3 — stateful replacement

B12 turned this from a description of two mechanisms into a comparison, because
both sides now have measured semantics:

```
OTP                MigrateState      old state -> code_change/3 -> new state
vivarium/Cordis    RevertAndReapply  state lives outside the replaceable thing
```

**The agent drives every upgrade.** Module source is generated as text at
runtime, compiled, loaded, and migrated through `sys:suspend` / `sys:change_code`
/ `sys:resume` — no release script, no appup, no relup. Otherwise this would
measure that OTP release upgrades work, which nobody doubts and which is not the
question.

| arm | mechanism | agent steps | process identity | still serves | **runtime reported a problem** | **reconciliation** |
|---|---|---|---|---|---|---|
| migrate, correct | `code_change/3` | 7 | preserved | yes | no | matches ledger |
| migrate, **wrong** | `code_change/3` | 7 | preserved | yes | **no** | **FAILED TRANSITION** |
| externalise, correct | store + restart | 8 | not preserved | yes | no | matches ledger |
| externalise, **wrong** | store + restart | 8 | not preserved | yes | **no** | **FAILED TRANSITION** |

The wrong arms drop the accumulated evidence — an omission, not a corruption,
because that is what an author actually gets wrong. In both, the process kept
serving, answered queries, and reported nothing. Only the ledger comparison found
it.

> **OTP trusts `code_change/3` exactly as Cordis trusts the inverse.**

That is the finding, and it generalises B12 rather than repeating it. Two
runtimes with nothing in common — a JavaScript effect system and the BEAM — both
let a component describe its own transition and neither verifies the description.
**The gap is not a property of Cordis. It is a property of every runtime that
delegates its own transition to the component being replaced, and reconciliation
is therefore substrate-independent.**

## The answer to the axis

> **Does forward migration buy enough over explicit externalised state plus clean
> retraction to justify its complexity? No.**

It costs one step fewer and preserves process identity, which is worth something
where identity is load-bearing — a registered name, an open connection, a
subscription. It buys **nothing on correctness**: same silent failure, same
detector. And it carries a cost the externalised arm does not: `code_change/3` is
a bespoke transformation function the agent must write correctly for every shape
change, whereas the externalised store needs the replacement only to read the
keys it wants.

For vivarium the externalised arm is also the one already implied by the
[B11 + B12 rule](../backlog.toml): state that must cross a version boundary is
named as a dependency rather than held. Axis 3 says taking that route costs one
extra step and no correctness.

---

# Recommendation

**Do not switch to BEAM.** The three axes point the same way:

1. **Containment is the reason people reach for BEAM, and it is the axis that
   went worst.** Three of ten fault classes contained outright, against fork's
   ten. The uncontained ones — VM-global tables, unbounded binaries, native code
   — are precisely the ones a code-generating agent can reach, and the NIF case
   produces a node that ignores SIGTERM. The one available mitigation is a flag
   the generated component sets on itself.
2. **Mutation impedance costs nothing on generation and is lossy on
   transformation**, in the default configuration totally so.
3. **Forward migration does not pay for itself** against externalised state,
   and shares its blind spot.

**What to take anyway**, because two of these are genuinely better than what
vivarium has:

- **Reduction counting.** A runaway loop that cannot starve the system is a real
  property, and SBCL has no equivalent — a non-yielding Lisp loop in the serving
  image is a wedge. This is an argument for keeping trials in forked children
  rather than for switching runtimes, but it is a real gap in the parent.
- **Supervision as a restart policy, not as containment.** The `one_for_one`
  behaviour — replace the failed child, leave the siblings — is worth copying at
  the harness level. It is what B12's per-component terminal failure already
  gestured at, arrived at independently by a second runtime.

**What is now settled across three probes:** effect containment (B12) does not
subsume execution containment, and execution containment as BEAM supplies it is
**partial**. Neither runtime gives vivarium a boundary it can rely on for
arbitrary generated code. The boundary that does hold for every fault class is
the one E1 measured and vivarium already uses: **a separate OS process**.

## The trigger

**What would make BEAM the right substrate:** if vivarium's workload became many
long-lived concurrent agents whose failures are ordinary crashes rather than
generated-code pathologies — supervision, hot upgrade and reduction counting are
then all on the hot path and fork's per-trial cost is paid continuously instead
of occasionally. Nothing in the current workload looks like that.

**What would reverse the axis 1 finding:** a way to force generated native code
onto dirty schedulers *without the component's cooperation*. The dirty-scheduler
mitigation was measured and it works — wedged-and-unkillable becomes
alive-at-half-rate — so the only thing standing between BEAM and a defensible
NIF story is that the flag is declared by the code being contained. A VM-level
option, a load-time rewrite of the `ErlNifFunc` table, or a review gate that
refuses NIFs without the flag would each close it. The first two do not exist
today; the third is vivarium's to build and is the cheap one.

**What is not open:** whether "let it crash" is containment for this workload. It
is a restart policy layered on intra-VM isolation, and the gradient shows exactly
where that isolation stops.

## Reproducing

```bash
cd docs/probes/beam && ./run_faults.sh
```

```bash
cd docs/probes/beam && erlc -o /tmp/b8 migration_probe.erl impedance_probe.erl && erl -noshell -pa /tmp/b8 -eval 'migration_probe:main()'
```

Each fault runs in a **fresh node** — half of them are meant to kill it, and a
shared node would let the first fatal case silently invalidate every case after
it. The victim fires its fault **once**; an earlier version re-crashed on every
restart, exhausted the supervisor's intensity limit within a second, and reported
"node died" for a fault that was perfectly contained.
