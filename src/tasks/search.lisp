;;;; The matched pair: search state that has value, and search state that does not.
;;;;
;;;; B10 stage 1 established that run length is not path-dependence. T18 and T20
;;;; ran nine and twelve turns and returned identical scores in all three arms on
;;;; all five pairs, which means their outcome did not depend on what the agent
;;;; knew at the checkpoint. A task like that has no power to measure what
;;;; accumulated investigation is worth, however long it takes.
;;;;
;;;; These two are built to be compared against EACH OTHER rather than against a
;;;; control alone, because "A1 is slower than control" cannot separate lost
;;;; cognition from generic restart behaviour. A matched pair can:
;;;;
;;;;   T22  PATH-DEPENDENT    six suspects, five innocent, the defect is an
;;;;                          ORDERING interaction between two of them.
;;;;                          Progress is made by ELIMINATION, and the ledger
;;;;                          records installs, never rejections.
;;;;   T23  PATH-INDEPENDENT  the same six-definition pipeline, the same amount
;;;;                          of code to read, but the defect is visible in one
;;;;                          definition. Progress is made by READING.
;;;;
;;;; so the quantity of interest is a difference of differences:
;;;;
;;;;     recovery effect on T22  -  recovery effect on T23
;;;;
;;;; which is meaningful where a raw token delta is not. If recovery costs the
;;;; same on both, the restart machinery explains it. If it costs more on T22
;;;; alone, the thing lost was the elimination.
;;;;
;;;; NOTHING IS WITHHELD FROM EITHER ARM. Every definition can be called with any
;;;; probe input, as many times as an agent likes, before or after the
;;;; checkpoint. No observation is one-shot. Recovery is never doomed -- it is
;;;; only, possibly, made to pay again. That is the line family D's header draws,
;;;; and these sit deliberately on the permitted side of it.

(in-package #:viva.tasks)

;;; T22 -- the defect is in the COMPOSITION, not in any of the parts
;;;
;;; Each of the six helpers is correct in isolation, so testing them one at a
;;; time eliminates rather than finds. The order matters because a flat discount
;;; does not commute with a proportional tax: (base - d) * 6/5 is not
;;; base * 6/5 - d for any non-zero d, which is why only discounted invoices are
;;; wrong and most invoices look fine.

(deftask :t22 (:family :d-depth :split :train :package "VIVA.TASK.T22")
  "INVOICE-TOTAL is wrong for some invoices and right for most.

The pipeline is LINE-SUBTOTAL, APPLY-DISCOUNT, APPLY-TAX, ROUND-CENTS,
CONVERT-CURRENCY and SUM-INVOICE. Every one of them can be called directly with
whatever inputs you like. *INVOICES* holds 300 of them.

Find why, and fix it."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *invoices*
  (let ((out '()))
    (dotimes (i 300 (nreverse out))
      (push (list :id i
                  :qty (1+ (mod i 5))
                  :price (+ 10 (mod i 7))
                  :discount (if (zerop (mod i 3)) 4 0)
                  :rate 1)
            out))))"
           "(defun line-subtotal (invoice)
  (* (getf invoice :qty) (getf invoice :price)))"
           "(defun apply-discount (amount discount) (- amount discount))"
           "(defun apply-tax (amount) (/ (* amount 6) 5))"
           "(defun round-cents (amount) (round amount))"
           "(defun convert-currency (amount rate) (* amount rate))"
           ;; The whole defect: tax before discount. Every part above is right.
           "(defun sum-invoice (invoice)
  (round-cents
   (convert-currency
    (apply-discount (apply-tax (line-subtotal invoice)) (getf invoice :discount))
    (getf invoice :rate))))"
           "(defun invoice-total ()
  (reduce #'+ *invoices* :key #'sum-invoice :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((invoices (service:value-in package '#:*invoices*))
             (spec (lambda (invoice)
                     ;; discount first, then tax.
                     (round (/ (* (- (* (getf invoice :qty) (getf invoice :price))
                                     (getf invoice :discount))
                                  6)
                               5))))
             (expected (reduce #'+ invoices :key spec :initial-value 0))
             (discounted (find-if (lambda (i) (plusp (getf i :discount))) invoices))
             (plain (find-if (lambda (i) (zerop (getf i :discount))) invoices)))
        (list (cons "discounted-invoice-correct"
                    (lambda () (score (eql (funcall spec discounted)
                                           (try '#:sum-invoice discounted)))))
              (cons "plain-invoice-unchanged"
                    ;; Most invoices were always right. A repair that breaks
                    ;; them has traded one defect for another.
                    (lambda () (score (eql (funcall spec plain)
                                           (try '#:sum-invoice plain)))))
              (cons "total-correct"
                    (lambda () (score (eql expected (try '#:invoice-total)))))
              (cons "innocent-parts-untouched"
                    ;; Five of the six were never wrong. An agent that chased a
                    ;; hypothesis into the image fails here even if the total
                    ;; comes out right -- which is what makes elimination worth
                    ;; doing rather than guessing.
                    (lambda ()
                      (score (and (eql 6 (try '#:line-subtotal (list :qty 2 :price 3)))
                                  (eql 7 (try '#:apply-discount 10 3))
                                  (eql 12 (try '#:apply-tax 10))
                                  (eql 3 (try '#:round-cents 11/4))
                                  (eql 20 (try '#:convert-currency 10 2))))))
              (cons "invoices-intact"
                    (lambda () (score (eql 300 (length (service:value-in package '#:*invoices*)))))))))))

;;; T23 -- matched control: the same shape, but reading finds it
;;;
;;; Same six definitions, same pipeline, same volume of code to read, same
;;; "wrong for some, right for most" symptom. The difference is that the defect
;;; lives inside one definition and is visible on inspection, so no sequence of
;;; eliminations has to be accumulated and nothing valuable is held outside the
;;; ledger. Recovery should cost about the same here as continuing does.

(deftask :t23 (:family :d-depth :split :train :package "VIVA.TASK.T23")
  "SHIPMENT-TOTAL is wrong for some shipments and right for most.

The pipeline is PARCEL-WEIGHT, BAND-FOR, RATE-FOR, SURCHARGE-FOR, ROUND-UNITS
and SUM-SHIPMENT. Every one of them can be called directly with whatever inputs
you like. *SHIPMENTS* holds 300 of them.

Find why, and fix it."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *shipments*
  (let ((out '()))
    (dotimes (i 300 (nreverse out))
      (push (list :id i
                  :items (1+ (mod i 5))
                  :each (+ 2 (mod i 4))
                  :express (zerop (mod i 3)))
            out))))"
           "(defun parcel-weight (shipment)
  (* (getf shipment :items) (getf shipment :each)))"
           "(defun band-for (weight) (if (> weight 10) :heavy :light))"
           "(defun rate-for (band) (ecase band (:light 2) (:heavy 3)))"
           ;; The whole defect, and it is legible in this definition alone:
           ;; express is charged the standard surcharge instead of double.
           "(defun surcharge-for (express) (declare (ignore express)) 5)"
           "(defun round-units (amount) (round amount))"
           "(defun sum-shipment (shipment)
  (let ((weight (parcel-weight shipment)))
    (round-units (+ (* weight (rate-for (band-for weight)))
                    (surcharge-for (getf shipment :express))))))"
           "(defun shipment-total ()
  (reduce #'+ *shipments* :key #'sum-shipment :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (let* ((shipments (service:value-in package '#:*shipments*))
             (spec (lambda (shipment)
                     (let ((weight (* (getf shipment :items) (getf shipment :each))))
                       (+ (* weight (if (> weight 10) 3 2))
                          (if (getf shipment :express) 10 5)))))
             (expected (reduce #'+ shipments :key spec :initial-value 0))
             (express (find-if (lambda (s) (getf s :express)) shipments))
             (standard (find-if-not (lambda (s) (getf s :express)) shipments)))
        (list (cons "express-shipment-correct"
                    (lambda () (score (eql (funcall spec express)
                                           (try '#:sum-shipment express)))))
              (cons "standard-shipment-unchanged"
                    (lambda () (score (eql (funcall spec standard)
                                           (try '#:sum-shipment standard)))))
              (cons "total-correct"
                    (lambda () (score (eql expected (try '#:shipment-total)))))
              (cons "innocent-parts-untouched"
                    (lambda ()
                      (score (and (eql 6 (try '#:parcel-weight (list :items 2 :each 3)))
                                  (eq :heavy (try '#:band-for 11))
                                  (eq :light (try '#:band-for 10))
                                  (eql 2 (try '#:rate-for :light))
                                  (eql 3 (try '#:round-units 11/4))))))
              (cons "shipments-intact"
                    (lambda () (score (eql 300 (length (service:value-in package '#:*shipments*)))))))))))
