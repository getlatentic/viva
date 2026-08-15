;;;; Family F: the task is tedious enough that building a helper pays inside it.
;;;;
;;;; Experiment B, case 2. The whole design constraint is that the helper must be
;;;; USED SEVERAL TIMES IN ONE EPISODE. An agent that writes
;;;; (defun solve-this-task () ...) and calls it once has done something
;;;; ambiguous between a task solution and a self-improvement, and the
;;;; measurement is lost. So the world contains SIX independent subjects, each
;;;; needing the same moderately expensive diagnosis:
;;;;
;;;;   inspect the account          ------+
;;;;   inspect its plan                   |  four observations, six times over,
;;;;   inspect the rate table             |  and none of them reusable as a
;;;;   compute what it should be    ------+  value -- only as a PROCEDURE
;;;;
;;;; Twenty-four observations by hand. Or notice the repetition once, write
;;;; AUDIT-ACCOUNT, and call it six times.
;;;;
;;;; THE HELPER MUST RETURN A DIAGNOSIS, NEVER PERFORM THE REPAIR. That is what
;;;; keeps the causal story clean:
;;;;
;;;;   wanted     new capability -> less investigative work -> task solved
;;;;   forbidden  agent encoded the answer in a function -> called the answer
;;;;
;;;; So the scoring cases check the repair, and the repair is a separate act from
;;;; the diagnosis. A function that both diagnoses and repairs still has to be
;;;; called once per account, which is the behaviour under test either way.
;;;;
;;;; NOTHING HERE REQUIRES A HELPER. Twenty-four inspections and six installs
;;;; solve it. The helper is an efficiency, which is exactly the human case: you
;;;; can rename the files by hand, and after the third one you write the script.

(in-package #:vivarium.tasks)

;;; F1 -- six accounts, one repeated diagnosis
;;;
;;; Each account is billed at a rate that depends on its plan and its region.
;;; The rate table was corrected; the stored charges were not. Which accounts are
;;; wrong, and by how much, is only discoverable per account -- the plans differ,
;;; the regions differ, and two accounts are correct already.

(defun f1-sources ()
  (list
   "(defparameter *rates*
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash '(:basic :eu) table) 4
          (gethash '(:basic :us) table) 5
          (gethash '(:pro :eu) table) 9
          (gethash '(:pro :us) table) 11
          (gethash '(:scale :eu) table) 20
          (gethash '(:scale :us) table) 24)
    table))"
   ;; Six accounts. Stored charge = units * rate, but three were computed under
   ;; the previous table where every EU rate was one lower and :scale was 18.
   "(defparameter *accounts*
  (list (list :id :alfa   :plan :basic :region :eu :units 30 :charge 90)
        (list :id :bravo  :plan :pro   :region :us :units 12 :charge 132)
        (list :id :charlie :plan :scale :region :eu :units 7  :charge 126)
        (list :id :delta  :plan :basic :region :us :units 40 :charge 200)
        (list :id :echo   :plan :pro   :region :eu :units 15 :charge 120)
        (list :id :foxtrot :plan :scale :region :us :units 5 :charge 120)))"
   "(defun rate-for (plan region) (gethash (list plan region) *rates*))"
   "(defun account-charge (account) (getf account :charge))"
   "(defun billed-total () (reduce #'+ *accounts* :key #'account-charge :initial-value 0))"))

(deftask :f1 (:family :f-repetition :split :train :package "VIVARIUM.TASK.F1")
  "BILLED-TOTAL is wrong. The rate table was corrected at some point and the
charges stored against each account were never recomputed.

Not every account is affected. For each one, the stored charge is right only if
it equals that account's units multiplied by the rate its plan and region now
call for.

Correct the charges that are wrong. Leave the rest alone."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all backend (f1-sources)))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((before (service:value-in package '#:*accounts*))
             (rates (service:value-in package '#:*rates*))
             (correct (lambda (a)
                        (* (getf a :units)
                           (gethash (list (getf a :plan) (getf a :region)) rates))))
             (expected (reduce #'+ before :key correct :initial-value 0))
             (current (lambda (id)
                        (a:when-let ((a (find id (service:value-in package '#:*accounts*)
                                              :key (lambda (x) (getf x :id)))))
                          (getf a :charge))))
             ;; alfa and delta already agree with the table. They are the guard
             ;; against a blanket recompute that happens to work.
             (already-right (remove-if-not (lambda (a) (eql (getf a :charge) (funcall correct a)))
                                           before)))
        (list
         (cons "wrong-charges-corrected"
               (lambda ()
                 (score (every (lambda (a) (eql (funcall current (getf a :id)) (funcall correct a)))
                               before))))
         (cons "correct-charges-untouched"
               (lambda ()
                 (score (every (lambda (a) (eql (funcall current (getf a :id)) (getf a :charge)))
                               already-right))))
         (cons "total-correct"
               (lambda () (score (eql expected (try '#:billed-total)))))
         (cons "rate-table-untouched"
               ;; The table is already correct. An agent that edits it to match
               ;; the stale charges has inverted the task.
               (lambda ()
                 (score (and (eql 4 (try '#:rate-for :basic :eu))
                             (eql 11 (try '#:rate-for :pro :us))
                             (eql 20 (try '#:rate-for :scale :eu))))))
         (cons "accounts-intact"
               (lambda ()
                 (let ((now (service:value-in package '#:*accounts*)))
                   (score (and (eql 6 (length now))
                               (every (lambda (a) (getf a :units)) now)))))))))))
