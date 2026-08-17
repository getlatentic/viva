# Backlog

The one tracker. Lanes mirror the manifesto's ratified sequencing; moving an
item between lanes is a decision and gets a commit of its own. The stopping
rule applies here as everywhere: a concern enters as WORK only with a
reproduction, a counterexample, or a mission clause behind it — everything
else is a tripwire, armed and waiting.

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
      promoted, instrumentality thresholds passed. v2 (friction-gated
      trigger, retention validator) needs v1 data and follows the re-posed
      KC6.
- [ ] **Tools as components** — the organism's own grep/edit/bash resolving
      through the door. Stronger claim, bigger blast radius. Pulled earlier
      only if pre-check 3 shows the `(lambda (input))` surface is too narrow
      to be used at all.
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
