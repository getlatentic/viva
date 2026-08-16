;;;; A gate owner, in the define-owner style. The stub macro makes the file
;;;; loadable; the clauses are data for a generator and are judged by shape.

(defpackage #:kc6.gate (:use #:cl))
(in-package #:kc6.gate)

(defmacro define-owner (name &rest clauses)
  (declare (ignore clauses))
  `(defvar ,name t))

(define-owner gate
  (:states (:closed) (:open ?count))
  (:transition ((:closed) (:open-request))
    => '(:open 1)
    (list :publish :gate.opened 1))
  (:transition ((:open ?count) (:open-request))
    => `(:open ,(1+ ?count))
    (list :publish :gate.opened (1+ ?count)))
  (:transition ((:open ?count) (:close))
    :when (= ?count 1)
    => '(:closed)
    (list :publish :gate.closed))
  (:transition ((:open ?count) (:close))
    :when (> ?count 1)
    => `(:open ,(1- ?count))
    (list :publish :gate.stepped (1- ?count))))
