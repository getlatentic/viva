;;;; Family M: the two shapes E2 claim 1 has never been able to produce.
;;;;
;;;; Claim 1 is that merging is free, because a variant is a set of ledger
;;;; entries and conflicts are per definition rather than per line. It has no
;;;; verdict, and the reason is structural: every candidate in the existing
;;;; landscape carries exactly one definition, always the same target, so
;;;; COMPLEMENTARY-PAIR can never find a pair and CONFLICTS-BETWEEN can never
;;;; find a disagreement that means anything. No budget fixes that.
;;;;
;;;; T11 gives the census a genuine conflict -- two valid repairs that touch the
;;;; same definition differently, with neither body subsuming the other. T12
;;;; gives it a genuine clean merge -- three defects on three definitions, so two
;;;; lineages can specialise and their union is well defined.

(in-package #:viva.tasks)

;;; T11

(deftask :t11 (:family :m-conflict :split :train :package "VIVA.TASK.T11")
  "Comped lines carry a price of NIL and ORDER-TOTAL multiplies straight through
them.

The line goes through NORMALIZE-LINE on its way in, so the NIL can be dealt with
in either place: coerce it as the line is normalised, or skip it as the total is
computed. Both work. Pick one and make the total correct.

The correct total for *LINES* is 35."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *lines* (list (list :qty 2 :price 5) (list :qty 3 :price 5)
                                    (list :qty 4 :price nil) (list :qty 1 :price 10)))"
           "(defun normalize-line (line) line)"
           "(defun order-total (lines)
  (reduce #'+ (mapcar #'normalize-line lines)
          :key (lambda (line) (* (getf line :qty) (getf line :price)))
          :initial-value 0))")))
  (lambda (package backend)
    (declare (ignore backend))
    (let ((lines (service:value-in package '#:*lines*)))
      (list (cons "total-correct"
                  (lambda () (score (eql 35 (ignore-errors
                                             (service:call-in package '#:order-total lines))))))
            (cons "normalize-still-total"
                  ;; Whichever half was chosen, the pair must still compose: a
                  ;; repair that makes NORMALIZE-LINE lossy passes the total and
                  ;; fails here.
                  (lambda ()
                    (let ((one (ignore-errors
                                (service:call-in package '#:normalize-line
                                                 (list :qty 2 :price 5)))))
                      (score (and (listp one) (eql 2 (getf one :qty)) (eql 5 (getf one :price)))))))
            (cons "lines-intact"
                  (lambda () (score (eql 4 (length (service:value-in package '#:*lines*))))))))))

;;; T12

(deftask :t12 (:family :m-complement :split :held-out :package "VIVA.TASK.T12")
  "Three independent charges are each wrong, and each is wrong for a different
kind of order:

  SHIPPING-COST  ignores the surcharge above 10 kg
  TAX-FOR        applies the domestic rate to zone :EXPORT, which is untaxed
  DISCOUNT-FOR   gives no bulk discount at 100 units or more, which should be 10%

Fix what you can. They do not interact."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defun shipping-cost (weight) (* 2 weight))"
           "(defun tax-for (subtotal zone) (declare (ignore zone)) (round (* subtotal 20) 100))"
           "(defun discount-for (units subtotal) (declare (ignore units)) (declare (ignore subtotal)) 0)")))
  (lambda (package backend)
    (declare (ignore backend))
    (flet ((try (name &rest arguments)
             (ignore-errors (apply #'service:call-in package name arguments))))
      (list (cons "shipping-surcharge"
                  ;; Each case is led by a different definition, which is what
                  ;; lets two lineages specialise and then merge cleanly.
                  (lambda () (score (and (eql 20 (try '#:shipping-cost 10))
                                         (eql 40 (try '#:shipping-cost 15))))))
            (cons "export-untaxed"
                  (lambda () (score (and (eql 0 (try '#:tax-for 100 :export))
                                         (eql 20 (try '#:tax-for 100 :domestic))))))
            (cons "bulk-discount"
                  (lambda () (score (and (eql 0 (try '#:discount-for 99 1000))
                                         (eql 100 (try '#:discount-for 100 1000))))))))))
