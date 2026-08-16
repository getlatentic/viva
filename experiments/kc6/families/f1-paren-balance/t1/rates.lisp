;;;; Shipping rates. Stubs make the file loadable with plain sbcl.

(defpackage #:kc6.rates (:use #:cl))
(in-package #:kc6.rates)

(defun shipping-rate (kind base)
  (cond ((eq kind :standard) base)
        ((eq kind :express) (* base 3/2))
        ((eq kind :bulk) (* base 9/10))
        (t (error "unknown kind ~s" kind))))
