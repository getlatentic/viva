(require :asdf)
(asdf:initialize-source-registry
 (list :source-registry (list :directory "/Users/dev/workspace/vivarium/") :inherit-configuration))
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "vivarium/tasks") (asdf:load-system "vivarium/cli"))
(in-package #:cl-user)

(defpackage #:esc (:use #:cl))
(in-package #:esc)
(defun rate-for (x) (* x 2))
(defparameter *world* :untouched)

(in-package #:cl-user)
(setf vivarium.inspect:*package-under-inspection* (find-package '#:esc)
      vivarium.inspect:*callable* (vivarium.inspect:capture-callables
                                   (find-package '#:esc) '("RATE-FOR")))
(vivarium.inspect:begin-inspection-session)

(defvar *backend* (make-instance 'vivarium.image:sbcl-image :package "ESC"))

(defun try (tool &rest kv)
  (let ((args (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k args) v))
    (let* ((vivarium.image-tools:*backend* *backend*)
           (r (vivarium.tool:execute tool args nil)))
      (if (stringp r)
          (format nil "ALLOWED -> ~a" (substitute #\Space #\Newline (subseq r 0 (min 60 (length r)))))
          (format nil "~:[ALLOWED~;REFUSED~] -> ~a" (vivarium.tool:tool-result-error-p r)
                  (substitute #\Space #\Newline
                              (let ((o (vivarium.tool:tool-result-output r)))
                                (subseq o 0 (min 80 (length o))))))))))

(format t "~&==== ESCAPE ROUTES (all but the last two MUST be REFUSED) ====~%")
(macrolet ((row (label form) `(format t "~&~42a ~a~%" ,label ,form)))
  (row "1 defparameter as execution channel"
       (try vivarium.inspect:install-definition "source" "(defparameter *world* (setf *world* :pwned))"))
  (row "1b progn wrapper"
       (try vivarium.inspect:install-definition "source" "(progn (setf *world* :pwned))"))
  (row "1c eval-when"
       (try vivarium.inspect:install-definition "source" "(eval-when (:compile-toplevel) 1)"))
  (row "1d two forms in one payload"
       (try vivarium.inspect:install-definition "source" "(defun a () 1) (defparameter *world* :pwned)"))
  (row "1e read-time eval #."
       (try vivarium.inspect:install-definition "source" "(defun a () #.(setf cl-user::*x* 1))"))
  (row "2 invoke a NEW function via inspect_value"
       (progn (try vivarium.inspect:install-definition "source" "(defun helper () :ran)")
              (try vivarium.inspect:inspect-value "target" "HELPER")))
  (row "3 REDEFINE an old name, then invoke it"
       (progn (try vivarium.inspect:install-definition "source" "(defun rate-for (x) (setf *world* :pwned) x)")
              (try vivarium.inspect:inspect-value "target" "RATE-FOR" "args" (vector "3"))))
  (row "POSITIVE: read a variable"
       (try vivarium.inspect:inspect-value "target" "*WORLD*"))
  (row "POSITIVE: install a plain DEFUN"
       (try vivarium.inspect:install-definition "source" "(defun audit (id) id)")))
(format t "~&~%world is: ~a  (must be UNTOUCHED)~%" (symbol-value (find-symbol "*WORLD*" '#:esc)))
