;;;; The retention policy's mechanism: one bounded reflection turn after the
;;;; work, in the work's own conversation.
;;;;
;;;; Level 3's gap, measured before this existed: across 90+ KC6 task-runs
;;;; and three framings, no arm spontaneously retained anything -- promote
;;;; existed and the POLICY did not. This file is the policy's v1: the
;;;; harness owns WHEN (always, at task end), the reflection turn owns WHAT,
;;;; and retention flows through the existing doors only -- remember for
;;;; text, the capability tools for compiled transformations -- so the
;;;; policy adds attention, never authority.
;;;;
;;;; Same conversation on purpose (:reset nil): reflection sees the actual
;;;; friction rather than a reconstruction, and a cancellation that landed
;;;; during the work stays in force. Bounded on purpose: the turn gets its
;;;; own request budget on top of whatever the task consumed, so it can
;;;; neither starve nor be starved by the work that preceded it.

(in-package #:vivarium.harness)

(defparameter *reflection-budget* 6
  "Requests a reflection turn may spend beyond what the task consumed.")

(defparameter *reflection-prompt*
  "The task above is finished. Before this working context closes, decide
what -- if anything -- should outlive it.

Retain only what genuinely makes similar future work cheaper:
- a fact or procedure you had to work out (a build quirk, a format rule,
  where something lives): use remember, one line each.
- a transformation you would otherwise write again (a parser, a reshaper,
  a converter): write it as a tool, with the ordinary file tools. A tool is
  a directory .vivarium/tools/<name>/ holding tool.json --

      {\"name\": \"...\", \"description\": \"...\",
       \"exec\": [\"python3\", \"run.py\"],
       \"parameters\": [{\"name\": \"...\", \"type\": \"string\",
                        \"description\": \"...\", \"required\": true}]}

  -- and the script it names. The script reads one JSON object of arguments
  on stdin and prints its result. Later tasks call it by name.

  A tool costs more to write than a note and only pays if you would reach
  for it again, so prefer the note unless the transformation is plainly
  one you would rewrite.

Parsimony is the policy: most tasks leave nothing worth keeping, and
\"nothing to retain\" is the correct answer then. Never retain
task-specific answers -- only what transfers."
  "The policy text. Names both channels and their division of labour -- this
is the organism directing its own retention, not an experiment measuring a
default, so mechanism-naming is the job rather than a confound.

The compile channel is GONE from it, and that is the point. v1 said
create_capability / call_capability / promote_capability: the in-image path
that lost 0/6 in KC6 and, worse for a retention policy, evaporates when the
process exits. What replaced it needs no verb at all -- a script and a
manifest, written with the file tools every agent already has, callable by
name afterwards through the registry. The cost caveat is deliberate: the
kill punished paying a heavy install price for something used four times.")

(defun reflect (agent)
  "Run the retention policy's reflection turn on AGENT's just-finished task.

Returns the reflection's reply, or NIL when the turn could not run (an
aborting agent stays aborted; reflection never overrides a cancellation).
The request limit is raised by *REFLECTION-BUDGET* from wherever the task
left it, so the turn has room of its own without inheriting starvation."
  (unless (agent-aborting agent)
    (setf (agent-request-limit agent)
          (+ (agent-requests agent) *reflection-budget*))
    (ask agent *reflection-prompt* :reset nil)))
