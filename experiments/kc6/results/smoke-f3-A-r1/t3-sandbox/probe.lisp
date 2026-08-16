(load "config.lisp")
(load "harness.lisp")
(let ((names (sort (copy-list (tool-names (make-instrumented-agent))) #'string<)))
  (format t "~{~a~%~}" names))
