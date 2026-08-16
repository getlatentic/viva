(defpackage #:mini.actor
  (:use #:cl)
  (:local-nicknames (#:kernel #:mini.kernel)
                    (#:ledger #:mini.ledger))
  (:export #:spawn #:tell))

(in-package #:mini.actor)

(defun spawn (id)
  (list :cell id (kernel:transition '() (list :spawned id))))

(defun tell (cell message)
  (ledger:record message)
  (kernel:transition (third cell) message))
