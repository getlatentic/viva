;;;; Family A-flight: work captured mid-transition.
;;;;
;;;; Modelled as state rather than run as traffic, and that is forced. E1
;;;; measured that SBCL refuses to fork with more than one thread running, and
;;;; CHECK-ZYGOTE enforces it, so a fixture that spawns a server cannot be scored
;;;; in a trial at all. What survives the modelling is the property that matters:
;;;; a restart destroys it and there is no source to rebuild it from.

(in-package #:vivarium.tasks)

;;; T7

(deftask :t7 (:family :a-flight :split :train :package "VIVARIUM.TASK.T7")
  "Forty orders are stuck part-way through in *PENDING*. Each is a plist with a
:STAGE.

ADVANCE-ALL only knows how to move an order whose stage is :STARTED. It signals
on the rest, so the queue has stopped draining and nothing behind it is moving.

Fix ADVANCE-ALL so every pending order reaches stage :COMPLETE. An order at
:STARTED completes with its :AMOUNT; an order at :DEFERRED has a :THUNK that
must be called to produce its amount."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-pending package)
    (service:install-all
     backend
     (list "(defun advance-all ()
  (maphash (lambda (id order)
             (declare (ignore id))
             (setf (getf order :stage) :complete)
             (setf (getf order :amount) (getf order :amount)))
           *pending*)
  (hash-table-count *pending*))")))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((pending (service:value-in package '#:*pending*))
           (count (hash-table-count pending))
           (snapshot (loop for id being the hash-keys of pending using (hash-value order)
                           collect (cons id (copy-list order))))
           (expected (let ((table (make-hash-table :test #'eql)))
                       (maphash (lambda (id order)
                                  (setf (gethash id table)
                                        (if (eq :deferred (getf order :stage))
                                            (funcall (getf order :thunk))
                                            (getf order :amount))))
                                pending)
                       table)))
      (flet ((drive ()
               ;; Restore before invoking. A case that leaves the queue advanced
               ;; changes what every later case sees -- run the broken version
               ;; first and it marks everything :COMPLETE, so the fixed version
               ;; never takes the :DEFERRED branch again and a correct repair
               ;; scores as a failure. A case must observe, or act from a known
               ;; state; it must not depend on running first.
               (let ((live (service:value-in package '#:*pending*)))
                 (clrhash live)
                 (loop for (id . order) in snapshot
                       do (setf (gethash id live) (copy-list order))))
               (ignore-errors (service:call-in package '#:advance-all))
               (service:value-in package '#:*pending*)))
        (list (cons "orders-intact"
                    ;; Observes, and deliberately does not restore: this is the
                    ;; case that catches a repair which drained the queue away.
                    (lambda () (intact-p package '#:*pending* count)))
              (cons "all-complete"
                    (lambda ()
                      (let ((live (drive)))
                        (scored-fraction
                         (loop for order being the hash-values of live
                               count (eq :complete (getf order :stage)))
                         count))))
              (cons "amounts-correct"
                    (lambda ()
                      (let ((live (drive)))
                        (scored-fraction
                         (loop for id being the hash-keys of live using (hash-value order)
                               count (eql (gethash id expected) (getf order :amount)))
                         count)))))))))

;;; T8

(deftask :t8 (:family :a-flight :split :held-out :package "VIVARIUM.TASK.T8")
  "*DEFERRED* holds closures. Each captured values from the request that queued
it, and those values exist nowhere else -- not in a file, not in a database, only
in the closure.

DRAIN-DEFERRED returns the closures instead of calling them, so nothing has ever
actually run.

Fix it to return the list of results, in key order, leaving *DEFERRED* itself
untouched so a failed drain can be retried."
  (lambda (backend package)
    (service:install-all
     backend
     (list "(defparameter *deferred* (make-hash-table :test #'eql))"
           "(defun drain-deferred ()
  (loop for key in (sort (loop for k being the hash-keys of *deferred* collect k) #'<)
        collect (gethash key *deferred*)))"))
    (let ((table (service:value-in package '#:*deferred*))
          (random-state (service:seeded 31337)))
      (clrhash table)
      (dotimes (key 25)
        (let ((captured (1+ (random 100 random-state))))
          (setf (gethash key table) (lambda () (* captured captured)))))))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((table (service:value-in package '#:*deferred*))
           (count (hash-table-count table))
           (expected (loop for key in (sort (loop for k being the hash-keys of table collect k) #'<)
                           collect (funcall (gethash key table)))))
      (list (cons "closures-intact"
                  (lambda () (intact-p package '#:*deferred* count)))
            (cons "all-invoked"
                  (lambda ()
                    (let ((got (ignore-errors (service:call-in package '#:drain-deferred))))
                      (score (and (listp got)
                                  (= (length got) count)
                                  (every #'numberp got))))))
            (cons "results-correct"
                  (lambda ()
                    (let ((got (ignore-errors (service:call-in package '#:drain-deferred))))
                      (score (equal expected got)))))))))
