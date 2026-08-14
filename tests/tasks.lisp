;;;; Is each task actually a task?
;;;;
;;;; Two properties, and a benchmark is worthless without both: every task must
;;;; FAIL before it is fixed, and every task must PASS after a known-good fix.
;;;; The first catches a defect that was never really broken; the second catches
;;;; a case that cannot be satisfied at all, which would silently cap every
;;;; harness at the same wrong ceiling and look like a null result.
;;;;
;;;; The reference fixes below are the answer key, and they live here rather
;;;; than in the task set so nothing on the agent's path can reach them.

(in-package #:vivarium.tests)

(defparameter +reference-fixes+
  ;; task -> definitions that solve it, in install order.
  `((:t1 . ("(defun total-revenue ()
  (reduce #'+ *events*
          :key (lambda (event)
                 (let ((price (event-price event)))
                   (if price (* (event-qty event) price) 0)))
          :initial-value 0))"))
    (:e24 . ("(defparameter *quotes*
  (mapcar (lambda (q)
            (if (gethash (getf q :id) *negotiated*)
                q
                (list :id (getf q :id) :weight (getf q :weight) :zone (getf q :zone)
                      :cost (shipping-cost (getf q :weight) (getf q :zone)))))
          *quotes*))"))
    (:t2 . ("(defun price-of (key)
  (let ((raw (gethash key *cache*)))
    (if raw (- raw *discount*) 0)))"))
    (:t3 . ("(defclass session ()
  ((id :initarg :id :accessor session-id)
   (orders :initarg :orders :initform '() :accessor session-orders)
   (total :initarg :total :accessor session-total)))"
            ;; The image-native migration: CLOS calls this the first time each
            ;; obsolete instance is touched. There is no equivalent move for a
            ;; harness that had to restart -- there would be no instances left.
            "(defmethod update-instance-for-redefined-class :after
     ((session session) added discarded plist &rest initargs)
  (declare (ignore added discarded plist initargs))
  (setf (slot-value session 'total)
        (reduce #'+ (session-orders session) :initial-value 0)))"))
    (:t4 . ("(defun net-total ()
  (reduce #'+ *events*
          :key (lambda (event)
                 (let ((price (or (event-price event) 0)))
                   (* (event-qty event) price)))
          :initial-value 0))"))
    (:t5 . ("(defmethod describe-item ((item gift-card))
  (format nil \"gift card: ~a\" (item-name item)))"))
    (:t6 . ("(defun average-event-value ()
  (/ (reduce #'+ *events*
             :key (lambda (event)
                    (let ((price (or (event-price event) 0)))
                      (* (event-qty event) price)))
             :initial-value 0)
     (length *events*)))"))
    (:t7 . ("(defun advance-all ()
  (dolist (id (loop for key being the hash-keys of *pending* collect key))
    (let* ((order (gethash id *pending*))
           (amount (if (eq :deferred (getf order :stage))
                       (funcall (getf order :thunk))
                       (getf order :amount))))
      (setf (getf order :amount) amount)
      (setf (getf order :stage) :complete)
      (setf (gethash id *pending*) order)))
  (hash-table-count *pending*))"))
    (:t8 . ("(defun drain-deferred ()
  (loop for key in (sort (loop for k being the hash-keys of *deferred* collect k) #'<)
        collect (funcall (gethash key *deferred*))))"))
    (:t9 . ("(defun shipping-cost (weight zone)
  \"Cost to ship WEIGHT kilograms to ZONE.\"
  (+ (* 2 weight) (if (eq zone :b) 5 0)))"))
    (:t10 . ("(defun count-at-quantity (quantity)
  \"How many events carry exactly QUANTITY.\"
  (loop for event across *events* count (eql quantity (event-qty event))))"))
    (:t11 . ("(defun order-total (lines)
  (reduce #'+ (mapcar #'normalize-line lines)
          :key (lambda (line) (* (getf line :qty) (or (getf line :price) 0)))
          :initial-value 0))"))
    (:t12 . ("(defun shipping-cost (weight) (+ (* 2 weight) (if (> weight 10) 10 0)))"
             "(defun tax-for (subtotal zone)
  (if (eq zone :export) 0 (round (* subtotal 20) 100)))"
             "(defun discount-for (units subtotal)
  (if (>= units 100) (round (* subtotal 10) 100) 0))"))
    (:t15 . ("(defun orders-for (sku) (gethash sku *index*))"))
    (:t16 . ("(defun distinct-skus ()
  (length (remove-duplicates (map 'list #'event-sku *events*) :test #'equal)))"))
    (:t17 . ("(defun shipping-band (weight) (if (> weight 10) :heavy :light))"))
    (:t18 . ("(defun fee-for (line)
  (/ (* (getf line :units) (or (getf line :rate) 2)) 4))"
             "(defun round-cents (amount) (round amount))"))
    (:t19 . ("(defun handling-fee (items) (if (> items 20) (+ 5 (- items 20)) 5))"
             "(defun insurance-for (declared)
  (if (> declared 100) (round (* declared 2) 100) 0))"
             "(defun rush-surcharge (tier)
  (ecase tier (:next-day 25) (:two-day 10) (:ground 0)))"
             "(defun credit-for (amount days) (if (> days 30) (/ amount 2) amount))"
             "(defun round-to-cent (amount) (round amount))"))
    (:t20 . ("(defun adjust-estimated (reading value)
  (if (eq (getf reading :status) :estimated) (* value 9/10) value))"))
    (:t22 . ("(defun sum-invoice (invoice)
  (round-cents
   (convert-currency
    (apply-tax (apply-discount (line-subtotal invoice) (getf invoice :discount)))
    (getf invoice :rate))))"))
    (:t23 . ("(defun surcharge-for (express) (if express 10 5))"))
    (:t21 . ("(defun signed-amount (entry)
  (let ((amount (getf entry :amount)))
    (cond ((null amount) 0)
          ((eq (getf entry :kind) :reversal) (- amount))
          (t amount))))"))
    ;; T13 is solved by rolling back, not by installing. T14 is solved by
    ;; leaving it alone. Both are handled below.
    (:t13 . ())
    (:t14 . ())))

(defun task-scores (cases)
  "Mirrors TRIAL:SCORE-CASE, including the part that matters: a case that
signals scores NIL rather than zero. The broken definition in T1 signals a
TYPE-ERROR when called, and 'could not be run' is genuinely different
information from 'ran and scored nothing'."
  (mapcar (lambda (entry)
            (cons (car entry) (handler-case (funcall (cdr entry)) (error () nil))))
          cases))

(defun all-passing-p (scores)
  (every (lambda (entry) (eql 1.0 (float (or (cdr entry) 0)))) scores))

(defun prepare (id)
  "Set the task up and build its cases, in that order. Returns (values task
backend cases) -- cases must be built before anything acts, because a case
closes over the world it will compare against."
  (let* ((task (tasks:find-task id))
         (backend (make-instance 'image:sbcl-image :package (tasks:task-package task))))
    (tasks:setup task backend)
    (values task backend (tasks:cases-for task backend))))

(defun apply-reference-fix (id backend)
  (case id
    (:t13 (image:rollback-definition backend "DEFUN VIVARIUM.TASK.T13::ORDER-TOTAL"))
    (:t14 nil)
    (t (dolist (source (cdr (assoc id +reference-fixes+)))
         (let ((result (image:install-definition backend source :note "reference")))
           (when (image:installation-error result)
             (error "Reference fix for ~a did not install: ~a"
                    id (image:installation-error result))))))))

;;; The two properties

(define-test "every task is registered exactly once, with a fixed split"
  (is = 24 (length (tasks:all-tasks)))
  (is = 16 (length (tasks:tasks-in :train)))
  (is = 8 (length (tasks:tasks-in :held-out)))
  ;; Both halves must carry every family, or the held-out set measures
  ;; something different from the training set rather than the same thing.
  ;; E-IMPACT is the exception WHILE B14.1 RUNS: E24 is the representative
  ;; repair the three gates are measured on, and its held-out counterpart is
  ;; B14.2's work. If the gates pass and no held-out E-IMPACT task exists, the
  ;; family is incomplete and this exemption must come out, not be extended.
  (is = 9 (length (tasks:task-families)))
  (is = 1 (length (remove-if-not (lambda (task) (eq :e-impact (tasks:task-family task)))
                                 (tasks:tasks-in :train))))
  (is = 0 (length (remove-if-not (lambda (task) (eq :e-impact (tasks:task-family task)))
                                 (tasks:tasks-in :held-out)))))

(define-test "a task set up twice from scratch scores identically"
  ;; Without this the whole instrument is unusable for an A/B: a difference
  ;; between two arms could be the fixture rather than the harness, and nothing
  ;; downstream would reveal which.
  (dolist (task (tasks:all-tasks))
    (let ((id (tasks:task-id task)))
      (flet ((run ()
               (multiple-value-bind (found backend cases) (prepare id)
                 (declare (ignore found))
                 (let ((before (task-scores cases)))
                   (apply-reference-fix id backend)
                   (list before (task-scores cases))))))
        (is equalp (run) (run) (format nil "~a is not reproducible" id))))))

(define-test "no task package leaks into another"
  (let ((packages (mapcar #'tasks:task-package (tasks:all-tasks))))
    (is = (length packages) (length (remove-duplicates packages :test #'string=)))))

(define-test "a broken task actually scores badly before it is fixed"
  ;; T14 is the control -- it is supposed to pass untouched, and it is checked
  ;; on its own below.
  (dolist (task (remove :t14 (tasks:all-tasks) :key #'tasks:task-id))
    (multiple-value-bind (found backend cases) (prepare (tasks:task-id task))
      (declare (ignore found backend))
      (let ((scores (task-scores cases)))
        (false (all-passing-p scores)
               (format nil "~a passes before any fix -- it is not a task"
                       (tasks:task-id task)))))))

(define-test "every task is solvable, and the reference fix solves it completely"
  (dolist (task (tasks:all-tasks))
    (let ((id (tasks:task-id task)))
      (multiple-value-bind (found backend cases) (prepare id)
        (declare (ignore found))
        (apply-reference-fix id backend)
        (let ((scores (task-scores cases)))
          (true (all-passing-p scores)
                (format nil "~a is not solvable by its reference fix: ~a" id scores)))))))

(define-test "the control task passes untouched and fails if edited"
  (multiple-value-bind (task backend cases) (prepare :t14)
    (declare (ignore task))
    (true (all-passing-p (task-scores cases)))
    ;; Rewriting a definition that was already correct is the behaviour the
    ;; control exists to catch, and it must cost a case even when the rewrite
    ;; computes the right answer.
    (image:install-definition
     backend
     "(defun order-total (lines)
        (reduce #'+ lines :key (lambda (line) (* (getf line :qty) (or (getf line :price) 0)))
                :initial-value 0))"
     :note "an unnecessary rewrite")
    (let ((scores (task-scores cases)))
      (false (all-passing-p scores))
      (is eql 1.0 (cdr (assoc "still-correct" scores :test #'string=)))
      (is eql 0.0 (cdr (assoc "left-alone" scores :test #'string=))))))

;;; The property the whole set exists to measure

(define-test "a correct fix still scores zero on survival once the state is gone"
  ;; The file-based harness's situation reproduced directly: the definition is
  ;; right and the data it operated on is gone. Correctness and survival must be
  ;; separately visible, which is why a scalar score would destroy this
  ;; benchmark rather than merely blur it.
  (multiple-value-bind (task backend cases) (prepare :t13)
    (declare (ignore task))
    (apply-reference-fix :t13 backend)
    (true (all-passing-p (task-scores cases)))
    (service:set-value-in "VIVARIUM.TASK.T13" '#:*lines* '())
    (let ((scores (task-scores cases)))
      (is eql 0.0 (cdr (assoc "lines-intact" scores :test #'string=)))
      ;; The repaired definition is still a correct definition.
      (is eql 1.0 (cdr (assoc "total-correct" scores :test #'string=))))))

(define-test "losing accumulated state also costs the correctness cases that read it"
  ;; The stronger half, and worth pinning because it is easy to overstate the
  ;; separation above. Where correctness is defined against the accumulated
  ;; data, destroying the data fails that too -- there is nothing left to be
  ;; correct about. A reloading harness scores zero across all three of T1.
  (multiple-value-bind (task backend cases) (prepare :t1)
    (declare (ignore task))
    (apply-reference-fix :t1 backend)
    (true (all-passing-p (task-scores cases)))
    (setf (fill-pointer (service:value-in "VIVARIUM.TASK.T1" '#:*events*)) 0)
    (let ((scores (task-scores cases)))
      (is eql 0.0 (cdr (assoc "events-intact" scores :test #'string=)))
      (is eql 0.0 (cdr (assoc "event-zero-unchanged" scores :test #'string=)))
      (is eql 0.0 (cdr (assoc "revenue" scores :test #'string=))))))

(define-test "every case returns a number in [0,1], or NIL for a case that could not run"
  (dolist (task (tasks:all-tasks))
    (multiple-value-bind (found backend cases) (prepare (tasks:task-id task))
      (declare (ignore found backend))
      (dolist (entry (task-scores cases))
        (let ((score (cdr entry)))
          (true (or (null score) (and (realp score) (<= 0 score 1)))
                (format nil "~a/~a returned ~a" (tasks:task-id task) (car entry) score)))))))

;;; Contamination detection

(define-test "contamination is path-shaped, not name-shaped"
  ;; A task's own package is VIVARIUM.TASK.T11, so matching the bare product
  ;; name flags an agent doing exactly what it was asked. That version of the
  ;; detector fired on correct runs and would have discarded them.
  (let ((root "/Users/dev/workspace/vivarium/"))
    (is equal '() (tasks:contamination-in
                   (list "sbcl --eval '(vivarium.task.t11::order-total *lines*)'"
                         "ls -la"
                         "echo VIVARIUM.TASK.T11")
                   root))
    (is = 3 (length (tasks:contamination-in
                     (list "cat /Users/dev/workspace/vivarium/tests/tasks.lisp"
                           "grep -r reference tests/tasks.lisp"
                           "cd .. && ls")
                     root)))))

(define-test "a scored attempt runs its shell somewhere empty"
  ;; The jail is what stops an agent reading the answer key that sits beside it.
  (let ((a (tasks:jail-directory (tasks:find-task :t1)))
        (b (tasks:jail-directory (tasks:find-task :t1))))
    (true (probe-file a))
    (false (equal (namestring a) (namestring b)))
    (is equal '() (directory (merge-pathnames "*.*" a)))))
