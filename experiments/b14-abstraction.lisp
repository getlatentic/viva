;;;; B14 diagnostic -- WHY did Gate 1 fail? Not a third version of E24.
;;;;
;;;; E24's verdict is FINAL: observable but not reliably solvable, 0/5 twice,
;;;; under two different prompts. This file cannot change that. It lives outside
;;;; src/tasks so :E24B is not in the task set, is not counted by the suite, and
;;;; NO RESULT HERE CAN MAKE GATE 1 RETROSPECTIVELY PASS.
;;;;
;;;; WHAT THE SECOND FAILURE SHOWED. The prompt amendment fixed discoverability:
;;;; burden went from 4,4,7,5,7 to 16,10,8,7 and the agent visibly walked the
;;;; intended diagnostic path, printing "stored 75 -> actual 27" per quote. It
;;;; then repaired QUOTE BY QUOTE. total-correct failed 5/5, negotiated-preserved
;;;; 2/5, stale-recomputed 3/5.
;;;;
;;;;   observability      FIXED
;;;;   evidence gathered  YES
;;;;   mismatches found   YES
;;;;   repair strategy    ENUMERATION, not a rule over the population
;;;;
;;;; THE QUESTION, and only this one: is rule induction failing because the
;;;; population is too large, or does this model prefer local enumeration even
;;;; when a generic repair is available?
;;;;
;;;; NOT TESTED BY SHRINKING THE POPULATION. inspect_value prints 20 entries, so
;;;; 40 quotes would expose 50% of the population against 400's 5%. A win there
;;;; would confound scale with view density and prove nothing. So: SAME 400
;;;; QUOTES, SAME WORLD, SAME TOOLS, SAME BUDGET, SAME CASES. One sentence of the
;;;; prompt differs, and it removes ambiguity about the expected GRANULARITY
;;;; without revealing which quotes are affected or how to identify them.
;;;;
;;;; PRE-REGISTERED INTERPRETATION, written before the run:
;;;;
;;;;   A fails, B passes   the model saw the evidence and chose the wrong LEVEL
;;;;                       OF ABSTRACTION. The recurring bottleneck is
;;;;                       procedural, not tooling -- and B14's reusable
;;;;                       improvement is then a SKILL, not impact_map.
;;;;   A fails, B fails    a deeper inability or budget limit in deriving the
;;;;                       rule. The sequence needs redesigning around something
;;;;                       this model can actually do.
;;;;   A passes on rerun   the original failure was stochastic and this whole
;;;;                       diagnostic was reading noise.

(in-package #:vivarium.cli)

(tasks:deftask :e24b (:family :e-diagnostic :split :train :package "VIVARIUM.TASK.E24B")
  "Some quotes in *QUOTES* report a shipping cost that disagrees with what
SHIPPING-COST computes for them today. Not all of those are wrong.

*QUOTES* holds 400 quotes. Each is a plist with :ID, :WEIGHT, :ZONE and :COST,
where :COST was stored when the quote was made. QUOTE-TOTAL sums them.

Correct the ones that are stale, and leave everything else exactly as it is.

Repair the affected population generically: work out what distinguishes the
quotes that need correcting and install code that applies that. Patching
individual quote records one by one is not an acceptable repair."
  (lambda (backend package)
    (declare (ignore package))
    (vivarium.service:install-all backend (tasks::e24-sources)))
  ;; The identical scoring lambda, taken from E24 rather than rewritten. A
  ;; diagnostic scored differently from the task it diagnoses is not a
  ;; diagnostic.
  (tasks:task-cases (tasks:find-task :e24)))

(defun b14-abstraction-diagnostic ()
  (let ((*b14-task* :e24b))
    (b14-report (b14-run :label "E24B -- granularity named, rule withheld")
                :label "E24B -- granularity named, rule withheld")))
