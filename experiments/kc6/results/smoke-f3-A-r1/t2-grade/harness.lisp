;;;; A harness whose reviewer agent sees a FILTERED registry.

(defstruct tool name)

(defvar *registry* '())

(defun register (tool)
  (setf *registry*
        (cons tool (remove (tool-name tool) *registry*
                           :key #'tool-name :test #'string=)))
  tool)

(register (make-tool :name "read"))
(register (make-tool :name "edit"))
(register (make-tool :name "grep"))
(register (make-tool :name "bash"))
(register (make-tool :name "remember"))
(register (make-tool :name "search"))
;; Re-registration replaces by name: still exactly one "read".
(register (make-tool :name "read"))

(defun tool-names (tools) (mapcar #'tool-name tools))

(defun make-agent (&key active)
  (if active
      (remove-if-not (lambda (tool) (member (tool-name tool) active :test #'string=))
                     *registry*)
      *registry*))

(defun make-reviewer-agent ()
  ;; "comment" is in the active list and registered nowhere: the filter
  ;; keeps what exists, it does not create what does not.
  (make-agent :active '("read" "grep" "comment" "search")))
