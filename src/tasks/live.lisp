;;;; Family A-live: the fix is only derivable from the data that is there.
;;;;
;;;; Same root asymmetry as A-state, approached from the other side. The state
;;;; is not what must survive here, it is what must be READ -- and it was
;;;; produced by a history of calls that no source records, so a harness working
;;;; from source alone is guessing about a distribution it cannot see.

(in-package #:vivarium.tasks)

;;; T4

(deftask :t4 (:family :a-live :split :train :package "VIVARIUM.TASK.T4")
  "NET-TOTAL is wrong, and every test anyone wrote for it passes.

It takes the absolute value of each price before multiplying. Look at what is
actually in *EVENTS* before deciding whether that matters.

Fix NET-TOTAL so it returns the true net figure."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-events package)
    (service:install-all
     backend
     (list "(defun net-total ()
  (reduce #'+ *events*
          :key (lambda (event)
                 (let ((price (or (event-price event) 0)))
                   (* (event-qty event) (abs price))))
          :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((expected (service:reference-revenue package))
           (refunds (service:refund-ids package))
           (events (service:value-in package '#:*events*))
           (refund-weight
             (loop for event across events
                   when (eq :refund (service:call-in package '#:event-kind event))
                     sum (* (service:call-in package '#:event-qty event)
                            (service:call-in package '#:event-price event)))))
      (list (cons "net-correct"
                  (lambda () (score (eql expected (service:call-in package '#:net-total)))))
            (cons "refunds-subtract"
                  ;; The three rare events are the whole task. A fix that
                  ;; handles NIL but keeps ABS passes nothing here.
                  (lambda ()
                    (score (and (minusp refund-weight)
                                (eql expected (service:call-in package '#:net-total))))))
            (cons "refunds-still-present"
                  (lambda ()
                    (score (equal refunds (service:refund-ids package)))))))))

;;; T5

(deftask :t5 (:family :a-live :split :train :package "VIVARIUM.TASK.T5")
  "DESCRIBE-ITEM is a generic function whose methods were installed at runtime
by whatever module owned each item class. It signals for at least one class of
item that is actually in the catalogue.

The source will not tell you which classes exist -- the catalogue will.

Give every item in *CATALOGUE* a description, without changing the descriptions
the existing methods already produce."
  (lambda (backend package)
    (service:install-all
     backend
     (list "(defclass item () ((name :initarg :name :accessor item-name)))"
           "(defclass book (item) ())"
           "(defclass tool-item (item) ())"
           "(defclass gift-card (item) ())"
           "(defgeneric describe-item (item))"
           "(defmethod describe-item ((item book)) (format nil \"book: ~a\" (item-name item)))"
           "(defmethod describe-item ((item tool-item)) (format nil \"tool: ~a\" (item-name item)))"
           "(defparameter *catalogue* '())"))
    (let ((make (lambda (class name)
                  (make-instance (find-class (service:sym package class)) :name name))))
      (service:set-value-in
       package '#:*catalogue*
       (list (funcall make '#:book "Structure and Interpretation")
             (funcall make '#:tool-item "Hex Key")
             (funcall make '#:gift-card "Fifty")
             (funcall make '#:book "On Lisp")))))
  (lambda (package backend)
    (declare (ignore backend))
    (let ((catalogue (service:value-in package '#:*catalogue*)))
      (list (cons "every-item-described"
                  (lambda ()
                    (scored-fraction
                     (count-if (lambda (item)
                                 (ignore-errors
                                  (let ((text (service:call-in package '#:describe-item item)))
                                    (and (stringp text) (plusp (length text))))))
                               catalogue)
                     (length catalogue))))
            (cons "existing-methods-unchanged"
                  (lambda ()
                    (score (and (equal "book: On Lisp"
                                       (ignore-errors
                                        (service:call-in package '#:describe-item
                                                         (fourth catalogue))))
                                (equal "tool: Hex Key"
                                       (ignore-errors
                                        (service:call-in package '#:describe-item
                                                         (second catalogue))))))))
            (cons "catalogue-intact"
                  (lambda ()
                    (score (= (length catalogue)
                              (length (service:value-in package '#:*catalogue*))))))))))

;;; T6

(deftask :t6 (:family :a-live :split :held-out :package "VIVARIUM.TASK.T6")
  "AVERAGE-EVENT-VALUE truncates, and on the distribution actually flowing
through this image the lost remainder is not negligible.

Return the exact average as a rational rather than a truncated integer. Comped
events count as zero and still count toward the denominator."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-events package)
    (service:install-all
     backend
     (list "(defun average-event-value ()
  (truncate (reduce #'+ *events*
                    :key (lambda (event)
                           (let ((price (or (event-price event) 0)))
                             (* (event-qty event) price)))
                    :initial-value 0)
            (length *events*)))")))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((total (service:reference-revenue package))
           (count (service:event-count package))
           (exact (/ total count)))
      (list (cons "average-exact"
                  (lambda () (score (eql exact (service:call-in package '#:average-event-value)))))
            (cons "not-truncated"
                  (lambda ()
                    (score (/= (truncate total count)
                               (service:call-in package '#:average-event-value)))))
            (cons "events-intact"
                  (lambda () (intact-p package '#:*events* count)))))))

;;; T15 -- the shape is only in the image
;;;
;;; From a real run. Asked to fix a function over *STOCK*, an agent could not
;;; read the variable, guessed it was a hash table, and installed a GETHASH
;;; against a list of plists. The value was in the image the whole time. Here the
;;; source is deliberately mute about the shape: it says NIL.

(deftask :t15 (:family :a-live :split :train :package "VIVARIUM.TASK.T15")
  "ORDERS-FOR treats *INDEX* as an association list and returns NIL for
everything. Its declaration says only `nil`, so the source will not tell you what
it actually holds -- the running image will.

Fix ORDERS-FOR to return the list of order ids for a SKU, and NIL for a SKU that
has none. Leave *INDEX* alone."
  (lambda (backend package)
    (service:install-all
     backend
     (list "(defparameter *index* nil)"
           "(defun orders-for (sku) (cdr (assoc sku *index* :test #'string=)))"))
    (let ((table (make-hash-table :test #'equal))
          (random-state (service:seeded 515)))
      (dotimes (n 40)
        (setf (gethash (format nil "SKU-~2,'0d" n) table)
              (loop repeat (1+ (random 4 random-state)) collect (random 9999 random-state))))
      (service:set-value-in package '#:*index* table)))
  (lambda (package backend)
    (declare (ignore backend))
    (let* ((index (service:value-in package '#:*index*))
           (keys (sort (loop for k being the hash-keys of index collect k) #'string<))
           (expected (mapcar (lambda (k) (gethash k index)) keys))
           (count (hash-table-count index)))
      (list (cons "orders-correct"
                  (lambda ()
                    (scored-fraction
                     (count t (mapcar (lambda (key want)
                                        (equal want (ignore-errors
                                                     (service:call-in package '#:orders-for key))))
                                      keys expected))
                     (length keys))))
            (cons "missing-sku-is-nil"
                  (lambda ()
                    (score (null (ignore-errors
                                  (service:call-in package '#:orders-for "SKU-NOPE"))))))
            (cons "index-intact"
                  (lambda () (intact-p package '#:*index* count)))))))

;;; T16 -- a fresh process would say it is fine
;;;
;;; The trap this project keeps walking into. A new SBCL has never heard of this
;;; image, so an agent that shells out to verify is asking a stranger. Here the
;;; source declares *EVENTS* empty, so a fresh process runs the function without
;;; error and returns 0 -- a plausible answer, and the wrong one. Only calling it
;;; in this image shows the defect.

(deftask :t16 (:family :a-live :split :held-out :package "VIVARIUM.TASK.T16")
  "DISTINCT-SKUS is meant to count how many different SKUs appear in *EVENTS*.
It returns one entry per event instead.

The declaration of *EVENTS* in the source is an empty vector, so anywhere but in
this running image the function looks correct. Check it here."
  (lambda (backend package)
    (service:install-all backend service:+event-substrate+)
    (service:build-events package)
    (service:install-all
     backend
     ;; REMOVE-DUPLICATES defaults to EQL, and every SKU is a distinct string
     ;; object. On an empty vector this returns 0 and looks right.
     (list "(defun distinct-skus ()
  (length (remove-duplicates (map 'list #'event-sku *events*))))")))
  (lambda (package backend)
    (declare (ignore backend))
    (let ((expected (service:distinct-skus package))
          (events (service:event-count package)))
      (list (cons "distinct-correct"
                  (lambda () (score (eql expected
                                         (ignore-errors
                                          (service:call-in package '#:distinct-skus))))))
            (cons "not-one-per-event"
                  ;; Fails for anything that left the EQL comparison in place.
                  (lambda ()
                    (let ((got (ignore-errors (service:call-in package '#:distinct-skus))))
                      (score (and got (< got events))))))
            (cons "events-intact"
                  (lambda () (intact-p package '#:*events* events)))))))

;;; T17 -- loaded, not installed
;;;
;;; Real code arrives by LOAD, not through this harness, so the ledger has no
;;; previous source for it and READ-DEFINITION falls back to introspection. That
;;; path is load-bearing for `vivarium run` and no other task exercises it.

(deftask :t17 (:family :a-live :split :train :package "VIVARIUM.TASK.T17")
  "SHIPPING-BAND was loaded from a file rather than installed here, so this image
has no previous source for it -- only the live function itself.

It returns :HEAVY for anything over 10 kg and :LIGHT otherwise, but the boundary
is wrong: exactly 10 kg is being called heavy. Ten kilograms is light.

Fix it."
  (lambda (backend package)
    (declare (ignore backend))
    ;; Deliberately NOT through INSTALL-ALL: nothing reaches the ledger, which is
    ;; what makes this different from every other task.
    (let ((*package* (find-package package)))
      (eval (read-from-string
             "(defun shipping-band (weight) (if (>= weight 10) :heavy :light))"))))
  (lambda (package backend)
    (let ((ledger (image:image-ledger backend)))
      (list (cons "boundary-correct"
                  (lambda ()
                    (score (and (eq :light (service:call-in package '#:shipping-band 10))
                                (eq :heavy (service:call-in package '#:shipping-band 11))
                                (eq :light (service:call-in package '#:shipping-band 3))))))
            (cons "installed-through-the-image"
                  ;; The fix has to land in the image, not merely be described.
                  (lambda ()
                    (score (find "DEFUN VIVARIUM.TASK.T17::SHIPPING-BAND"
                                 (ledger:entries ledger)
                                 :key #'ledger:entry-target :test #'string=))))
            (cons "still-a-function-of-one-argument"
                  (lambda ()
                    (score (ignore-errors
                            (= 1 (length (sb-introspect:function-lambda-list
                                          (service:sym package '#:shipping-band))))))))))))
