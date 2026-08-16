;;;; A harness that grows tools by loading extensions.

(defstruct tool name)

(defvar *registry* '())

(defun register (tool)
  (setf *registry*
        (cons tool (remove (tool-name tool) *registry*
                           :key #'tool-name :test #'string=)))
  tool)

(register (make-tool :name "read"))
(register (make-tool :name "edit"))

(defun tool-names (tools) (mapcar #'tool-name tools))

(defun make-instrumented-agent ()
  (load "extension.lisp")
  *registry*)
