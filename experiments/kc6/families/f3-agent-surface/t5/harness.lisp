;;;; Flags, an extension, an active filter, and a child that keeps only
;;;; what is shared. Every trap in this family, composed.

(defstruct tool name)

(defvar *registry* '())

(defun register (tool)
  (setf *registry*
        (cons tool (remove (tool-name tool) *registry*
                           :key #'tool-name :test #'string=)))
  tool)

(defmacro deftool (var &key name)
  `(defvar ,var (make-tool :name (or ,name (string-downcase (symbol-name ',var))))))

(deftool read-tool :name "read")
(deftool edit-tool :name "edit")
(deftool find-tool :name "search")
(deftool write-tool :name "write")
(deftool bash-tool :name "bash")

(register read-tool)
(register edit-tool)
(register find-tool)

(defun enable-shell ()
  ;; Nothing calls this.
  (register bash-tool))

(defparameter +unshared+ '("audit-log")
  "Lead-only tools; a child never receives them.")

(defun tool-names (agent) (mapcar #'tool-name (getf agent :tools)))

(defun make-lead-agent ()
  (load "extension.lisp")
  (let ((active '("read" "search" "audit-log" "delegate")))
    (list :tools (remove-if-not (lambda (tool)
                                  (member (tool-name tool) active :test #'string=))
                                *registry*))))

(defun sub-agent (parent)
  (list :tools (remove-if (lambda (tool)
                            (member (tool-name tool) +unshared+ :test #'string=))
                          (getf parent :tools))))
