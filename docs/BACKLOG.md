# Backlog — governance residue

**Workable items moved to GitHub issues, which are now the single source of
truth**: https://github.com/tosinamuda/viva/issues — five sprint
milestones (walking-skeleton router → external tool registry → graduation
by reuse → MCP export → the harder-family eval) plus a triaged backlog.
See CONTRIBUTING.md for the rules.

This file keeps only what is NOT work: the ARMED tripwires (conditions that
convert to issues when they fire), the RECORDED non-levers, and the FUTURE
lane's revisit triggers. The completed KC6 record below is history, kept
because the receipts in it are cited by RESULTS.md and the amendments.

## NOW — KC6, the gate

The experiment is pre-registered (`experiments/kc6/PROTOCOL.md`), priced
(expected $1.78-$4.09 all-in, off-peak at measured cache behaviour), and
gated (`./experiments/kc6/preflight.sh`, green). **Budget: $7.00 hard,
metered by `budget.py` between runs; model pinned to `deepseek-v4-flash` by
a preflight gate that fails on any other value; scheduling off-peak
mandatory** (amendment 13). What remains is authoring and running.

- [x] Author the six families, five tasks each, hidden tests written against
      each task's specification before any arm runs — **all six frozen**,
      three-legged gate green on every task; f3, f4, f5 reconcile
      hand-computed answers against each check's independent derivation
      (f5's check builds the packages and walks operator positions itself).
      Held-out f5, f6 authored last, after the scored four were fixed.
      Grading is pristine-plus-outputs per the families README and each
      task's `graded` manifest
- [x] Fixed split and order committed (families/README.md): scored 1-4,
      held-out 5-6 authored last, battery order 3-1-4-2-6-5. Held out of
      pilots and authoring knowledge, NEVER out of the analysis: all six
      enter the battery and the primary n = 6 sign test (amendment 11)
- [ ] Pilot slice: pre-check 2 (non-collapse, A-never-evolve vs B within 5%
      wall / 2% tokens) and pre-check 4 (capability floor) on the bound three
      (families 3, 1, 4 — amendment 12)
- [ ] Fix the cost cap from the pilot measurement in RESULTS.md before run one
      (caps: 120M total / 9M miss for the battery, 20M pilot, 6,750 requests
      — re-tightened to the 225 design by amendment 12)
- [ ] The battery: 225 runs — A and C at 3 repeats on all six families, B at
      3 repeats on the bound three (3, 1, 4)
- [x] The runner: cell mode smoke-validated live; batch mode drives the
      truncation spend order (pilot with its $1.50 sub-cap, then A+C in
      battery order with the pre-check 3/4 checkpoint after the bound
      three's A cells, then B — whose cells the pilot already ran,
      amendment 14). AN is arm A plus a never-use policy, for pre-check 2.
      Idempotent: completed cells skip on re-invocation
- [x] **KC6 re-posed, run to completion**: checkpoint passed on the first
      honest attempt (door 100% creating-cells-resolving, floor cleared per
      family), 54 cells, 270 task-runs, $3.50 total
- [x] RESULTS.md verdict, decision rule verbatim: **KILL CRITERION SIX
      FIRED** — 0/6 families favored A, door genuinely used (47 minted, 10
      promoted) and 1.9x the cost of text; arm-B control failed; scope
      stated. The Elixir/external question reopens with data — a
      manifesto-rank decision, the user's

### The six families

Every one is a friction this repository's own development actually produced —
the commits show them happening before anyone chose them as tasks, which is
what makes them cheap to author honestly and hard to rig.

| # | family | the receipt |
|---|--------|-------------|
| 1 | paren balance in a Lisp edit | broken twice in one session; fixed only when a probe printed depth per line |
| 2 | usage totals out of JSONL transcripts | the same parse written four separate times (harness count, cost scripts, live measurements) |
| 3 | what tools an agent actually SEES | answerable only through the real constructor — reading the code said nine tools were fourteen |
| 4 | TLC output → holds or violates | needed a config-to-expectation table before thirteen configs could be one command (`spec/verify.sh`) |
| 5 | a symbol's definition and callers across packages | repeated grep archaeology; the `call-component`-has-no-caller finding took three searches |
| 6 | a version id out of tool prose | the first test parsed the word `version` instead of the number and activated NIL |

## THROUGH THE DOOR MEANWHILE — one item, by ratified rule

- [ ] **RECONCILE** — the open stage of the component lifecycle: a co-effect
      ledger and compensation semantics, repairing what a reverted version
      already did. Mission clause, not feature. Spec first, TLC second, table
      third, wiring last. Spec obligation, from review: model a compensation
      that FAILS PARTWAY — a ledger whose repairs are assumed atomic repeats
      the exact comfort the Cordis probe rejected.

## BEHIND THE GATE, in order

- [x] **Retention policy (Level 3) — v1 BUILT and validated live.** The
      harness owns WHEN (always-reflect at task end, bounded), reflection
      owns WHAT, retention through existing doors only
      (src/workspace/reflection.lisp, docs/retention-policy.md). Beats the
      spontaneity-null baseline on both channels: text active on f1, and on
      f2 the door's first unforced promotion — 4 created, 3 resolved, 1
      promoted, instrumentality thresholds passed. **v2 ratified in design
      (docs/retention-policy.md): three tiers — future-prompt skill,
      code-carrying skill, registered tool — with graduation to the door
      only on demonstrated reuse.** Build is the next mechanism work; it
      repairs exactly what the kill measured (premature tier-3
      registration) and narrows the live-image question to mid-task
      graduation and composition.
- [ ] **Retention v2 build — the next mechanism work.** The three-tier
      router in the reflection prompt; tier-2 code-skills as the default
      code retention; tier 3 as EXTERNAL script tools and MCP servers in
      any language (bash/python/lisp), registry on disk, lifecycle laws
      carried over; graduation wired to ledger-counted reuse. Plus the
      externalization pass: skills as markdown (exists), memory files
      (exists), AGENTS.md read as an instruction source alongside them.
- [ ] **Attachments** — the placeless-organism contract: explicit named
      working-set lists, no ambient inheritance, grants dying with the task,
      siblings isolated. Ratified as design in the manifesto; not yet
      mechanism.
- [ ] **Peer messaging (TaskTree v2)** — laws already writable: tree-minted
      identities both ends, delivery only between live tasks, refusal with
      reason otherwise, immutable payloads, bounded inboxes with declared
      overflow, terminal tasks receive nothing. Spec is the entry artifact,
      and one decision is made THERE, not discovered in wiring: whether a
      draining parent still receives. Review's answer, adopted as the spec's
      starting position: yes — draining is live. Carve-out ruled on: gate
      first, no spec work during KC6; the one exception is a multi-day
      external stall, entered by an explicit lane-move commit.
- [ ] **Learning policy** — the mission's second clause is PARTIAL: skills
      and memory exist, nothing decides when to write one. Same shape as the
      retention policy, one level down; likely the same artifact family.
- [ ] **Harder families — the Level 3 retention-policy evaluation**
      (re-filed here by amendment 16, condition 6): task families where
      direct solving is expensive enough that investment is rational within
      five tasks, measuring SPONTANEOUS retention against the KC6
      spontaneity-null baseline. Triggered only if invited mode shows the
      mechanism earns a policy. Not a KC6 confirmatory — a policy-less
      model may decline expensive tasks too, and tuning cost until
      investment appears would author the answer key by another route.

## FUTURE WORK — parked by the kill, user-ratified

- **Self-editing code / live in-image compile** — the door as retention
  lost 0/6 with the mechanism genuinely used; its narrowed residual claim
  (mid-task graduation, tool composition) waits for graduation data to make
  tier 3 load-bearing. The proven lifecycle survives and governs external
  tools instead.
- **Tools as components** — subsumed: with tier 3 external, the organism's
  own tools becoming versioned artifacts is the same registry, not a
  special door.
- **Multiplexer frontend** — a surface over viva's typed streams,
  steering, and retention: the behaviors a PTY multiplexer cannot offer.
  Product-rank; revisit when the ecosystem ships its session layer.

## ARMED — tripwires, not work items until they fire

- [ ] `extra-tools` third loss ⇒ the context-object refactor is mandatory,
      one object threaded whole. Two losses so far (build-agent, sub-agent),
      both seams pinned by tests.
- [ ] Suite-deadlock tripwire fires ⇒ the two locks in the holder's frame get
      a small lock-order model — reviewer's addendum, adopted: lock ordering
      in the mechanics is the one concurrency class TLC has never been
      pointed at here, deliberately. Incident record: one occurrence, nine
      threads on one mutex, 16 instrumented hunt rounds + ~14 clean runs, no
      reproduction; tripwire self-diagnoses with every thread's backtrace,
      exit 99.
- [ ] A witness config stops violating ⇒ `spec/verify.sh` already fails on
      it; treat as evidence rot, not as a pass.
- [ ] Anything mutates a request's prompt prefix per-request ⇒ the measured
      82–91% within-run cache hit rate breaks and the battery price triples.

## HYGIENE — user actions, standing. Outranks family one in urgency, not lane

- [ ] **Rotate the credentials pasted in the earlier session** — DeepSeek API
      key, AWS keys, Bedrock token. They went only into gitignored `.env`,
      but pasted is pasted.
- [ ] Delete `~/.pi/agent/models.json` (contains the DeepSeek key).

## RECORDED, deliberately not levers

- Prompt stable-parts-first ordering would recover ~2.3M cross-run miss
  tokens over the battery — worth about fifty cents on Flash. Tidy, not a
  lever; do it only if touching that code anyway.
- Cordis itself: probed (B12), declined, trigger documented in
  `docs/cordis-probe.md` — reopens only if components ever need spatial
  scoping the current tree cannot express.
