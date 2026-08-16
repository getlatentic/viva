(defpackage #:mini.tools
  (:use #:cl)
  (:local-nicknames (#:actor #:mini.actor))
  (:export #:resolve #:install))

(in-package #:mini.tools)

;; This package has its OWN transition. Same name, different symbol.
(defun transition (phase) (list :tool-phase phase))

(defun resolve (name)
  (transition (list :resolving name)))

(defun install (name)
  (actor:spawn name))
