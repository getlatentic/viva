;;;; The SBCL half of B7 probe 3.
;;;;
;;;; Pharo's argument names and method comment turned out to live in the
;;;; .changes file rather than in the image: move it away and the same live
;;;; method reports #(#arg1 #arg2) and a nil comment. This asks the matching
;;;; question of SBCL -- a function defined at RUNTIME from a string, with no
;;;; source file in existence, saved into a core and read back in a process
;;;; that never sees any source.

(require :sb-introspect)

(eval (read-from-string "
(defun order-total (line-items &key (tax 0.0))
  \"Total a list of line items and apply a tax rate.\"
  (* (reduce #'+ line-items) (+ 1 tax)))"))

(defun probe-schema (tag)
  (format t "~%=== ~a ===~%" tag)
  (format t "lambda-list : ~s~%" (sb-introspect:function-lambda-list 'order-total))
  (format t "ftype       : ~s~%" (sb-introspect:function-type 'order-total))
  (format t "docstring   : ~s~%" (documentation 'order-total 'function))
  (format t "runs        : ~s~%" (order-total '(10 20 5) :tax 0.2)))

(probe-schema "live image, defined from a string, no source file")

(sb-ext:save-lisp-and-die
 "schema.core"
 :executable t
 :toplevel (lambda ()
             (probe-schema "restored from core, source file deleted")
             (sb-ext:quit)))
