# B7 — Smalltalk probe: does the durability advantage show up in outcomes?

**Status: done. Recommendation stands — do not switch — but not for the reason
the first pass gave.** Three measurements, no port, no task set, no harness.

The first pass ran only Pharo, whose ARM64 VM will not start on this host, so
everything went through Rosetta and the headline came out as "Smalltalk stops the
world for ~590 ms against SBCL's ~30 ms, a 20× loss". A native ARM64 control on
Squeak, plus a Rosetta control on the *same* Squeak image, shows two-thirds of
that was translation overhead. The corrected numbers:

| | serving-process pause | whole operation | artifact | ms/MB |
|---|---|---|---|---|
| **SBCL 2.6.7, native ARM64**, fork + save | **~30 ms** | 261–461 ms | 37.2 MB core | 6.2–11.6 |
| **Squeak 6.1, native ARM64**, `snapshot:andQuit:false` | **214 ms** | 214 ms | 51.3 MB image | 4.0 |
| Squeak 6.1, x86_64 under Rosetta | 630–811 ms | same | same | 12.5 |
| Pharo 13.1, x86_64 under Rosetta | 587–823 ms | same | 58.7 MB image | 10.0 |

The gap is **7×, not 20×** — and it is not a gap in engineering quality. Per
megabyte Smalltalk writes its heap *faster* than SBCL does. The entire difference
is that **SBCL forks and Smalltalk does not**.

So M4 asked whether Smalltalk can fork too. **It can.** A Pharo image forked 265
times across two runs while serving traffic, churning the heap, forcing full GCs
and compiling methods. No fork failed, nothing in flight was lost, and every child
wrote an image that restarts, resumes mid-computation and serves. The parent's stall is **tens of
milliseconds at the median** across every configuration tested — 18–75 ms in the
lightest run, p50 56–142 ms in the heavier ones — against SBCL's own 30–36 ms.
The *tail* is heavier and noisier than any single run suggests, and probe 4c
failed to attribute it: see there for what that does and does not license.

Stated at the width the evidence actually supports: **for the checkpoint semantics
tested here, Smalltalk matches SBCL's low-pause fork-and-save while additionally
preserving control flow.** Not "forked Smalltalk VMs are safe" — see M4's own
limits. The narrow primitive, *fork and immediately checkpoint*, is what was
measured, and it is the only one viva would need.

That removes the runtime objection. What is left against switching is M3 — the
derived schema — and the fact that nothing currently open needs what Smalltalk
uniquely offers.

Scripts are in [probes/](probes/); every number is reproducible from them.

---

## Environment, and a correction to make first

| | |
|---|---|
| Squeak | 6.1 (23976), 50.6 MB fresh — **the native ARM64 control** |
| Squeak VM | OpenSmalltalk Cog Spur `202606270913`, `macos64ARMv8`, native arm64 |
| Pharo | 13.1 (`Pharo13.1-64bit-4f7563d`), 54.6 MB fresh |
| Pharo VM | Pharo v10.3.9, Nov 2025 "stable" and Jan 2026 "latest" — **neither starts here** |
| host | macOS 27 (Darwin 27.0.0), Apple Silicon |
| SBCL control | 2.6.7, same host, native arm64 |

**The correct statement is not "the ARM64 Pharo VM never starts on this machine",
which is what the first pass concluded, but this:** the current Pharo/Cog VM build
cannot reserve its JIT code zone under macOS 27's address-space layout, and dies
at startup doing so. 0/5 starts on the stable build, 0/5 on the latest:

```
[ERROR] allocateHeap (…/gcc3x-cointerp.c:93203):Could not allocate codeZone in
        the expected place (0x320000000), got 0x7000000000
[ERROR] error (src/debug.c:46):Aborting the execution of the VM
```

Native ARM64 Smalltalk is fine. The **upstream OpenSmalltalk ARM64 Cog VM starts
first time on this host and runs every probe below**, JIT and all. The failure is
specific to the Pharo VM build, not to the architecture, not to Smalltalk, and
not to the JIT as such.

Worth recording because it cost real time: the abort prints a crash dump, and a
crash dump happens to contain the digits `42`, so a naive `eval "6*7"` smoke test
false-positives. Several apparently contradictory bisects were that artifact.
Probe scripts use a distinctive token instead.

**How much Rosetta cost.** Held constant — same Squeak image, same VM source
revision, only the architecture differing — four consecutive idle snapshots:

```
native arm64  :  209  204  203  206 ms
x86_64/Rosetta:  811  651  643  630 ms      →  ~3.1× penalty
```

Pharo under Rosetta (587–823 ms) lands on Squeak under Rosetta (630–811 ms).
That is the useful part: Pharo and Squeak are doing the same work at the same
speed once the architecture is held fixed, so a native ARM64 Pharo VM would very
likely land near Squeak's ~205 ms. Nothing below depends on Pharo being slow.

Raw disk here writes 59 MB in 20–30 ms (≈3.9 GB/s NVMe), so no checkpoint on
either substrate is I/O-bound; all of them are spending their time on heap
traversal and GC, which is CPU work, which is why translation showed up so
strongly.

---

## M1 — Snapshot under load

A green-threaded server under **external** load, snapshotting itself mid-traffic.
The load has to come from outside the image: an in-image client is itself a
Smalltalk `Process`, would be suspended by the same snapshot, and could never
observe the stall it was meant to measure. Handler sleeps 300 ms, 8 concurrent
Python workers, ≈25 req/s, 18 s run, snapshot at t+8 s. Squeak uses `WebServer`,
Pharo uses Zinc.

**Squeak, native ARM64** — three runs:

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| pause, measured in-image | **214 ms** | **215 ms** | **214 ms** |
| completions during the pause | 0 | 0 | 0 |
| longest gap between client completions | 353 ms | 334 ms | 354 ms |
| in flight when the snapshot began | 8 | 8 | 8 |
| **in-flight requests lost** | **0** | **0** | **0** |
| latency before, p50 / max | 304 / 331 ms | 303 / 335 ms | 304 / 329 ms |
| latency across the pause, p50 / max | — / — | 303 / **356** ms | 303 / **356** ms |
| latency after, p50 / max | — | 303 / 305 ms | 304 / 306 ms |

**Pharo, x86_64 under Rosetta** — pause 587 / 823 / 589 ms, idle baseline
577 / 598 / 585 ms, image 58.7 MB, in flight 8 / 8 / 8, **lost 0 / 0 / 0**,
worst gap 713 / 646 / 659 ms, latency across the pause max 838 / 898 / 773 ms
against a baseline max of 446 / 469 / 461 ms.

Two things hold on both, and one only holds natively.

**In-flight requests genuinely survive, everywhere.** 48 in-flight requests
across six runs on two substrates; none lost, all HTTP 200. Afterwards latency
returns to baseline exactly.

**Load costs nothing.** Pharo idle 577–598 ms against 587–823 ms under traffic;
Squeak idle 203–209 ms against 214–215 ms. The pause is the price of writing the
heap, not of serving. Repeated checkpointing does not degrade.

**Natively, the pause mostly disappears into the latency budget — and that is
arithmetic, not luck.** A handler blocked in `(Delay forMilliseconds: 300) wait`
does not pay for a freeze it slept through: when the image thaws, the delay's
deadline has already passed and it fires at once. The penalty is roughly
`max(0, pause − work still owed)`. With a 214 ms pause and 300 ms of work, almost
every request hides it completely — measured max latency 356 ms against a 331 ms
baseline, a **25 ms tail**. With Pharo's Rosetta-inflated 587 ms pause the same
requests cannot hide it and paid up to 538 ms. The pause being *shorter than one
unit of work* is what makes it cheap, and that is a property of the workload as
much as of the substrate.

### Beside SBCL, comparing like with like

B6 records 388 ms for fork-and-save. That is the **whole operation**, and it is
not the quantity Pharo's pause is: in SBCL the *child* does the writing while the
parent keeps running. What decides availability is how long the serving process
stops. Measured here, three runs
([probes/smalltalk-p1-sbcl-comparison.lisp](probes/smalltalk-p1-sbcl-comparison.lisp)):

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| **parent's worst stall** (= the `fork()` call) | **31.4 ms** | **36.0 ms** | **29.6 ms** |
| whole operation, fork → child reaped | 291 ms | 461 ms | 261 ms |
| core written | 37.2 MB | 37.2 MB | 37.2 MB |
| parent's accumulated state intact | 5000 events | 5000 events | 5000 events |

The whole-operation figure reproduces B6's 388 ms. The parent stall does not
appear in B6 at all, and it is the honest comparator: **~30 ms against 214 ms.**

But note what the ms/MB column in the summary says. Squeak writes its heap at
4.0 ms/MB; SBCL's child manages 6.2–11.6 ms/MB. **Smalltalk is not slower at
checkpointing — it is slower at staying available while it checkpoints**, because
it does the work in the process that is serving. That is one technique apart, not
one architecture apart, and the technique is the one viva already uses.

Whether Squeak or Pharo could fork the same way is the obvious follow-up and was
not tested. Smalltalk `Process`es are green, so the Smalltalk side is safe; but
the OpenSmalltalk VM runs OS-level helper threads (heartbeat), so `fork` from
inside the image is not obviously safe and would need measuring, not assuming.

---

## M2 — Resume mid-computation

The capability SBCL provably lacks. Five subjects run concurrently in one image;
the image snapshots itself from the middle of all of them; the original is
**killed**; the saved image is restarted. Every trace line carries a wall-clock
stamp and is appended, so any line after the original's last stamp was written by
the restored image.

**It works on both, and it is exact.**

| subject | at snapshot | Pharo after restore | Squeak after restore |
|---|---|---|---|
| **A** — counted loop, stack-local accumulator, `Delay`-driven | Pharo `step=33`, Squeak `step=35` | resumed `sum=561`, ran to `sum=7140` | resumed `sum=630`, ran to `sum=8515` |
| **E** — 13-deep recursive chain, marker pinned per frame | mid-descent | all 13 frames unwound, markers `0…84` | all 13 frames unwound, markers `0…84` |
| **B** — blocked on a `Semaphore` | — | `took=6` → `took=21` | → `took=21` |
| **MAIN** — the script's own process | at the `snapshot:` send | resumed on the next statement | resumed on the next statement |
| **S** — listening server | serving | **dead, and lied about it** | **came back by itself** |
| restore latency | — | 976 / 984 / 995 / 1010 ms | **477 / 489 / 510 / 458 ms** |
| determinism, 3 restores of one checkpoint | — | `A step=33 sum=561` ×3, 57 lines ×3 | `A step=35 sum=630` ×3, 64 lines ×3 |

The accumulators are arithmetically exact — `sum(1..35) = 630`,
`sum(1..130) = 8515` — and they live *only* on their process's stack, so a
process rebuilt from scratch could not produce them. Subject E is the stronger
proof: frames entered **before** the snapshot returned their own locals **after**
the restore. The whole stack is the object, not just its top.

For contrast, SBCL's behaviour is on record in B6: a core taken mid-loop at step 5
restores with `counter=5` and enters `:toplevel`.

### Failure modes — what "fragile in practice" actually looks like

Not fragile. But not free, and the list grew when the second substrate was added.

1. **Pharo: an unregistered listening socket comes back dead and lies about it.**
   `ZnServer on: 8952` restores reporting `isRunning: true` and
   `isListening: false`; `curl` gets connection-refused; `ZnServer managedServers`
   is empty, so nothing restarted it. An explicit `start` fixes it at once.
   `ZnServer startDefaultOn:` registers, and *that* one is re-created by the
   session manager and answers normally after restore.
2. **Squeak: the same server came back by itself with no registration step.**
   The restored image answered `hits=1`, `hits=2` — counter correctly back at its
   snapshot value. File descriptors cannot be serialised on any substrate; what
   these images have is a hook that *re-creates* them, and Squeak's `WebServer`
   arranges it by default where Pharo's `ZnServer on:` does not.
3. **A file stream held open across the snapshot comes back closed.** In the
   restored image `closed` is `true` and writing raises `FileWriteError`. Loud,
   therefore much safer than (1).
4. **Restarting a saved Pharo image with no subcommand kills it.** The default
   command line handler prints usage and quits about a second after the image has
   resumed — which looks exactly like resume not working. `--no-quit` is required.
5. **Squeak blocks forever when an agent installs a method.** `compile:` in a
   headless image hangs with no error and no output: it is waiting on the
   author-initials dialog. `Utilities authorInitials: '…'` first, and it compiles
   fine. This is squarely on the path B7 cares about — a harness whose agent
   defines methods at runtime deadlocks on its first write until someone knows
   this.

None of these impugns the mechanism. (1) and (5) are reasons to distrust a
Smalltalk image's self-report, which for a harness that lets an agent inspect its
own world is a genuine cost.

---

## M3 — Tool schema derived from a live method

viva's load-bearing claim: a tool's schema is read off the running function —
argument names from the lambda list, arity kinds from its structure, types from
the compiler, description from the docstring. Subject is a method **compiled at
runtime**, because that is the case that matters: an agent that defines a method
has thereby written a tool.

```smalltalk
orderTotal: lineItems tax: taxRate
	"Total a list of line items and apply a tax rate."
	^ (lineItems inject: 0 into: [ :a :b | a + b ]) * (1 + taxRate)
```

| schema input | SBCL, off the live function | Smalltalk, off the live method |
|---|---|---|
| argument names | `(LINE-ITEMS &KEY (TAX 0.0))` | `selector keywords` → `('orderTotal' 'tax')`; source-derived names → `(lineItems taxRate)` |
| arity kinds | required / `&optional` / `&key`, **with defaults** | none exist — every argument required and positional |
| argument types | `T` unless declared | nothing, at all |
| return type | `NUMBER`, derived with no declarations | nothing |
| description | docstring | method comment |

**Selector keywords are the wrong names.** In `orderTotal: lineItems tax: taxRate`
the first keyword, `orderTotal:`, names the **operation**, not the first argument.
Deriving parameter names from `selector keywords` yields
`{"orderTotal": …, "tax": …}` — where `orderTotal` is supposed to identify a list
of line items. Smalltalk keywords are chosen to read well at the *call site*, and
that is a different job from naming a parameter.

**And the usable names are not in the image. This is the Smalltalk source model,
not a Pharo packaging choice** — the second substrate was added specifically to
test that, and it reproduces exactly. Same image, `.changes` moved aside, method
still live:

| | Pharo, with `.changes` | Pharo, without | Squeak, with | Squeak, without |
|---|---|---|---|---|
| argument names | `#(#lineItems #taxRate)` | `#(#arg1 #arg2)` | `('lineItems' 'taxRate')` | `('t1' 't2')` |
| comment | the docstring | `nil` | the docstring | `nil` |
| source | as written | decompiled | as written | decompiled |
| **runs** | `42.0` | `42.0` | `42.0` | `42.0` |

The behaviour is entirely in the image. **Two of the four schema inputs are not.**
`sourcePointer` is an offset into a separate `.changes` file. An image shipped on
its own can only produce `orderTotal_tax_(arg1, arg2)` with no description — and
each dialect invents different placeholder names, which is a nice illustration
that nothing real is being recovered.

The SBCL control ([probes/smalltalk-p3-sbcl-comparison.lisp](probes/smalltalk-p3-sbcl-comparison.lisp))
is the same shape and comes out the other way: a function defined at runtime from
a string, no source file ever created, saved into a core, and run in a process
with the source deleted still reports `lambda-list (LINE-ITEMS &KEY (TAX 0.0))`,
its docstring, and `42.0`.

**Verdict: worse, and structurally so.** Fewer inputs, one of the two name
sources semantically wrong, and both good ones outside the artifact.

### But this is a weaker objection than it first looked

The first write-up treated M3 as a substrate defect. On reflection that
over-reaches, because the requirement it fails is one no substrate should be asked
to meet: *reconstruct your semantic source representation from bytecode alone.*
Nothing should be designed that way. Source identity belongs in the agent's
durable state, and installation should run **ledger → source/AST → compile →
method**, never **method → reverse-engineer source**.

viva already has that ledger. So the honest statement is not "Smalltalk cannot
carry a derived schema" but:

> **A Smalltalk image is not self-sufficient as source-level memory.**

Which is true, and which the ledger already answers — the same conclusion B6
reached from the other direction. The ledger stops being optional insurance
against image rot and becomes load-bearing, but it exists either way.

What survives as a real residual is narrower, and it is not really a reflection
deficiency at all — it is a **write-path integrity problem**. On SBCL the image
cannot drift from its own description. On Smalltalk there are two ways to modify
the running system:

```
                  self-modification
                          │
             ┌────────────┴────────────┐
        ledger path                bypass path
             │                          │
    source, provenance,          executable, and
    history, validation          partly unknowable
```

Anything down the bypass path — a package load, or an agent reaching for the
image's own `compile:` — silently produces a method whose derived schema is
`(arg1, arg2)` with no description. The failure is not that the names are missing;
it is that **nothing reports them missing**.

So the fix is not better reflection. It is an invariant: *all persistent
self-modification is transactional through the ledger* — propose, append, compile
candidate, validate, evaluate, install, record promotion — after which a direct
`compile:` is architecturally forbidden in the way that writing directly into a
database's storage files is forbidden. Technically possible, never done.

That unifies this with M5's silent-semantic class under one heading, **mutation
observability**, and it is a constraint viva can enforce rather than a defect
it would have to live with.

**One correction to viva's own claim, found while building the control.**
`derive.lisp`'s header said SBCL yields `(FUNCTION (LIST &KEY (:TAX SINGLE-FLOAT) …))`
"with no help". Measured on 2.6.7, on both the `eval` and `compile-file` paths, it
yields `(FUNCTION (T &KEY (:TAX T)) (VALUES NUMBER &OPTIONAL))` — return type
derived, argument types `T`. `json-type` maps that to "any" and `build-parameters`
refuses to guess, so nothing downstream is wrong; the comment overstated the
input, and is now fixed. Types are the weakest input on both substrates. The
claim rests on **names, arity kinds and the docstring** — precisely the set SBCL
keeps in the image and Smalltalk keeps in a side file.

---

## M4 — Can a Smalltalk image fork, so the child writes the snapshot?

M1's real finding was that the difference is fork versus stop-the-world. So: does
`fork()` work from inside a Smalltalk image?

The danger is not the green `Process`es — those are objects in the heap. It is the
VM underneath: a heartbeat thread, a kqueue-based aio loop, sockets, a JIT code
zone. `fork()` from a multithreaded process leaves the child holding locks whose
owner threads no longer exist. So this does not fork once while idle. It forks
repeatedly while the image is doing everything that could break it — serving real
traffic, churning the heap, ping-ponging semaphores, writing files, and compiling
methods — and then checks that every child's image actually restarts.

Measured on Pharo, because **Squeak 6.1's base image has no FFI at all** — no
`ExternalLibraryFunction`, no `Alien`, no FFI plugin loaded — so `fork` is not
reachable without loading packages. Pharo has uFFI in base, and pays the Rosetta
penalty, which makes these stall numbers *pessimistic*.

```smalltalk
cls class compile: 'forkNow ^ self ffiCall: #( long fork ( void ) ) module: LibC'.
pid := cls forkNow.
pid = 0 ifTrue: [ "child" Smalltalk saveAs: 'p4-fork-', i printString. ... quit ]
        ifFalse: [ "parent" keep serving ]
```

| | run A, 5 forks | run B, 10 forks |
|---|---|---|
| **parent stall per fork** | **50, 19, 19, 18, 18 ms** | **60, 45, 29, 26, 63, 54, 75, 56, 21, 28 ms** |
| requests started / finished | 752 / 744 | **827 / 827** |
| **in-flight lost** | **0** | **0** |
| latency across the fork, p50 / max | 305.9 / **307.5 ms** (baseline max 490.5) | — |
| worst completion gap | 324.8 ms, **17.0 s after the first fork** | — |
| concurrent GC churn iterations | 3,556 | 5,116 |
| semaphore handoffs | 2,944 | 4,273 |
| file writes | 2,043 | 2,945 |
| **methods compiled during the forks** | 1,672 | 2,383 |
| children producing a valid image | 5 / 5 | 10 / 10 |

**The fork is invisible to clients.** Latency across the first fork peaked at
307.5 ms against a baseline maximum of 490.5 ms — the fork did not even produce
the worst gap of the run, which happened 17 seconds later and was ordinary jitter.
Compare M1's stop-the-world numbers, where the pause *was* the worst gap by
construction.

**Every child's image restarts, resumes, and serves.** All five images from run A
answered HTTP on the restored image's re-created listener. And they resumed
*computation*, not just sockets — each restored image reported the counters as of
its own fork, then kept incrementing:

| restored image | counters at t0 | at t+2 s |
|---|---|---|
| `p4-fork-1` | churn 1,879 / compiles 880 | churn 2,116 / compiles 998 |
| `p4-fork-5` | churn 3,334 / compiles 1,549 | churn 3,564 / compiles 1,663 |
| `p4-fork-10` | churn 4,977 / compiles 2,281 | churn 5,205 / compiles 2,396 |

(parent's totals at the end of the run: churn 5,116, compiles 2,383)

The checkpoint values rise monotonically with fork index, exactly tracking when
each fork happened, and every one is live afterwards. **This is SBCL's
availability model with Smalltalk's continuation-preserving checkpoint.**

**One VM-level complaint, and it is the child's.** The forked children's inherited
aio loop logs `kevent: Bad file descriptor` — 469 lines across run A, on the
shared stderr. The parent's serving was measurably unaffected (744/744, normal
latency), and every restored image logs **zero** such errors. The child finds the
inherited kqueue descriptor invalid, complains, saves, and exits; nothing that
survives the fork carries the damage.

### What this does and does not establish

It does **not** establish that forking a Smalltalk VM is generally safe. It
establishes that *this* Pharo/OpenSmalltalk configuration survived hostile forks
and produced valid resumable images. The distinction is the whole point of the
`kevent` evidence: after `fork()` only the calling OS thread survives, so the
child holds inherited mutex state whose owners are gone, an inherited kqueue
descriptor that is no longer valid, and no heartbeat thread. A child that tried to
*live* in that state would be on very thin ice.

The child does not try to live. It writes an image and dies. So the claim is:

> **fork-and-immediately-checkpoint appears viable.**

Not: *forked Pharo processes are safe general-purpose runtime clones.* The narrow
primitive is all viva would need, and it is the only one measured.

Two limits stand. This is Pharo-only, because base Squeak cannot reach `fork`.
And the child originally returned through `quitPrimitive`, letting the VM's normal
shutdown machinery try to tidy resources it inherited but does not own — which is
exactly the code most likely to touch a lock whose owner thread no longer exists.
Probe 4b closes both gaps it can: the child now calls `_exit` directly, and the
sample is large enough to catch a rare failure.

### Probe 4b — the soak, with the child calling `_exit`

Same hostile activity plus a forced full GC every 900 ms so forks land during
collection, and the child's path between `fork()` and death reduced to
`saveAs:` followed by a raw `_exit`. `saveAs:` is deliberately kept rather than
dropping to the bare snapshot primitive: the session shutdown/startup hooks it
runs are what re-create sockets on resume, and an image that cannot restore is
worth nothing however fast it was written.

250 forks, spaced 200 ms instead of M4's 3 s — deliberately faster than anything
sane, to find where the primitive bends.

| | |
|---|---|
| forks | 250 |
| **fork failures** | **0** |
| requests started / finished | 3,134 / **3,134** |
| **requests lost** | **0** |
| parent stall: min / p50 | 30 ms / **62 ms** |
| parent stall: p90 / p99 / max | 597 ms / 2,723 ms / **6,405 ms** |
| stalls over 200 ms | 45 of 250 (18%) |
| concurrent: forced full GCs | 183 |
| heap churn / semaphore handoffs / file writes | 3,685 / 3,421 / 1,720 |
| client latency p50 / max | 487 ms / 5,100 ms |

**The mechanism never failed.** Nothing was lost, no fork returned an error, every
image sampled restores. But the parent's stall tail goes from M4's 75 ms maximum
to 6.4 s at p99+, while the median holds at 62 ms.

The obvious reading is that 5 Hz saturates disk with nine concurrent 60 MB writers
and M4's clean numbers came from 3 s spacing. **Probe 4c tested that and it is not
what the data says** — see below. The honest statement from 4b alone is narrower:
*the median fork stall is small and the tail is not, and 4b does not establish
why.*

**`_exit` is safe.** The images the `_exit` children wrote are valid, boot, carry
their checkpoint state (`churn=3719`), restore their listener
(`running=true listening=true` on 8973), and serve a real HTTP round-trip from
inside the restored image:

```
'HTTP round-trip against the restored image: id=5 churn=3745'
```

That is worth stating plainly because the hardening could have gone the other way:
`_exit` skips atexit handlers and stdio flushing, so a buffered image write would
have been truncated by it. It is not.

### Probe 4c — the saturation curve

5 Hz is not a failure case, it is a point on a curve, and the number a harness
actually needs is *the maximum sustained checkpoint frequency below a latency
budget*. Sweeping the spacing, same hostile load throughout:

| spacing | forks | p50 | p90 | p99\* | max | >200 ms | client p99 |
|---|---|---|---|---|---|---|---|
| 3000 ms | 40 | 102 | 961 | 4828 | 4828 | 8 | 3912 |
| 1500 ms | 50 | 120 | 387 | 17348 | 17348 | 12 | 4140 |
| 750 ms | 60 | **56** | 206 | 1299 | 1299 | 6 | 1885 |
| 375 ms | 80 | 142 | 383 | 2822 | 2822 | 20 | 1557 |

\* `p99 == max` in every row, which is the tell: at n = 40–80 the "p99" *is* the
single worst sample. These are not distribution estimates.

**There is no curve here, and the hypothesis it was built to test is wrong.** The
relationship is non-monotonic — the *slowest* checkpoint rate has the second-worst
tail, the second-fastest has the best. Re-running the 3000 ms configuration later
gave `p50 92 / p90 265 / max 560` with the forced GC and `p50 87 / p90 163 /
max 440` without it: an order of magnitude below the same configuration's 4828 ms
in the sweep.

So the seconds-scale outliers are **not caused by checkpoint rate**, are not
reproducible at a fixed configuration, and are most consistent with machine-level
noise on a contended host. The forced full GC that 4b/4c added and M4 lacked
accounts for part of the *sub-second* tail (p90 265 → 163 with it removed) and
nothing like the multi-second events.

What survives, and it is less than the previous draft of this section claimed:

- **nothing ever failed** — 0 fork failures and 0 lost requests across 475 forks.
  This is the load-bearing result, and it does not depend on any timing.
- **the observed stall is small at the median** — 56–142 ms across 375–3000 ms
  spacing. But this is not a measurement of `fork()`. An in-image timer brackets
  `t0 → fork() → t1` with a *green thread*, so what it records is
  `fork latency + scheduler delay + unrelated descheduling + measurement
  interference`. Treat even the median as an upper bound of unknown tightness.
- **the tail is unattributed.** Resolving it needs a quiet host, n in the
  thousands, and an out-of-image clock.

M4's 18–75 ms should be read the same way: n = 15, on a quieter machine. So should
SBCL's 29.6–36.0 ms, which is n = 3. Both substrates' fork-stall figures are
small-sample, and **the same order of magnitude is the maximum justified
comparative claim** — not a ranking, and not a distribution.

**The right instrument, if this ever needs settling.** Not a bigger version of the
same benchmark; a different one. Move the clock outside the image: an external
observer driving a high-frequency request stream with monotonic timestamps, joined
against the fork sequence number, the child's checkpoint start and finish, the
count of children writing concurrently, RSS and memory pressure, swap activity,
disk throughput, full-GC timestamps, CPU utilisation and throttling state. And
**randomise the spacing order** across `{375, 750, 1500, 3000}` rather than
sweeping monotonically, so machine-state drift cannot masquerade as a rate effect
— which, on this evidence, is exactly what it did.

The engineering advice below is design judgement rather than a measured result,
and is worth keeping for that reason alone — the right mental model is not
"checkpointing is free" but **checkpointing is a resource with backpressure**:

```
        want a checkpoint
               │
      checkpoint scheduler
               │
    previous writer finished?
        ├─ no  → defer or coalesce
        └─ yes → fork → write image → _exit
```

A scheduler that refuses to fork while a previous child is still writing bounds
concurrent writers regardless of what the requested rate is, which is almost
always the trade a serving system wants. None of that is exotic; it is the same
shape as any write-behind cache. What this probe does **not** supply is the number
to configure it with — that was the point of 4c and 4c did not deliver it.

---

## M5 — Does the image assume a human is sitting in it?

The author-initials hang found in M2 is not about author initials. It is evidence
that a Smalltalk development image blurs application, runtime, IDE and user in a
way that is wonderful interactively and hostile to an agent: the runtime decides
human input is required, puts up a modal dialog, and the agent hangs forever with
no exception to catch and nothing to log. The criterion is not "does it support
headless" but **every runtime failure must become data or control flow the agent
can reach**.

Fifteen operations, each classified `OK`, `RAISED` (an exception the agent caught
— also fine, it is data), or `BLOCKED`. Blocking is detected from outside by a
watchdog, because from inside the image there is by definition nothing left to
run; the suite then restarts past the blocker so one hang cannot hide the rest.
Squeak 6.1, native ARM64:

| operation | verdict |
|---|---|
| create a class | OK |
| **compile a method, image as it ships** | **BLOCKED — waiting on the author-initials dialog** |
| set author initials | OK |
| compile a method, author set | OK |
| **compile malformed source** | RAISED `SyntaxErrorNotification` — catchable |
| compile a method referencing an undeclared variable | OK — *silently* |
| rename a class | OK |
| change a superclass | OK |
| remove a class | OK |
| unhandled `Error` in a forked process | OK — main process keeps scheduling |
| `halt` in a forked process | OK — main process keeps scheduling |
| evaluate an undeclared variable | RAISED `MessageNotUnderstood` |
| connect to a closed port | RAISED `ConnectionRefused` |
| bind an already-bound port | OK — *silently* |
| allocate a 400 M-element array | OK — allocated |

**Exactly one blocking hazard in fifteen**, and it is a one-line fix
(`Utilities authorInitials: '…'`). Everything else is either fine or raises
something catchable. Notably a debugger in one green process does **not** freeze
the image — the main process kept scheduling in both the unhandled-exception and
`halt` cases.

Pharo does better still. Spot-checking the three compile operations: valid method
**OK** with no author set, malformed source **RAISED `OCCodeError`**, undeclared
variable **OK**. **No blocking hazard at all** — Pharo's investment in
non-interactive operation shows up exactly here.

**Two quiet hazards matter more than the loud one.** Both dialects compile a
method referencing an undeclared variable *silently*, so an agent's typo installs
clean and fails later at runtime; and Squeak binding an already-bound port
returned success instead of raising. Neither hangs. Both are failures that did not
become data — the same criterion failing in a quieter way, and much harder to
audit for.

So the audit really sorts into three classes, and the third is the one that
matters for a self-improving system:

| class | example | what the agent does |
|---|---|---|
| **blocking** | author-initials dialog | freezes; nothing to catch, nothing to log |
| **explicit** | `SyntaxErrorNotification`, `ConnectionRefused` | catches it and recovers |
| **silent semantic** | undeclared variable accepted; port bound twice | believes the change succeeded, and corrupts itself |

Blocking is the loud failure and the easy one — a watchdog finds it, and the fix
was one message send. **Silent semantic failure is the dangerous one**: the agent
mutates itself incorrectly and the substrate returns success. That suggests a
metric this probe did not set out to produce and should have —

> **mutation observability**: when the agent changes itself incorrectly, how
> reliably does the substrate turn that mistake into observable evidence?

which is arguably more important than headless autonomy, and which neither
substrate has been measured on. Note what it does *not* imply: better live
mutation mechanics do not remove the need for validation, provenance, rollback,
evaluation and selection. viva's evaluator earns its place on either
substrate; Smalltalk changes how mutations are *applied*, not whether they need
to be *judged*.

The blocking hazard, then, is a footnote. The interactive assumptions are real but
shallow and enumerable — this audit found the whole set in one pass.

---

## Recommendation

**B7 no longer identifies an execution-model reason to reject Smalltalk.** Native
Smalltalk snapshots efficiently; exact continuation survives restoration; and
fork-and-snapshot experimentally provides SBCL-class serving availability *while*
preserving control flow. The remaining differences are about source-level
reproducibility, tool-schema representation, instrument continuity, and one open
empirical question that this probe cannot answer.

Scoring the story's kill criterion after M4:

- *"Pharo's snapshot pause under load is no better than SBCL's"* — **no longer
  fires.** Stop-the-world it is 214 ms native against SBCL's 30 ms; forked at a
  sustainable rate it is **18–75 ms against 30–36 ms**, under load, on the slower
  architecture. The first pass called this disqualifying on a number that was
  mostly Rosetta; the second called it weak; it is now absent — with the caveat
  that the rate has to be budgeted, which M4b measures.
- *"resume-mid-computation is fragile in practice"* — **does not fire.** Exact and
  deterministic on both dialects, and it survives the fork path.

What that supports, at the width the evidence bears: for the checkpoint semantics
tested here, Smalltalk **matches** SBCL's low-pause approach and adds control-flow
preservation. Not a general claim of dominance — the two differ on other axes, and
M3 is one of them. What remains:

1. **M3, restated.** A Smalltalk image is not self-sufficient as source-level
   memory. That is real, but the ledger already answers it, and no substrate
   should be asked to reconstruct source from bytecode. The residual is narrower:
   anything installed outside the ledger path degrades silently.
2. **Nothing currently open needs control-flow resume.** Trials are ephemeral by
   design (fork, score, `_exit`); E4's self-edits need to survive a turn, not a
   process death. Smalltalk's advantage is genuine and currently unbought — a
   reason to wait, not to refuse.
3. **Instrument continuity**, which is a cost of switching, not an argument that
   switching is wrong.
4. **The question this probe cannot answer**, and the one that now matters most:
   *does preserving live cognition make the agent better?* See below.

M5 is deliberately not on that list: one blocking hazard in fifteen operations,
fixed by a single message send, and none at all on Pharo. What M5 *does* add is
the silent-semantic-failure class and the mutation-observability metric, which
apply to both substrates and neither has been measured on.

**So: stay on SBCL, and stop citing the runtime as the reason.** Items 2 and 3
are reasons to wait rather than reasons Smalltalk is wrong, and item 1 is
answered by machinery viva already has. The decision now hangs on item 4,
which is an experiment rather than an argument.

The whole investigation, in one paragraph:

> **Smalltalk survived every operational objection that initially looked likely to
> disqualify it.** Native ARM64 works. Continuation-preserving snapshots work.
> Fork-and-immediately-checkpoint appears viable. Serving continues through it.
> Restored checkpoints are executable. Headless hazards are manageable. The
> remaining question is not whether Smalltalk *can* support viva, but whether
> preserving implicit computational state improves agent outcomes enough to
> justify abandoning an already-measured SBCL instrument.

Stated so it can be attacked — which the previous version could not be:

> **The rational reason to remain on SBCL is evidence continuity and lower
> migration cost, not a demonstrated Smalltalk deficiency.**

The argument this probe started with was *SBCL is operationally superior,
therefore remain*. The measurements killed that. What replaced it is falsifiable:
B10 either finds that native continuation beats explicit continuation, which is a
migration trigger, or it does not, in which case the project has learned something
more general than a substrate preference.

And the runtime question has largely collapsed into a **representation** question:
*must in-flight cognition exist as control flow, or is representing it explicitly
as data sufficient?* That is what B10 asks, and it is answerable on SBCL alone.

Three things this sends back:

- **B6's `kills_it` tests the wrong quantity.** "The ~400 ms fork-and-save pause"
  is not a pause; the pause is ~30 ms. B6 is much further from firing than it reads.
- **B6's GENOME/CORE trap is the same finding as M3, from the other direction.**
  The source an agent installs does not live in the artifact; it lives in
  `.changes`. That makes the per-definition ledger load-bearing on Smalltalk
  rather than optional — but it is machinery this project already built, which is
  why M3 is a constraint to design around rather than a disqualification.
- **The fork technique is substrate-independent** and viva already owns it.
  That is the transferable result of this probe regardless of which substrate wins.
- **Mutation observability outgrew this probe** and is now [B9](../backlog.toml).
  M3 and M5 found the same defect in two places, and it is not a Smalltalk
  property: the dangerous operation is not code generation, it is **unobserved
  state transition** — code, memory, schema, learned policy, tool registration,
  prompt, capability installation. All of it needs the one transactional write
  path, on either substrate.

---

## The trigger

What specific result would make switching correct.

**Necessary, and now measurable — continuation persistence has to improve
outcomes.** B7 has very nearly finished proving Smalltalk *can* preserve live
computation. It has not shown that the capability makes an agent better, and that
is the difference between an elegant runtime property and an agent capability. The
experiment is a clean A/B, one variable:

```
same task set, same model, same budget
  A  EXPLICIT CONTINUATION   goal, plan, current step, observations,
                             partial result, pending tools, hypotheses,
                             evaluator state, continuation tag
                             → restore → dispatch → continue
  B  NATIVE CONTINUATION     stack, frame, locals, green process,
                             instruction position → resume
```

**Success rate is not the outcome; a vector is** — because the interesting result
is `success(A) ≈ success(B)` with tokens, tool calls, wall time, repeated steps,
state size and harness complexity all worse for A. The headline metric is
**reconstruction tax**: work done after restore that merely recreates information
or computation that existed before the checkpoint. If a good explicit-state design
drives that to ~zero, SBCL wins the architectural argument outright.

Filed as its own story ([B10](../backlog.toml)) rather than left in this probe,
because it needs the task set and a scored loop that B7's terms of reference
excluded — and because it outgrew the substrate question. There are two
philosophies of persistent agents, not two implementations:

| | |
|---|---|
| **persistence by state-machine design** | computation → explicit state → checkpoint → new process → transition continues. Erlang, Temporal, durable execution, LangGraph-style checkpointing, actor persistence. |
| **persistence by computational capture** | computation itself → capture → restore → same computation continues. Smalltalk. |
| **persistence by supervised replacement** | process dies → supervisor starts a replacement → it continues from explicit state held elsewhere. BEAM, probed by [B8](../backlog.toml). Not a third arm of B10, and worth stating precisely: BEAM is an existence proof of *supervised replacement around* explicit state, **not of durable state itself** — process state is volatile across node death and durability needs Mnesia or another external store. It supplies the replacement half of arm A2 and leaves the durable half in the ledger. |

Essentially every modern agent system has chosen the first and converts control
flow into explicit durable state as a matter of course. Nobody appears to have
measured what that conversion *costs*, because on the usual substrates the second
option does not exist. B7 established that it does exist and is operationally
affordable, which is what makes the question askable at all. So the runtime
question has largely collapsed into a representation question: **must in-flight
cognition exist as control flow, or is representing it explicitly as data
sufficient?**

An adjacent form of the same trigger, if it arrives first: an experiment whose
subject is *an agent turn that outlives its process* — checkpoint mid-tool-call,
resume elsewhere, migrate a running turn. Nothing open needs it. If a story ever
states it, SBCL cannot do it and M2 shows Smalltalk does it exactly.

**Withdrawn: the availability trigger.** The first pass set this at "a native ARM64
VM measuring a stop-the-world snapshot under ~50 ms". M4 met the underlying test
by a different route: forked, the parent stalls 18–75 ms against SBCL's 30–36 ms,
under load, on the slower architecture. There is nothing left to trigger. The
remaining work on this axis is hardening, not deciding — a long-running fork soak,
and having the child `_exit` rather than trusting `quitPrimitive` in a forked VM.

**Sufficient — the schema stops being derived.** If E5's single-tool RLM wins and
the fixed tool schema goes away, M3 evaporates with it: there is no schema to
derive, so it does not matter that Smalltalk derives one badly. Watch
[E5](e5-single-tool-rlm.md). With M1 and M4 settled, **E5 winning would leave
instrument continuity as the only argument against switching** — which is a reason
to defer, not a reason to refuse. This is now the single most decision-relevant
open experiment in the project, for a reason that has nothing to do with E5's own
hypothesis.

**Sufficient — Smalltalk source moves into the image.** Tonel, or any scheme that
keeps method source and comments reachable from the image alone, and M3's
objection goes with it. Worth checking before assuming: the finding here is about
`.changes` and `sourcePointer`, not about what a package format could do. If both
this and E5 land, there is no technical argument left against Smalltalk.

**What would close the question permanently in viva's favour:** SBCL gaining
control-flow resume by representing in-flight work as *data* rather than as a
stack — which B6 already gestures at ("the no-threads constraint forced in-flight
work to be represented as DATA"). If that lands, Smalltalk's one genuine advantage
is gone and there is nothing left to weigh.

---

## Reproducing

| file | what it does |
|---|---|
| [probes/squeak-p1-snapshot-under-load.st](probes/squeak-p1-snapshot-under-load.st) | native-ARM64 control: WebServer, snapshots itself mid-traffic |
| [probes/squeak-p1-run.sh](probes/squeak-p1-run.sh) | drives M1 on Squeak |
| [probes/squeak-p2-resume.st](probes/squeak-p2-resume.st) | five concurrent subjects, snapshot from the middle |
| [probes/squeak-p2-run.sh](probes/squeak-p2-run.sh) | drives M2 on Squeak: run, snapshot, kill, restart |
| [probes/squeak-p3-schema.st](probes/squeak-p3-schema.st) | schema off a runtime-compiled method, with and without `.changes` |
| [probes/squeak-p5-autonomy.st](probes/squeak-p5-autonomy.st) | M5: fifteen operations, classified OK / RAISED / BLOCKED |
| [probes/squeak-p5-run.sh](probes/squeak-p5-run.sh) | drives M5, with the watchdog that detects a modal dialog from outside |
| [probes/smalltalk-p4-fork-snapshot.st](probes/smalltalk-p4-fork-snapshot.st) | M4: fork under traffic, heap churn, semaphores, file I/O and method compilation |
| [probes/smalltalk-p4-run.sh](probes/smalltalk-p4-run.sh) | drives M4 |
| [probes/smalltalk-p4b-fork-soak.st](probes/smalltalk-p4b-fork-soak.st) | M4b: the soak, child calls `_exit`, forced full GCs |
| [probes/smalltalk-p4b-run.sh](probes/smalltalk-p4b-run.sh) | drives M4b |
| [probes/smalltalk-p4c-envelope.sh](probes/smalltalk-p4c-envelope.sh) | M4c: sweeps the checkpoint rate — the attempt that did not settle the tail |
| [probes/smalltalk-p1-snapshot-under-load.st](probes/smalltalk-p1-snapshot-under-load.st) | the Pharo/Zinc equivalent |
| [probes/smalltalk-p1-run.sh](probes/smalltalk-p1-run.sh) | drives M1 on Pharo |
| [probes/smalltalk-p1-analyse.py](probes/smalltalk-p1-analyse.py) | correlates client log with the snapshot window (both dialects) |
| [probes/smalltalk-load.py](probes/smalltalk-load.py) | external load generator (both dialects) |
| [probes/smalltalk-p1-sbcl-comparison.lisp](probes/smalltalk-p1-sbcl-comparison.lisp) | SBCL parent-stall control |
| [probes/smalltalk-p2-resume.st](probes/smalltalk-p2-resume.st) | the Pharo equivalent of M2 |
| [probes/smalltalk-p2-run.sh](probes/smalltalk-p2-run.sh) | drives M2 on Pharo |
| [probes/smalltalk-p3-schema.st](probes/smalltalk-p3-schema.st) | the Pharo equivalent of M3 |
| [probes/smalltalk-p3-sbcl-comparison.lisp](probes/smalltalk-p3-sbcl-comparison.lisp) | SBCL control: schema survives a core with no source |

Squeak, which is the one to start from — native ARM64, no workarounds:

```bash
curl -sSLO https://files.squeak.org/6.1/Squeak6.1-23976-64bit/Squeak6.1-23976-64bit.zip && unzip -q Squeak6.1-23976-64bit.zip
```

```bash
curl -sSLo cog.dmg https://github.com/OpenSmalltalk/opensmalltalk-vm/releases/download/202606270913/squeak.cog.spur_macos64ARMv8.dmg && hdiutil attach -nobrowse -quiet cog.dmg -mountpoint /tmp/m && cp -R /tmp/m/*.app ./cog.app && hdiutil detach -quiet /tmp/m && xattr -c cog.app/Contents/MacOS/Squeak
```

Pharo needs the x86_64 VM as well, since its ARM64 build will not start:

```bash
curl -sSLo vm-x64.zip http://files.pharo.org/get-files/130/pharo-vm-Darwin-x86_64-stable.zip && unzip -q vm-x64.zip -d vm-x64
```

All four `*-run.sh` scripts take `<image-dir> <probe-dir>`.
