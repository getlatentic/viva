;;;; Family D: tasks long enough that interrupting one interrupts something.
;;;;
;;;; Added for [B10], and the reason is a measurement rather than a preference.
;;;; B10's pre-run probe found the train split completes in a median of 4.5
;;;; turns; S2c's reported 6.7 spans all seventeen tasks and both models, and the
;;;; harder held-out tasks were carrying it. A checkpoint placed in a five-turn
;;;; run interrupts an agent that has barely started, so a near-floor
;;;; reconstruction tax would be an artefact of run length rather than evidence
;;;; that explicit durable state is sufficient. That is the failure mode that
;;;; would be actively misleading, because a null result reads as a finding.
;;;;
;;;; WHAT THESE GUARANTEE AND WHAT THEY MUST NOT. They guarantee that a run
;;;; accumulates in-flight state before any plausible checkpoint: work is
;;;; ordered, or plural, or spent on hypotheses that turn out wrong. They must
;;;; NOT be built so that losing that state is expensive by construction --
;;;; whether it is expensive is exactly what B10 measures, and a task tuned to
;;;; make recovery costly would measure this file rather than the substrate.
;;;; The line is: these decide that there IS something in flight, never what
;;;; losing it costs.
;;;;
;;;; One family, three reasons a run gets long -- ordered work, plural work, and
;;;; work spent on hypotheses that turn out wrong. Three are train-split so B10
;;;; can spend them; T21 is held out, because the census test's invariant is that
;;;; both halves carry every family, and because a B10 result found on train
;;;; should have somewhere to be confirmed.

(in-package #:vivarium.tasks)

;;; T18 -- ordered work: the second defect is masked by the first
;;;
;;; FEE-FOR signals on the legacy lines, so SETTLE-BATCH cannot return at all
;;; and ROUND-CENTS is never reached. Only once the first defect is repaired
;;; does the second become observable. An agent cannot see both at once, which
;;; is what makes the turns ordered rather than merely several.

(deftask :t18 (:family :d-depth :split :train :package "VIVARIUM.TASK.T18")
  "SETTLE-BATCH signals instead of returning a total.

There are 800 lines in *LINES* and the failure comes from a handful of them.
Find which, and why, and make SETTLE-BATCH return the correct settled total.

Fees are quarter-units and settle to whole cents."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *lines*
  (let ((out '()))
    (dotimes (i 800 (nreverse out))
      (push (list :id i
                  :tier (if (member i '(17 340 611)) :legacy :standard)
                  :rate (if (member i '(17 340 611)) nil 3)
                  :units (1+ (mod i 7)))
            out))))"
           "(defun fee-for (line)
  (/ (* (getf line :units) (getf line :rate)) 4))"
           "(defun round-cents (amount) (truncate amount))"
           "(defun settle-batch ()
  (reduce #'+ *lines* :key (lambda (line) (round-cents (fee-for line)))
          :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((lines (service:value-in package '#:*lines*))
             ;; The specification, not a copy of the implementation: a legacy
             ;; line settles at the flat legacy rate of 2, everything else at 3,
             ;; and quarters round rather than truncate.
             (expected (reduce #'+ lines
                               :key (lambda (line)
                                      (round (/ (* (getf line :units)
                                                   (if (eq (getf line :tier) :legacy) 2 3))
                                                4)))
                               :initial-value 0)))
        (list (cons "legacy-lines-priced"
                    (lambda ()
                      (let ((legacy (find :legacy lines :key (lambda (l) (getf l :tier)))))
                        (score (eql (/ (* (getf legacy :units) 2) 4)
                                    (try '#:fee-for legacy))))))
              (cons "standard-lines-unchanged"
                    (lambda ()
                      (let ((standard (find :standard lines :key (lambda (l) (getf l :tier)))))
                        (score (eql (/ (* (getf standard :units) 3) 4)
                                    (try '#:fee-for standard))))))
              (cons "settles-by-rounding"
                    ;; Unreachable until the first defect is gone, which is the
                    ;; point of the pair.
                    (lambda () (score (and (eql 4 (try '#:round-cents 7/2))
                                           (eql 2 (try '#:round-cents 9/4))))))
              (cons "batch-total"
                    (lambda () (score (eql expected (try '#:settle-batch)))))
              (cons "lines-intact"
                    (lambda () (score (eql 800 (length (service:value-in package '#:*lines*)))))))))))

;;; T19 -- plural work: five independent charges, none interacting
;;;
;;; T12 has this shape and is held out. B10 needs one it is allowed to spend,
;;; and five rather than three because the length is the point.

(deftask :t19 (:family :d-depth :split :train :package "VIVARIUM.TASK.T19")
  "Five charges are each wrong, independently:

  HANDLING-FEE   flat 5, but orders over 20 items should pay 5 plus 1 per
                 additional item
  INSURANCE-FOR  charges every order; only declared values above 100 insure,
                 at 2%
  RUSH-SURCHARGE ignores the tier; :next-day is 25, :two-day is 10, :ground is 0
  CREDIT-FOR     returns the full amount for any return; returns after 30 days
                 credit half
  ROUND-TO-CENT  truncates where it should round

They do not interact. Fix what you can."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defun handling-fee (items) (declare (ignore items)) 5)"
           "(defun insurance-for (declared) (round (* declared 2) 100))"
           "(defun rush-surcharge (tier) (declare (ignore tier)) 10)"
           "(defun credit-for (amount days) (declare (ignore days)) amount)"
           "(defun round-to-cent (amount) (truncate amount))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (list (cons "handling-scales-above-20"
                  (lambda () (score (and (eql 5 (try '#:handling-fee 20))
                                         (eql 8 (try '#:handling-fee 23))))))
            (cons "insurance-only-above-100"
                  (lambda () (score (and (eql 0 (try '#:insurance-for 100))
                                         (eql 4 (try '#:insurance-for 200))))))
            (cons "rush-by-tier"
                  (lambda () (score (and (eql 25 (try '#:rush-surcharge :next-day))
                                         (eql 10 (try '#:rush-surcharge :two-day))
                                         (eql 0 (try '#:rush-surcharge :ground))))))
            (cons "late-returns-credit-half"
                  (lambda () (score (and (eql 100 (try '#:credit-for 100 10))
                                         (eql 50 (try '#:credit-for 100 45))))))
            (cons "rounds-not-truncates"
                  (lambda () (score (and (eql 4 (try '#:round-to-cent 7/2))
                                         (eql 2 (try '#:round-to-cent 9/4))))))))))

;;; T20 -- wrong work: the obvious suspects are correct
;;;
;;; The total is wrong, and the two definitions on the obvious path are not the
;;; reason. The defect is in a branch 2 of 500 readings take. An agent must
;;; spend turns forming and discarding hypotheses, which is in-flight state that
;;; nothing in the ledger records -- the ledger holds what was INSTALLED, and a
;;; rejected candidate is never installed.

(deftask :t20 (:family :d-depth :split :train :package "VIVARIUM.TASK.T20")
  "TOTAL-CONSUMPTION is slightly too high and nobody knows why.

There are 500 readings in *READINGS*. NORMALIZE-READING and SCALE-FOR have both
been reviewed and are believed correct. Find the real cause and fix it.

An estimated reading is only 90% trusted and should be discounted accordingly."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *readings*
  (let ((out '()))
    (dotimes (i 500 (nreverse out))
      (push (list :id i
                  :status (if (member i '(88 401)) :estimated :measured)
                  :unit (if (evenp i) :kwh :mj)
                  :raw (+ 10 (mod i 13)))
            out))))"
           "(defun scale-for (unit) (if (eq unit :kwh) 1 1/4))"
           "(defun normalize-reading (reading)
  (* (getf reading :raw) (scale-for (getf reading :unit))))"
           ;; The defect: an estimated reading is passed through at full weight.
           "(defun adjust-estimated (reading value)
  (declare (ignore reading))
  value)"
           "(defun total-consumption ()
  (reduce #'+ *readings*
          :key (lambda (reading)
                 (adjust-estimated reading (normalize-reading reading)))
          :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((readings (service:value-in package '#:*readings*))
             (expected (reduce #'+ readings
                               :key (lambda (reading)
                                      (let ((value (* (getf reading :raw)
                                                      (if (eq (getf reading :unit) :kwh) 1 1/4))))
                                        (if (eq (getf reading :status) :estimated)
                                            (* value 9/10)
                                            value)))
                               :initial-value 0)))
        (list (cons "estimated-discounted"
                    (lambda ()
                      (let ((estimated (find :estimated readings
                                             :key (lambda (r) (getf r :status)))))
                        (score (eql (* (* (getf estimated :raw)
                                          (if (eq (getf estimated :unit) :kwh) 1 1/4))
                                       9/10)
                                    (try '#:adjust-estimated estimated
                                         (try '#:normalize-reading estimated)))))))
              (cons "measured-untouched"
                    ;; A repair that discounts everything passes the total only
                    ;; by accident and fails here.
                    (lambda ()
                      (let ((measured (find :measured readings
                                            :key (lambda (r) (getf r :status)))))
                        (score (eql (try '#:normalize-reading measured)
                                    (try '#:adjust-estimated measured
                                         (try '#:normalize-reading measured)))))))
              (cons "suspects-still-correct"
                    ;; The two definitions that were reviewed and cleared must
                    ;; still be what they were. A run that "fixes" them has
                    ;; chased the wrong hypothesis into the image.
                    (lambda () (score (and (eql 1 (try '#:scale-for :kwh))
                                           (eql 1/4 (try '#:scale-for :mj))))))
              (cons "consumption-total"
                    (lambda () (score (eql expected (try '#:total-consumption)))))
              (cons "readings-intact"
                    (lambda () (score (eql 500 (length (service:value-in package '#:*readings*)))))))))))

;;; T21 -- the held-out member of the family
;;;
;;; Ordered like T18 and blind like T20 at once: the pipeline signals, and once
;;; that is repaired the remaining error is not in the definition that looks
;;; responsible. Held out, so B10 spends T18-T20 and keeps somewhere to confirm.

(deftask :t21 (:family :d-depth :split :held-out :package "VIVARIUM.TASK.T21")
  "POST-LEDGER signals rather than returning a balance.

There are 600 entries in *ENTRIES*. Repair it, and make the balance correct.

A reversal entry carries a negative amount and must not also be re-signed."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *entries*
  (let ((out '()))
    (dotimes (i 600 (nreverse out))
      (push (list :id i
                  :kind (cond ((member i '(41 209 588)) :reversal)
                              ((member i '(7 350)) :void)
                              (t :charge))
                  :amount (if (member i '(7 350)) nil (+ 5 (mod i 11))))
            out))))"
           "(defun signed-amount (entry)
  (if (eq (getf entry :kind) :reversal)
      (- (getf entry :amount))
      (getf entry :amount)))"
           "(defun post-ledger ()
  (reduce #'+ *entries* :key #'signed-amount :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((entries (service:value-in package '#:*entries*))
             (expected (reduce #'+ entries
                               :key (lambda (entry)
                                      (let ((amount (getf entry :amount)))
                                        (cond ((null amount) 0)
                                              ((eq (getf entry :kind) :reversal) (- amount))
                                              (t amount))))
                               :initial-value 0)))
        (list (cons "void-entries-contribute-nothing"
                    (lambda ()
                      (let ((void (find :void entries :key (lambda (e) (getf e :kind)))))
                        (score (eql 0 (try '#:signed-amount void))))))
              (cons "reversals-still-negative"
                    (lambda ()
                      (let ((reversal (find :reversal entries :key (lambda (e) (getf e :kind)))))
                        (score (eql (- (getf reversal :amount))
                                    (try '#:signed-amount reversal))))))
              (cons "charges-unchanged"
                    (lambda ()
                      (let ((charge (find-if (lambda (e) (and (eq (getf e :kind) :charge)
                                                              (getf e :amount)))
                                             entries)))
                        (score (eql (getf charge :amount) (try '#:signed-amount charge))))))
              (cons "balance"
                    (lambda () (score (eql expected (try '#:post-ledger)))))
              (cons "entries-intact"
                    (lambda () (score (eql 600 (length (service:value-in package '#:*entries*)))))))))))
