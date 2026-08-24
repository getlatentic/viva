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

Route by the SHAPE of the thing, not by how pleased you are with it.

1. A FACT OR PROCEDURE you had to work out -- a format rule, a build quirk,
   where something lives. Use remember, one line each. No code.

2. CODE YOU WOULD OTHERWISE WRITE AGAIN -- a parse, a reshape, a conversion.
   Write it as a skill: a file .viva/skills/<name>/SKILL.md holding

       ---
       name: <name>
       description: <when a future task should reach for this>
       language: python | bash | ...
       ---

   then a sentence of when to use it and ONE fenced code block that runs. A
   later task reads it and runs the snippet. This is the right home for
   working code you are not yet sure will be wanted often.

3. A TOOL, when the transformation is plainly one you will call by name again
   and again: a directory .viva/tools/<name>/ holding tool.json --

      {\"name\": \"...\", \"description\": \"...\",
       \"exec\": [\"python3\", \"run.py\"],
       \"parameters\": [{\"name\": \"...\", \"type\": \"string\",
                        \"description\": \"...\", \"required\": true}]}

   -- and the script it names, which reads one JSON object of arguments on
   stdin and prints its result.

   IF YOU DECLARE ANY PARAMETERS, the script must also answer a describe
   request, or the tool is refused and nothing is registered. When the JSON on
   stdin is exactly {\"vivarium\": \"describe\"}, print your own parameter list
   and exit, doing nothing else:

       {\"parameters\": [{\"name\": \"path\", \"type\": \"string\",
                        \"required\": true}]}

   That is what stops a manifest promising something the script cannot take,
   which fails later, in another task, to whoever calls it. A tool that
   declares NO parameters needs none of this.

   THIS IS THE EXPENSIVE TIER: it costs a manifest, a script and a calling
   convention to get wrong. Prefer a skill unless the reuse is already
   evident -- you have reached for this same transformation more than once, in
   this task or a previous one.

The dividing line between 2 and 3 is not quality, it is EVIDENCE OF REUSE.
Code you might want again is a skill. Code you have already wanted again is
a tool.

Parsimony is the policy: most tasks leave nothing worth keeping, and
\"nothing to retain\" is the correct answer then. Never retain task-specific
answers -- only what transfers."
  "The policy text. Names all three tiers and the rule that routes between
them -- this is the organism directing its own retention, not an experiment
measuring a default, so mechanism-naming is the job rather than a confound.

THE MIDDLE TIER IS THE POINT of this version. v1 offered a note or a tool and
nothing between, and the dogfood showed what that costs: the organism wrote an
excellent note about a file format, which removed enough friction that a tool
was never worth writing -- so the code it had worked out was thrown away every
time and re-derived from the note. A skill carries the code at a fraction of a
tool's price.

The routing rule is EVIDENCE OF REUSE rather than judgement of quality,
because `is this good enough to be a tool` is a question with no stable
answer, while `have I reached for this before` is a fact.

The compile channel is absent, and that is deliberate. v1 said
create_capability / call_capability / promote_capability: the in-image path
that lost 0/6 in KC6 and, worse for a retention policy, evaporates when the
process exits.")

(defun retire-unused (agent &key (now (get-universal-time)))
  "Retire the skills that have stopped earning their place. Returns what was
retired, for the caller to show.

Here rather than inside the reflection turn, and after it rather than before.
Reflection is a model request that decides what to KEEP; retiring is a
threshold on evidence already recorded, and mixing the two would let a model
argue its way out of a rule -- or spend tokens re-deciding something the
counters already answer.

After, because a skill written by this very reflection has a fresh timestamp
and cannot be retired by it, while sweeping first would race the write."
  (a:when-let ((environment (agent-environment agent)))
    (decay:sweep-skills environment (agent-skills agent) :now now)))

(defun reflect (agent)
  "Run the retention policy's reflection turn on AGENT's just-finished task.

Returns the reflection's reply, or NIL when the turn could not run (an
aborting agent stays aborted; reflection never overrides a cancellation).
The request limit is raised by *REFLECTION-BUDGET* from wherever the task
left it, so the turn has room of its own without inheriting starvation."
  (unless (agent-aborting agent)
    (setf (agent-request-limit agent)
          (+ (agent-requests agent) *reflection-budget*))
    (prog1 (ask agent *reflection-prompt* :reset nil)
      ;; A retirement nobody is told about is indistinguishable from a bug, so
      ;; it goes to the same place every other retention decision goes.
      (dolist (retirement (ignore-errors (retire-unused agent)))
        (format *error-output* "~&~a~%" (decay:describe-retirement retirement))))))
