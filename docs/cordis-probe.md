# B12 — Cordis probe: how does an accepted mutation leave the organism?

**Status: done. Recommendation — take the contract, not the framework, and pair
it with reconciliation, because Cordis reports a clean unload for every failure
mode viva actually has.**

One complete mutation lifecycle, run four times through the real runtime:

```
PROPOSE -> ISOLATE -> EVALUATE -> PROMOTE -> ACTIVATE -> OPERATE
        -> RETRACT -> DEACTIVATE -> RECONCILE
```

Viva already owns everything left of PROMOTE. Nothing right of ACTIVATE
existed before this probe, which is what B12 was filed to fix.

## What was run

| | |
|---|---|
| runtime | `cordis` **4.0.0-rc.8** from npm, `cordiverse/cordis` — the framework the paper formalises |
| host | Node v24.13.0, macOS 27.0.0 arm64 |
| paper | Shi, Zhang & Cui, *A Programming Paradigm for Spatiotemporal Composability*, 88pp |
| probe | [probes/cordis/](probes/cordis/) — `node run.mjs` |
| component | registers a **tool**, a **listener**, a **policy**, an owned **handle**, and **provides a service** — five contributions of four kinds, which is the case the ledger's per-definition rollback has no answer for |

**Every paper claim this probe tests was verified against the PDF before the
probe was written**, not paraphrased from the story notes: L-Raise (p38), the
author obligation on inverses (p56), Theorem 63's guard (pp34–35), the
exclusive-binding / broker split (p68), and the coeffect-projection boundary
(p23). All five check out verbatim.

**One naming drift worth recording:** the paper instantiates a fiber with
`ctx.use`; 4.0.0-rc.8 exposes `ctx.plugin`. The lifecycle states line up exactly
— `PENDING, LOADING, ACTIVE, FAILED, DISPOSED, UNLOADING` — with the calculus's
`Inactive(ξ)` carrying an error outcome realised as `FAILED`.

## The order was load-bearing, not presentational

Stage 1 measures Cordis alone. Stage 2 layers viva's reconciliation on top.
Reversing them would have produced a finding about viva's checker rather than
about the composition: a checker run against a runtime whose own guarantees have
not been characterised has no baseline to be stronger *than*.

## The observational boundary, stated before measuring

Cordis's equivalence is up to coeffect projection — §3.3.2, p23: *"The part of a
state that no key binds is thereby forgotten."* A probe that compared everything
would report failures the paradigm never claimed to prevent. So the probe
declares its boundary in [world.mjs](probes/cordis/world.mjs) before any
measurement:

```
INSIDE   tools, listeners, policy, handles     compared by snapshot()
OUTSIDE  emitted                               an append-only external log
```

`emitted` is §6.1's acquisition/emission split made concrete: a write that has
left for somewhere other parties can read. **A clean unload that leaves the audit
line standing has not failed** — it is outside what "as if it never existed" is
allowed to mean.

---

# Stage 1 — where the Cordis boundary actually lies

## A — clean unload (control)

```
residue inside the boundary   []            nothing
service binding after         withdrawn
registry                      1 -> 0        no retention
outside the boundary          ["search-capability-v1 activated"]   as declared
```

The control works. Without it, a failure in B or D could not be told from a probe
that never ran.

## B — partial activation failure

The component installs three of its contributions and then throws. L-Raise
(§4.3.4, p38) predicts four things, and **all four hold**:

| prediction | measured |
|---|---|
| the accumulator applies and the fiber arrives *"having installed nothing"* | `effects_retained: []`, residue `[]` |
| it lands `Inactive` carrying the error | `FAILED`, rejected with `index format unrecognised` |
| the failure is recorded **per fiber**, so siblings keep running | sibling `ACTIVE`, alive |
| the lifecycle is **not re-entered** from an error outcome | still `FAILED` after poking the context; one activation attempt, not two |

That last row is the one viva has no equivalent for and would not have
thought to build. A failed component is **withheld**, not retried against an
unchanged environment — the runtime declines to loop on something that has shown
itself unsound in the state it ran against.

## C — replacement (control)

§6.2 distinguishes exclusive binding, where switching implementations
*"momentarily perturb[s] every consumer's dependency"*, from a service broker
that *"absorbs this perturbation"*. Both measured, and the difference is exact:

| | consumer activations | teardowns | versions the consumer saw |
|---|---|---|---|
| exclusive binding | **2** | 1 | `[1, 2]` |
| service broker | **1** | 0 | `[1]` — while v2 serves |

One forced consumer reload versus zero. For viva this is a design choice it
would have to make too, and it is not free either way: the broker costs the
consumer any ability to observe that its provider changed.

## D — dependency withdrawal, and the discriminating control

§5.1.3 (p58): a provider entering `UNLOADING` has stopped providing, so dependents
*"recompute an unsatisfied target view and begin their own teardown while its
bindings are all still in place"*, and Theorem 63's guard `¬relied` holds the
withdrawal back *"until every consumer that resolves it to n has gone"*.

A teardown that needs the coeffect it is losing — a connection pool handing
connections back — is the case a disposer stack gets wrong. Measured:

```
provider body up
consumer up
provider body inverse
consumer teardown; pool binding visible=true
pool received 3 connections back
```

**The discriminating control is `registerProvideLast`.** Registered last, pure
LIFO would revert the provision *first* — before the provider's own body, and
long before any consumer tore down. The trace is **byte-identical** in both
arms. So the ordering came from the guard, not from a disposer stack. This is
the case that answers "is this more than LIFO", and the answer is yes.

Two further behaviours, neither of which viva has:

- the consumer lands in **`PENDING`, not `DISPOSED`** — a standing declaration
  awaiting re-satisfaction rather than a corpse;
- re-providing the key **re-activates it** (`PENDING → ACTIVE`), with no
  intervention.

### The limit of the guarantee, and it is sharp

The paper states it plainly (p35): *"the guard orders deactivations along
coeffects and not along the fiber tree: a parent may run its inverse while a
child of it is still Unloading… Parent and child are accordingly ordered more
weakly than Theorem 63 orders a provider and its consumer."*

The same dependency shape, expressed as a parent-held resource the child closes
over instead of as a coeffect key:

```
parent resource closed
child teardown; parent resource open=false      <- the ordering the guard gives is not here
```

**The guarantee is conditional on expressing the dependency as a coeffect.** An
agent writing its own components will reach for whichever is convenient, and only
one of the two is protected. For viva that is a constraint on what a
generated component is *allowed* to look like, not a property it inherits.

## H — what accumulated state costs at replacement

§7.3, against DSU and OTP: Cordis reverts the old component's effects and
reapplies the new one's *"from a clean slate, so a component's own in-memory
state does not survive a reload unless placed in a longer-lived dependency"*.
Measured on a component that builds an index while live:

| where the state lives | survived replacement | v2 had to redo |
|---|---|---|
| component-local | **no** | the whole index |
| a longer-lived dependency it injects | **yes** | nothing |

The escape hatch is real and it is cheap — one indirection. For a harness whose
premise is accumulated live state this is the price of complete retraction, and
it is payable: **state that must cross a version boundary is state that must be
named as a dependency rather than held.** That is the same shape B11 arrived at
from the other direction — the ledger authoritative, the working state
explicitly placed rather than implicitly carried.

---

# Stage 2 — the intersection

## E — the wrong inverse, and what the tracked-effect surface is worth

§5.1.1 (p56) is explicit: *"the callback supplies an inverse, and that the
inverse recovers the effect it accompanies is an obligation on the component
author rather than a property the runtime verifies."* For a human plugin that is
a discipline problem. For an agent writing its own `activate` and `deactivate` it
is a correctness problem, and it is silent.

Four variants of the same capability through the same complete lifecycle:

| variant | what it does wrong | `getEffects()` matches declaration | **Cordis verdict** | **reconciliation** |
|---|---|---|---|---|
| faithful | nothing | yes | clean unload | matches ledger |
| incomplete inverse | inverse runs, reverts nothing | **yes** | clean unload | **FAILED REVERSION** |
| out of band | never called `ctx.effect` | no | clean unload | **FAILED REVERSION** |
| disguised | out of band, plus a no-op effect under the missing label | **yes** | clean unload | **FAILED REVERSION** |

> **Cordis reports `DISPOSED`, no error, no retained effects — a clean unload —
> for all four.** It is right to: it executed every inverse it was given. The
> question it does not ask is whether the world is now what the history says.

The middle column is the finding that makes this more than a restatement of
§5.1.1. Cordis's own introspection *can* see the out-of-band mutation while the
component is active — that variant tracks 2 effects where the others track 5. So
a pre-unload check comparing declared contributions against `getEffects()` would
catch it.

**That check is worth less than it looks.** `EffectMeta` carries `{ label,
children }` and nothing about what the effect did, and the label is a free string
the author passes to `ctx.effect`. The `disguised` variant registers the label
without the deed and is indistinguishable from `faithful` on that surface. And
`incomplete inverse` was never distinguishable there at all.

```
tracked-effect check   catches OMISSION, defeated by a no-op under the right label
reconciliation         catches all three
```

This is not a Cordis defect — Cordis never claims `getEffects()` witnesses
anything. It bounds what a pre-unload check can be worth, which is a thing
viva needed to know before building one.

**So the composition is stronger than either layer, and now measurably so:**

```
Cordis layer     structural rollback     "I executed every registered inverse."
viva layer   empirical verification  "Does the world MATCH the ledger?"

revert(component);  expected = projection(ledger)
                    actual   = introspection(runtime)
                    actual != expected  ->  FAILED REVERSION
```

Neither half is redundant. Cordis without reconciliation cannot detect any of the
three failures. Reconciliation without Cordis detects them but has nothing to
withdraw the other four contributions correctly — no guard, no ordering, no
per-fiber failure isolation.

## What isolation contains, and what it does not

§6.3 says language-level mediation *"is insufficient"* for untrusted code because
a component with host-runtime access *"can reach the underlying objects
directly"*, and strong isolation still needs a process, runtime or container
boundary. Measured rather than assumed:

```
coeffect key isolated by ctx.isolate     true
ambient state reached anyway             true
ambient state reverted on unload         true   (it went through ctx.effect)
```

`ctx.isolate` isolates the realm a coeffect **key** resolves in. It is not a
sandbox and does not claim to be. **This is the measurement that separates B12
from B8** rather than an argument for it: effect containment and execution
containment are answering different questions, and a self-evolving system
plausibly needs both.

---

# F — the effect classification, recorded from what the cases produced

The probe's component produced all three, which is the point: *"every effect
needs an undo"* is not a sufficient model for an autonomous agent.

| class | example in this probe | recovery | who decides |
|---|---|---|---|
| **Revertible** | tool, listener, policy, handle, service | the inverse restores observational state | the runtime, given a correct inverse |
| **Compensatable** | the audit line in `emitted` | history stands, semantics restored by a *further* action | the author — Cordis has no machinery for it |
| **Irreversible** | — none reachable in-process | needs approval or a commit barrier | must be viva, before promotion |

§6.1 supplies the acquisition/emission boundary and discusses inversion,
withholding and compensation; **the three-way classification is viva's, not
the paper's**, and should not be cited to it. What the paper does say about
compensation is a warning worth carrying: compensating actions compose in the
same LIFO order as inverses, but *"the metatheory does not: the commutation of
Definition 60 is proved against ≃ and has to be re-established against the
coarser one"* (p68). Compensation is not a drop-in extension of the guarantee.

# G — reconciliation, and one gift from the paper

Measured in stage 2 above. §6.3 also supplies something viva should take
outright: because dependencies are **declared**, *"the complete set of
proxy-mediated capabilities a component requires is known before it runs"* — a
stronger pre-install review surface than viva currently has. An
agent-proposed component can be refused for what it *asks for* before anything is
installed, which is cheaper than detecting it afterwards.

---

# The contract to extract, and what is deliberately not taken

**Take:**

```
ComponentMutation { requires, provides, activate() -> EffectSet }
Effect            { contribution, inverse }
```

plus four behaviours the probe showed are worth more than the data structure:

1. **the guard** — withdraw a provision only after every consumer that resolved
   it has deactivated, so a teardown can still use what it is losing;
2. **failure is per-component and terminal** — siblings keep running, and a
   failed component is withheld rather than retried;
3. **consumers are standing declarations** — deactivate to `PENDING`, reactivate
   when the dependency returns, rather than dying;
4. **state that must cross a version boundary must be named as a dependency**,
   because component-local state does not survive replacement.

**Do not take:** the calculus, the coeffect algebra, isolation realms,
interception, the configuration loader, the HMR engine, or the broker. Each is
load-bearing for a general-purpose plugin host and none of them is what viva
is short of. Reproducing them turns a harness into a framework rewrite.

**Do not take the parent/child relationship as an ordering primitive.** It is the
one shape that looks protected and is not.

## Recommendation

**Adopt the contract, keep reconciliation, and do not adopt Cordis.**

The gap B12 named is real and Cordis closes most of it. Viva had
`propose → isolate → evaluate → reject/promote` and nothing for a promoted
component leaving. The four behaviours above are that missing lifecycle, and they
are small enough to implement against the ledger without importing a runtime.

But the probe also found the reason not to hand the whole problem over: **Cordis
reports a clean unload for every failure mode an agent-authored component
actually exhibits**, and its own introspection surface can be satisfied by a
component that registers a label without the deed. The layer that catches those
is the one viva already has. Neither is sufficient alone; the pair is
strictly better than either, and that is now measured rather than argued.

## The trigger

**What would make adopting Cordis itself correct:** if viva's components ever
become genuinely third-party — proposed by something other than this agent
against this ledger — then declared dependencies, realms, interception and the
broker stop being surplus and start being the review surface. At that point the
pre-install capability check of §6.3 is worth more than everything above it.

**What would kill the contract as extracted:** if an agent-authored component
cannot reliably express its dependencies as coeffect keys — if the convenient
thing keeps being the parent-held resource — then the guard never engages, the
ordering guarantee is not inherited, and what remains is a disposer stack with
extra machinery. Watch for that in the first component viva generates under
this contract rather than assuming it.

**What is settled either way:** effect containment does not subsume execution
containment. `ctx.isolate` isolates a coeffect key and a component reaches
ambient state straight through it, exactly as §6.3 says it must. B8 still has its
own question to answer.

## Reproducing

```bash
cd docs/probes/cordis && npm install && node run.mjs
```

Deterministic — no model calls, no network, no timing-dependent assertions. The
`settle()` delays are generous enough that the reactive propagation has finished
before anything is read.
