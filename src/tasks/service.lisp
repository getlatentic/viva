;;;; The substrate a task's state accumulates in.
;;;;
;;;; A small order service, and the seeded generators that fill it. The split
;;;; that matters: the DEFINITIONS go in through the ledger, so the agent can
;;;; read, replace and roll them back; the STATE is built by calling in
;;;; afterwards, so no source records it. That is the whole asymmetry the task
;;;; set is built to measure -- a harness that reloads from source gets the
;;;; definitions back and the state never.
;;;;
;;;; Single-threaded throughout, and not by taste: CHECK-ZYGOTE refuses to fork
;;;; a trial when more than one thread is running, so a fixture that spawns one
;;;; cannot be scored at all.

(in-package #:viva.service)

(defun fresh-package (name)
  "A task owns its package outright, so one task cannot see another's damage."
  (a:when-let ((existing (find-package name)))
    (delete-package existing))
  (make-package name :use '(#:common-lisp)))

(defun sym (package name)
  (or (find-symbol (string name) package)
      (error "~a is not present in ~a" name package)))

(defun call-in (package name &rest arguments)
  "Call into the image. Every case scores through this rather than by reading
what the agent said it did."
  (apply (symbol-function (sym package name)) arguments))

(defun value-in (package name) (symbol-value (sym package name)))

(defun set-value-in (package name value) (setf (symbol-value (sym package name)) value))

(defun seeded (seed) (sb-ext:seed-random-state seed))

(defun install-all (backend sources)
  "Install definitions in order, signalling on the first that will not compile.
A fixture that half-installs produces a task whose failure looks like the
agent's."
  (dolist (source sources)
    (let ((result (image:install-definition backend source :note "fixture")))
      (when (image:installation-error result)
        (error "Fixture definition failed to install: ~a~%~a"
               (image:installation-error result) source)))))

;;; The event substrate
;;;
;;; Three kinds, and the proportions carry the experiment. :COMP has a NIL price
;;; and is common enough to be found by anyone who looks. :REFUND is rare on
;;; purpose -- three in five thousand -- so a fix derived from reading the source
;;; misses it and a fix derived from the live data does not.

(defparameter +event-substrate+
  '("(defstruct (event (:conc-name event-)) (id 0) (kind :sale) (qty 1) (price 0) (sku \"\"))"
    "(defparameter *events* (make-array 0 :adjustable t :fill-pointer t))"
    "(defparameter *cache* (make-hash-table :test #'equal))"
    "(defparameter *pending* (make-hash-table :test #'eql))")
  "Declarations only. Every one is empty until a builder fills it.")

(defparameter +session-substrate+
  '("(defclass session () ((id :initarg :id :accessor session-id)
                           (orders :initarg :orders :initform '() :accessor session-orders)))"
    "(defparameter *sessions* (make-hash-table :test #'eql))"))

(defun build-events (package &key (count 5000) (seed 20260808) (refunds 3))
  "Fill *EVENTS* deterministically. Returns the reference revenue, computed here
so a case never has to trust the definition it is scoring."
  (let ((random-state (seeded seed))
        (events (value-in package '#:*events*))
        (make (symbol-function (sym package '#:make-event)))
        (refund-at '()))
    (setf (fill-pointer events) 0)
    (dotimes (index refunds)
      (push (+ 137 (* index 1511)) refund-at))
    (dotimes (id count)
      (let* ((refund-p (member id refund-at))
             (comp-p (and (not refund-p) (zerop (mod id 17))))
             (qty (1+ (random 9 random-state)))
             (price (cond (comp-p nil)
                          (refund-p (- (1+ (random 50 random-state))))
                          (t (1+ (random 50 random-state))))))
        (vector-push-extend (funcall make :id id
                                          :kind (cond (refund-p :refund) (comp-p :comp) (t :sale))
                                          :qty qty :price price
                                          ;; A fresh string per event on purpose:
                                          ;; 47 distinct SKUs across 5000 objects.
                                          ;; Counting them with EQL rather than
                                          ;; EQUAL gives 5000, and T16 turns on
                                          ;; exactly that difference.
                                          :sku (format nil "SKU-~2,'0d" (mod id 47)))
                            events)))
    (values (reference-revenue package) refund-at)))

(defun reference-revenue (package)
  "Total revenue computed independently of anything the agent may install."
  (let ((qty-of (symbol-function (sym package '#:event-qty)))
        (price-of (symbol-function (sym package '#:event-price))))
    (reduce #'+ (value-in package '#:*events*)
            :key (lambda (event)
                   (let ((price (funcall price-of event)))
                     (if price (* (funcall qty-of event) price) 0)))
            :initial-value 0)))

(defun event-count (package) (length (value-in package '#:*events*)))

(defun distinct-skus (package)
  (let ((of (symbol-function (sym package '#:event-sku))))
    (length (remove-duplicates (map 'list of (value-in package '#:*events*))
                               :test #'equal))))

(defun refund-ids (package)
  (let ((kind-of (symbol-function (sym package '#:event-kind)))
        (id-of (symbol-function (sym package '#:event-id))))
    (loop for event across (value-in package '#:*events*)
          when (eq :refund (funcall kind-of event))
            collect (funcall id-of event))))

(defun build-cache (package &key (count 2000) (seed 4242))
  "A warm memo table. Its entries are the state a reload destroys."
  (let ((random-state (seeded seed))
        (cache (value-in package '#:*cache*)))
    (clrhash cache)
    (dotimes (key count)
      (setf (gethash key cache) (* (1+ (random 50 random-state)) 100)))
    (hash-table-count cache)))

(defun build-sessions (package &key (count 300) (seed 99))
  "Live CLOS instances. T3 redefines their class underneath them, which is the
one repair a restart cannot even attempt -- there would be no instances left."
  (let ((random-state (seeded seed))
        (sessions (value-in package '#:*sessions*))
        (class (find-class (sym package '#:session))))
    (clrhash sessions)
    (dotimes (id count)
      (setf (gethash id sessions)
            (make-instance class :id id
                                 :orders (loop repeat (1+ (random 5 random-state))
                                               collect (1+ (random 100 random-state))))))
    (hash-table-count sessions)))

(defun build-pending (package &key (count 40) (seed 7))
  "Operations captured mid-transition, half of them as closures over values that
exist nowhere else. A closure is the purest case: source cannot reconstruct the
environment it captured."
  (let ((random-state (seeded seed))
        (pending (value-in package '#:*pending*)))
    (clrhash pending)
    (dotimes (id count)
      (let ((amount (1+ (random 20 random-state))))
        (setf (gethash id pending)
              (if (evenp id)
                  (list :stage :started :amount amount)
                  (list :stage :deferred :thunk (lambda () (* amount 3)))))))
    (hash-table-count pending)))
