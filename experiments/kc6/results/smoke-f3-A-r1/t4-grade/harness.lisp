;;;; Parent and child constructors. The child shares the parent's world --
;;;; read the copy list carefully, or better, run it.

(defstruct tool name)

(defvar *base* '())

(defun register (tool)
  (setf *base*
        (cons tool (remove (tool-name tool) *base*
                           :key #'tool-name :test #'string=)))
  tool)

(register (make-tool :name "read"))
(register (make-tool :name "edit"))
(register (make-tool :name "grep"))

(defvar audit-tool (make-tool :name "audit"))

(defun tool-names (agent) (mapcar #'tool-name (getf agent :tools)))

(defun make-workspace-agent (&key extras)
  (list :tools (append *base* extras) :extras extras))

(defun sub-agent (parent)
  (declare (ignore parent))
  ;; Rebuilt from the base registry: whatever the parent was handed as
  ;; :extras is not in the copy list.
  (list :tools *base* :extras '()))
