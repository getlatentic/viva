;;;; Family F: repeated investigation that a helper can displace.
;;;;
;;;; THE PERMANENT DESIGN RULE FOR THIS FAMILY, learned by building the same
;;;; flaw twice:
;;;;
;;;;   Before accepting a self-improvement task, enumerate the ways an agent
;;;;   could collapse the intended repeated work into a cheaper path, and
;;;;   demonstrate experimentally that each unintended path is closed BEFORE
;;;;   running a model. "The reference solution passes" is nowhere near
;;;;   sufficient for a benchmark about self-improvement.
;;;;
;;;; THREE PROOFS, and the third is the one that was missing:
;;;;
;;;;   REACHABILITY    CONTROL can solve it legally.
;;;;   NON-COLLAPSE    every identified cheap unintended path FAILS.
;;;;   INSTRUMENTALITY the reusable improvement can reduce work, AND the final
;;;;                   task result stays valid when that improvement is ABLATED.
;;;;
;;;; Instrumentality is what distinguishes improving the WORKER from improving
;;;; the WORK. Without it an agent can write (defun audit-account ...) that
;;;; computes the answer and (defun calculate-charge (id) (audit-account id)),
;;;; and the two collapse back into one thing.
;;;;
;;;; SOURCE MAY REVEAL THE PROCEDURE, NEVER THE ANSWER. An agent that reads the
;;;; API and thinks "I will do this four-call sequence six times, I should
;;;; automate it" is exhibiting exactly the behaviour under test -- that is the
;;;; shell-script move, not a shortcut. What source must not permit is writing
;;;; the repair without runtime evidence.

(in-package #:vivarium.tasks)

;;; F1 -- six accounts, four observations each, one repair
;;;
;;; The runtime values live in hash tables that are populated AFTER the
;;; definitions are installed, so read_definition shows empty containers and the
;;; API that reaches them. A hash table also prints as #<HASH-TABLE> with its
;;; keys but not its values, so inspecting a root reveals what to ask for and
;;; never the answers.

(defparameter +f1-accounts+ '(:alfa :bravo :charlie :delta :echo :foxtrot))

(defparameter +f1-facts+
  ;; id -> (usage rate override). Present only here, never in installed source.
  '((:alfa 30 4 nil) (:bravo 12 11 nil) (:charlie 7 20 100)
    (:delta 40 5 nil) (:echo 15 9 nil) (:foxtrot 5 24 90))
  "The runtime-only facts. CHARLIE and FOXTROT carry negotiated overrides, so no
uniform formula over usage and rate is correct and the override has to be
observed per account.")

(defun f1-expected (id)
  (destructuring-bind (usage rate override) (rest (assoc id +f1-facts+))
    (or override (* usage rate))))

(defun f1-sources ()
  (list
   "(defparameter *usage* (make-hash-table))"
   "(defparameter *rate* (make-hash-table))"
   "(defparameter *override* (make-hash-table))"
   "(defparameter *charge* (make-hash-table))"
   ;; The observation-safe API. Its SHAPE is readable; its RESULTS are not.
   "(defun usage-for (id) (gethash id *usage*))"
   "(defun rate-for (id) (gethash id *rate*))"
   "(defun override-for (id) (gethash id *override*))"
   "(defun current-charge (id) (gethash id *charge*))"
   "(defun accounts () '(:alfa :bravo :charlie :delta :echo :foxtrot))"
   ;; What the task asks for, wrong on arrival. The scorer calls this.
   "(defun calculate-charge (id) (current-charge id))"))

(defparameter +f1-observation-api+
  '("USAGE-FOR" "RATE-FOR" "OVERRIDE-FOR" "CURRENT-CHARGE" "ACCOUNTS")
  "Declared observation-safe. Not every pre-existing function -- provenance is
not purity, and CALCULATE-CHARGE is deliberately absent because the repair must
not be reachable as an observation.")

(defun f1-populate (package)
  "Runtime-only facts, installed as VALUES after the definitions exist. Nothing
here appears in any source READ-DEFINITION can show."
  (let ((usage (service:value-in package '#:*usage*))
        (rate (service:value-in package '#:*rate*))
        (override (service:value-in package '#:*override*))
        (charge (service:value-in package '#:*charge*)))
    (dolist (fact +f1-facts+)
      (destructuring-bind (id u r o) fact
        (setf (gethash id usage) u
              (gethash id rate) r)
        (when o (setf (gethash id override) o))
        ;; The stored charge is stale for every account: it ignores overrides
        ;; and uses a rate that has since changed.
        (setf (gethash id charge) (* u (max 1 (1- r))))))))

(deftask :f1 (:family :f-repetition :split :train :package "VIVARIUM.TASK.F1")
  "CALCULATE-CHARGE returns the stored charge for an account, and the stored
charges are stale.

For each account, the correct charge is its usage multiplied by its rate --
unless the account has a negotiated override, in which case the override is the
charge. USAGE-FOR, RATE-FOR, OVERRIDE-FOR and CURRENT-CHARGE report those for one
account at a time; ACCOUNTS lists them.

Redefine CALCULATE-CHARGE so it returns the correct charge for every account.
CALCULATE-CHARGE must not call USAGE-FOR, RATE-FOR, OVERRIDE-FOR or
CURRENT-CHARGE -- work the values out first and encode the result."
  (lambda (backend package)
    (service:install-all backend (f1-sources))
    (f1-populate package))
  (lambda (package backend)
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (list
       (cons "every-charge-correct"
             (lambda ()
               (score (every (lambda (id) (eql (f1-expected id) (try '#:calculate-charge id)))
                             +f1-accounts+))))
       (cons "overrides-respected"
             ;; CHARLIE and FOXTROT are wrong under any usage*rate formula, so
             ;; this fails for an agent that never observed the overrides.
             (lambda ()
               (score (and (eql 100 (try '#:calculate-charge :charlie))
                           (eql 90 (try '#:calculate-charge :foxtrot))))))
       (cons "repair-is-self-contained"
             ;; The escape this closes: deferring the whole investigation into
             ;; the repair, so the scorer performs it and the agent never does.
             (lambda ()
               ;; The BACKEND the task was set up with, not a fresh one -- a new
               ;; instance has an empty ledger and DEFINITION-SOURCE returns NIL,
               ;; which silently fails this case for every attempt.
               (let ((source (image:definition-source
                              backend
                              (format nil "DEFUN ~a::CALCULATE-CHARGE" package))))
                 (score (and source
                             (notany (lambda (api) (search api (string-upcase source)))
                                     '("USAGE-FOR" "RATE-FOR" "OVERRIDE-FOR" "CURRENT-CHARGE")))))))
       (cons "observation-api-untouched"
             (lambda ()
               (score (and (eql 30 (try '#:usage-for :alfa))
                           (eql 4 (try '#:rate-for :alfa))
                           (eql 100 (try '#:override-for :charlie))
                           (null (try '#:override-for :alfa))))))))))
