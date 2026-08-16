(defpackage #:mini.kernel
  (:use #:cl)
  (:export #:transition #:replay #:machine-state))

(in-package #:mini.kernel)

(defun step-once (state) (list :stepped state))

(defun transition (state message)
  (step-once (cons message state)))

(defun replay (events)
  (loop for event in events
        for state = (transition '() event) then (transition state event)
        finally (return state)))

(defun machine-state (state) (getf state :now))
