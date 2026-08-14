;;;; Family A-state: the fix must not destroy what is already there.
;;;;
;;;; Every task here scores correctness and survival as separate cases, which is
;;;; the concrete reason the score vector cannot collapse to one number. A
;;;; file-based harness can reach full marks on correctness and structurally
;;;; cannot reach them on survival: its only way to apply a fix is to reload, and
;;;; the reload is what destroys the thing being counted.

(in-package #:vivarium.tasks)

(defun event-fingerprint (package id)
  (let ((events (service:value-in package '#:*events*)))
    (when (> (length events) id)
      (let ((event (aref events id)))
        (list (service:call-in package '#:event-qty event)
              (service:call-in package '#:event-price event)
              (service:call-in package '#:event-kind event))))))

;;; T1

(deftask :t1 (:family :a-state :split :train :package "VIVARIUM.TASK.T1")
  "TOTAL-REVENUE signals a TYPE-ERROR. The image has been processing events for
a while and *EVENTS* holds every one of them; the run must not lose them.

Some events are comped -- kind :COMP, price NIL -- and the function multiplies
straight through the NIL. A comped event contributes zero revenue.

Fix TOTAL-REVENUE so it returns the correct figure."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-events package)
    (service:install-all
     backend
     (list "(defun total-revenue ()
  (reduce #'+ *events*
          :key (lambda (event) (* (event-qty event) (event-price event)))
          :initial-value 0))")))
  (lambda (package backend)
    (let ((expected (service:reference-revenue package))
          (count (service:event-count package))
          (first (event-fingerprint package 0)))
      (list (cons "revenue"
                  (lambda () (score (eql expected (service:call-in package '#:total-revenue)))))
            (cons "events-intact"
                  (lambda () (intact-p package '#:*events* count)))
            (cons "event-zero-unchanged"
                  (lambda () (score (equal first (event-fingerprint package 0)))))))))

;;; T2

(deftask :t2 (:family :a-state :split :held-out :package "VIVARIUM.TASK.T2")
  "PRICE-OF ignores the standing discount and returns the raw price.

*CACHE* holds two thousand raw prices accumulated from live traffic. They are
not recoverable from anywhere -- there is no source that produces them -- so the
cache must survive the fix, with its raw values unchanged.

Fix PRICE-OF to subtract *DISCOUNT* from the cached raw price. A key with no
cached price is worth zero."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-cache package)
    (service:install-all
     backend
     (list "(defparameter *discount* 10)"
           "(defun price-of (key) (or (gethash key *cache*) 0))")))
  (lambda (package backend)
    (let* ((cache (service:value-in package '#:*cache*))
           (count (hash-table-count cache))
           (discount (service:value-in package '#:*discount*))
           (sample (loop for key from 0 below 50 collect key))
           (raw (mapcar (lambda (key) (gethash key cache)) sample)))
      (list (cons "price-discounted"
                  (lambda ()
                    (scored-fraction
                     (count t (mapcar (lambda (key raw)
                                        (eql (- raw discount)
                                             (service:call-in package '#:price-of key)))
                                      sample raw))
                     (length sample))))
            (cons "cache-retained"
                  (lambda () (intact-p package '#:*cache* count)))
            (cons "raw-values-unchanged"
                  (lambda ()
                    (let ((live (service:value-in package '#:*cache*)))
                      (scored-fraction
                       (count t (mapcar (lambda (key raw) (eql raw (gethash key live)))
                                        sample raw))
                       (length sample)))))))))

;;; T3

(deftask :t3 (:family :a-state :split :held-out :package "VIVARIUM.TASK.T3")
  "Three hundred SESSION instances are live in *SESSIONS*, each holding the
orders it accumulated. They cannot be rebuilt -- nothing on disk records them.

SESSION needs a TOTAL slot holding the sum of that session's ORDERS. Redefining
the class leaves the new slot unbound on every existing instance, so the
redefinition is only half the job: the three hundred instances that already
exist have to end up with a correct TOTAL.

Add the slot and migrate the live instances."
  (lambda (backend package)
    (service:install-all backend service:+session-substrate+)
    (service:build-sessions package))
  (lambda (package backend)
    (let* ((sessions (service:value-in package '#:*sessions*))
           (count (hash-table-count sessions))
           (expected (let ((table (make-hash-table :test #'eql)))
                       (maphash (lambda (id session)
                                  (setf (gethash id table)
                                        (reduce #'+ (service:call-in package '#:session-orders
                                                                     session)
                                                :initial-value 0)))
                                sessions)
                       table)))
      (flet ((total-of (session)
               (let ((slot (find-symbol "TOTAL" package)))
                 (and slot (slot-boundp session slot) (slot-value session slot)))))
        (list (cons "sessions-intact"
                    (lambda () (intact-p package '#:*sessions* count)))
              (cons "totals-bound"
                    (lambda ()
                      (let ((live (service:value-in package '#:*sessions*)))
                        (scored-fraction
                         (loop for session being the hash-values of live
                               count (total-of session))
                         count))))
              (cons "totals-correct"
                    (lambda ()
                      (let ((live (service:value-in package '#:*sessions*)))
                        (scored-fraction
                         (loop for id being the hash-keys of live using (hash-value session)
                               count (eql (gethash id expected) (total-of session)))
                         count)))))))))

;;; T13

(deftask :t13 (:family :a-state :split :train :package "VIVARIUM.TASK.T13")
  "A change was installed to ORDER-TOTAL a moment ago and it was wrong: it
double-counts quantity. The version before it was correct.

The image keeps the previous source for every definition it installed. Restore
correct behaviour."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *lines* (list (list :qty 2 :price 5) (list :qty 3 :price 5) (list :qty 1 :price 10)))"
           "(defun order-total (lines)
  (reduce #'+ lines :key (lambda (line) (* (getf line :qty) (getf line :price))) :initial-value 0))"
           ;; The regression, installed over a good version so the ledger holds both.
           "(defun order-total (lines)
  (reduce #'+ lines :key (lambda (line) (* (getf line :qty) (getf line :qty) (getf line :price))) :initial-value 0))")))
  (lambda (package backend)
    (let ((lines (service:value-in package '#:*lines*))
          (good "(defun order-total (lines)
  (reduce #'+ lines :key (lambda (line) (* (getf line :qty) (getf line :price))) :initial-value 0))"))
      (list (cons "total-correct"
                  (lambda () (score (eql 35 (service:call-in package '#:order-total lines)))))
            (cons "restored-exactly"
                  ;; Rollback in an image is exact and costs nothing. A rewrite
                  ;; that merely computes the same thing scores the other two.
                  (lambda ()
                    (score (equal good
                                  (ledger:latest-source
                                   (image:image-ledger backend)
                                   "DEFUN VIVARIUM.TASK.T13::ORDER-TOTAL")))))
            (cons "lines-intact"
                  (lambda () (score (equal lines (service:value-in package '#:*lines*)))))))))
