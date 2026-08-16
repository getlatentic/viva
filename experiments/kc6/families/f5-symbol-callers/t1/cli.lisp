(defpackage #:mini.cli
  (:use #:cl)
  (:local-nicknames (#:actor #:mini.actor)
                    (#:tools #:mini.tools)
                    (#:kernel #:mini.kernel)))

(in-package #:mini.cli)

;; Dispatch reaches kernel:replay only through mini.ledger:reconstruct,
;; never directly from here.
(defvar *replayer* (function kernel:replay))

(defun main (command id)
  (case command
    (:spawn (actor:spawn id))
    (:tell (actor:tell (actor:spawn id) (list :note id)))
    (:resolve (tools:resolve id))
    (:install (tools:install id))))
