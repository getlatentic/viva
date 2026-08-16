(defpackage #:mini.ledger
  (:use #:cl)
  (:local-nicknames (#:kernel #:mini.kernel))
  (:export #:record #:reconstruct))

(in-package #:mini.ledger)

(defvar *log* '())

(defun record (entry)
  (push entry *log*)
  entry)

(defun reconstruct ()
  (kernel:replay (reverse *log*)))
