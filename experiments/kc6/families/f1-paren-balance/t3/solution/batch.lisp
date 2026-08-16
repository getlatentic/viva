;;;; Batch processing. Stubs make the file loadable.

(defpackage #:kc6.batch (:use #:cl))
(in-package #:kc6.batch)

(defun acquire-lock (lock) lock)
(defun release-lock (lock) lock)
(defun stage (item) item)
(defun flush-staged () t)

(defun process-batch (items lock)
  (acquire-lock lock)
  (unwind-protect
       (progn
         (dolist (item items)
           (stage item))
         (flush-staged))
    (release-lock lock)))
