;;;; A mini harness. The registry is the truth; reading is not running.

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
(deftool edit-tool)
(deftool grep-tool :name "grep")
(deftool write-tool :name "write")
(deftool bash-tool)
(deftool audit-tool :name "audit")
(deftool find-tool :name "search")

(register read-tool)
(register edit-tool)
(register grep-tool)
(register bash-tool)
(register find-tool)
(register (make-tool :name "remember"))

(defun enable-audit ()
  ;; Nothing calls this.
  (register audit-tool))

(defun tool-names (tools) (mapcar #'tool-name tools))

(defun make-workspace-agent () *registry*)
