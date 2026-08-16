;;;; Frame layouts per protocol version.

(defpackage #:kc6.codec (:use #:cl))
(in-package #:kc6.codec)

(defun frame-layout (version)
  (let ((table (list :magic #x7643)))
    (ecase version
      (:v1 (list* :header 12 table))
      (:v2 (list* :header 16 table)))))
