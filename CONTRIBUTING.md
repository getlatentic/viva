# Contributing

**GitHub issues are the single source of truth.** No work happens that is
not an issue; every change references one (`Closes #N`, or `Refs #N` for a
partial). Milestones are sprints — each a vertical slice a user can
experience, sequenced so each builds on the last.

Emergent work goes to the **backlog** (label `backlog`, no milestone), never
into the running sprint unless it blocks the sprint goal. Sprint planning at
each boundary triages the backlog into the next sprint.

Board: https://github.com/tosinamuda/vivarium/issues

**The road to v0.1**, four sprints, each demoable:

```
Sprint 0  the router retains, and it pays
Sprint 1  tools that leave the building — a tool vivarium wrote,
          called from Claude Code
Sprint 2  does it pay, on real work — dogfood a week of vivarium's own
          development with the policy on
Sprint 3  v0.1 — README around what survived, a clean-machine install,
          the demo, the tag
```

Machinery that does not gate the release lives in the backlog with a named
revisit trigger, not a wish: registry lifecycle wiring (trigger: a revert is
actually needed — files already have git), graduation by reuse (trigger:
manual registration becomes the friction), synthetic harder families
(trigger: dogfood evidence too noisy to read).

The repository's own governance documents remain where they are:
docs/MANIFESTO.md is the alignment point; docs/BACKLOG.md now holds only the
ARMED tripwires (conditions, not work), the RECORDED non-levers, and the
FUTURE lane's revisit triggers — everything workable lives in issues.

House rules that predate this file and still bind: no AI attribution in
commits; write it right the first time; every experiment pre-registers its
thresholds before its data exists; a check that cannot fail is not a check.
