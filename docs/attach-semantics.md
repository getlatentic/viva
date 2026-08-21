# What attaching to a session delivers

Written down because it is a policy, not an implementation detail, and it was
introduced as a bug fix without being stated as one.

## The two clients want opposite things

`vivarium attach` is line-oriented. It prints events as they arrive, so a
replay would scroll the terminal and bury whatever the person was looking at.
It attaches **from now**.

`vivarium live` is full-screen. Opening a session and seeing an empty pane is
indistinguishable from opening the wrong session. It attaches **from zero**.

Both are correct for their client. Neither is a default the other should
inherit.

## The seam, and the property that matters

```
historical -------------------- cursor N
                                  |
                                  +---- live
```

> Every event up to N comes from the replay, every event after N comes from the
> live subscription, and no event is lost or delivered twice.

`watch` establishes the barrier and the subscription in one critical section
for exactly this reason. That comment has been in the code since the daemon was
written; what did not exist was a test that the property holds.

It exists now, and it is asserted as **sequence contiguity** rather than as
"the old messages appeared":

- *attaching to a finished conversation replays it exactly once* — the replay
  delivers every event the session has, with no repeats.
- *attaching while a turn is running has no gap and no duplicate* — the attach
  happens deliberately mid-flight, and the union of replayed and live events is
  a contiguous run of sequence numbers.

A test that only checked for old messages passes while the seam drops an event
or repeats one, which is the failure that actually happens.

## What `since 0` costs, stated plainly

**Today, attaching a full-screen client replays the entire session.** For a
session with a hundred turns that is fine. For one with a hundred thousand
events it is not, and the honest description of the current behaviour is:

```
attach semantics today:
    replay full session history
    then transition atomically to live stream
```

Two things bound the damage and neither is a history window:

- the client keeps `*scrollback*` display lines (2,000) and discards the rest,
  so **memory** is bounded even when the wire is not;
- the daemon reads the tail from memory and everything older from the journal,
  so the daemon is not holding it all either.

What is unbounded is **the transfer**: every attach moves the whole history
across the socket once.

**This is not the right long-term semantics.** The replacement is a bounded
window — `since (max 0 (- head N))`, with the client asking for more as a
person scrolls back — and it should land before anybody runs an agent for days
in one session. It is not in this change set because the correction that
prompted this document was explicitly scoped to invariants, not features.

Until then the behaviour is: **full replay on every attach.** Anyone building
on the socket should know that is what they are getting.
