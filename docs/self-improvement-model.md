# What vivarium is actually about

The project spent a long time asking which substrate best supports self-modification,
then a long time building an instrument that turned out to measure something else.
This is the model that survived both, and it is the reference the remaining
experiments are designed against.

## The human version, which is the clearest statement of it

> You do a task manually, notice repeated friction, and change your working
> environment so the next attempt is easier.

Writing a shell script is the canonical case:

```
first time     download, rename, extract, convert, copy, verify
               ...notice the repetition
               write process.sh
thereafter     ./process.sh input/
```

**The script does not improve the task. It improves the worker's capacity to do
that class of task.** That distinction is the whole subject.

An ordinary coding agent is a contractor with **amnesia and an immutable
toolbox**: struggle, solve, struggle again, solve again. An experienced engineer
accumulates — a helper, an alias, a checklist, a test, a Makefile target — and
the third task costs less than the first.

## Three activities the machinery cannot tell apart

In a live image all three are the same act: compile a definition in. A file-based
harness separates them by ceremony; an image does not separate them at all. So
the **experiment** has to.

```
1  IMPROVE THE TASK       "change the world I was asked to change"
                          REPAIR-QUOTES fixes 400 rows and is then useless.

2  IMPROVE SELF TO SOLVE  "I cannot do this efficiently with what I have,
   THE TASK                so build the capability now"
                          LIVE-DEPENDENTS, written mid-task and used to finish it.

3  IMPROVE SELF BECAUSE   "what happened here should change how I behave later"
   OF THE TASK
```

### And 3 splits in two, which matters

```
3a RETAIN    I created something useful while working. Keep it.
             The problem is SELECTION and INHERITANCE, not invention.

3b DISTILL   I solved it without creating anything reusable, but learned
             something worth turning into a capability afterwards.
             Nothing resembling the artifact existed during the task.
```

3b is the stronger form and the harder one:

```
"I spent forty minutes comparing logs by hand.
 Next time I should have a diff script."          <- 3b, formed after
"This is taking forever, I'll stop and write
 a script first."                                 <- 2, formed during
"That script worked well, it goes in ~/bin."      <- 3a, kept because it proved out
```

## REGISTER is not PERSIST

A correction worth keeping, because conflating these misattributes what is
missing:

```
REGISTER   make a capability usable NOW        self.lisp:register-tool
PERSIST    make a capability exist LATER       nothing implements this
```

A tool can be perfectly registered and disappear at the episode boundary.
Something can be persisted without ever having been dynamically registered.
`register-tool`'s absence from every scored run blocked a form of **case 2**, not
case 3. Case 3 additionally needs:

```
created capability -> should this survive? -> promote -> artifact/ledger
                   -> next episode inherits it
```

## Self-improvement is not synonymous with writing tools

The kinds are genuinely different, and an agent should be able to reach for any
of them:

| kind | the trigger | the artifact |
|---|---|---|
| **automation** | "I keep doing these five steps" | a script |
| **abstraction** | "I keep writing this computation" | a function |
| **knowledge** | "I learned something I should remember" | notes, memory |
| **procedure** | "I need a better way to approach this" | a checklist, a skill |
| **verification** | "I keep making this mistake" | a test, a lint rule |
| **environment** | "this workflow is harder than it needs to be" | harness or config change |
| **observability** | "I keep struggling to see what is happening" | tracing, an index |

E24 is the evidence that this list is not decoration. Its failure was a
**procedure** gap — *check whether a second table marks some data exempt* — and
no amount of abstraction or tooling supplies it.

## The 2×2 underneath

```
                  needed NOW                     useful LATER
during task       build a helper to unblock      notice and generalise
                  the current work  [2]          while working
after task        (mostly irrelevant)            reflect, distil, retain [3]
```

The interesting territory is **the diagonal**: needed now, so self-extend live and
succeed; then useful later, so select and inherit.

## Which gives HYBRID a precise definition

Not "live plus files". The lifecycle of an improvement:

```
experience difficulty
      |
   self-extend during work                    [2]
      |
   use the extension
      |
   observe whether it actually helped
      |
   retain / discard / generalise               [3a / 3b]
      |
   next episode
```

Externalisation is one possible inheritance mechanism at the bottom, not the
point. **The research object is the lifecycle, not whether the improvement is
encoded as a skill or a tool.**

## The experiment ladder

One experiment cannot measure all of this, which is what B15 was trying to do.

| | question | needs |
|---|---|---|
| **A — task improvement** | can the base agent solve tasks at all? | the existing benchmark; no self-improvement claim |
| **B — instrumental** | does it notice a capability gap, build the capability, activate it, and use it to finish? | `register-tool` or direct invocation. **Case 2** |
| **C — retention** | given a capability it built and used in B, does it choose to keep it, and does the kept capability help a later task with the same latent need? | persistence + context reset. **Case 3a** |
| **D — post-hoc learning** | on tasks that do *not* hand it a reusable helper, can it extract one afterwards? | a reflection/promotion phase, and the full menu: nothing, skill, abstraction, prompt, harness. **Case 3b** |

### Why "the improvement is the solution" is useful but not sufficient

A task whose best solution *is* a reusable capability tests `2 -> 3a` well,
because the capability has already proved itself. But it makes retention
artificially easy — *I just built X, X solved my problem, should I keep X?* — and
it cannot test whether an agent can extract an improvement from experience **when
the task did not hand it one**. That is D, and it is the more interesting result.

Run both. B first, because C and D depend on it.

## The one-line description this is converging on

> Give an agent the equivalent of a programmer's ability to write a script, make
> an alias, extract a helper, update a checklist, add a test, or change its
> workflow, when experience shows that doing so makes future work better.

The difference from an ordinary agent is not that vivarium can modify code. It is
that it can recognise **when the way it works should itself become an artifact of
what it has learned.**
