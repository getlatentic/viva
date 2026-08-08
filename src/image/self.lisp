;;;; Tools with which an agent changes itself.
;;;;
;;;; The reason this can be three small functions rather than a subsystem is
;;;; that the agent is a live object and a tool schema is derived from a live
;;;; function. An agent installs a DEFUN, points this at it, and has a new
;;;; capability on its very next request -- no schema written, no restart, no
;;;; file. In a file-based harness the equivalent is editing the harness source
;;;; and starting again.
;;;;
;;;; The base prompt and the base tools are deliberately out of reach. A floor
;;;; the agent cannot edit is what makes a bad self-edit recoverable.

(in-package #:vivarium.self)

(defvar *agent* nil
  "The agent currently running, bound by WITH-SELF-EXTENSION.")

(defun current-agent ()
  (or *agent* (error "No agent bound. Wrap the run in VIVARIUM.SELF:WITH-SELF-EXTENSION.")))

(defmacro with-self-extension ((agent) &body body)
  "Let the tools in this file act on AGENT for the duration of BODY."
  `(let ((*agent* ,agent)) ,@body))

(defun add-tool (agent tool)
  "Replace any tool of the same name, so re-registering is a redefinition
rather than a second entry the model has to choose between."
  (setf (agent:tools agent)
        (cons tool (remove (tool:tool-name tool) (agent:tools agent)
                           :key #'tool:tool-name :test #'string=)))
  tool)

(tool:define-tool register-tool (args context)
  :description "Turn a function you have installed into a tool you can call on
your next step. Its arguments and description are read from the function itself,
so there is no schema to write."
  :parameters (("target" :string "The definition to expose, e.g. \"DEFUN SHOP::SHIPPING-COST\"" :required-p t)
               ("name" :string "Optional tool name; defaults to the function name" :required-p nil))
  (let* ((target (gethash "target" args))
         (symbol (image:definition-symbol target)))
    (cond ((null symbol)
           (tool:make-tool-result
            :output (format nil "No such definition: ~a" target) :error-p t))
          ((not (fboundp symbol))
           (tool:make-tool-result
            :output (format nil "~a is not a function." symbol) :error-p t))
          (t
           (let ((tool (derive:derive-tool symbol :name (gethash "name" args))))
             (add-tool (current-agent) tool)
             (format nil "Registered ~a. It takes: ~{~a~^, ~}. You can call it now."
                     (tool:tool-name tool)
                     (or (mapcar #'schema:parameter-label (tool:tool-parameters tool))
                         (list "no arguments"))))))))

(tool:define-tool remember (args context)
  :description "Add a standing instruction to your own prompt. It applies from
your next step onward and for the rest of this run."
  :parameters (("instruction" :string "One line you want to keep in mind" :required-p t))
  (let ((agent (current-agent))
        (instruction (gethash "instruction" args)))
    (setf (agent:system-prompt agent)
          (format nil "~a~%~%Note to self: ~a" (agent:system-prompt agent) instruction))
    (format nil "Noted: ~a" instruction)))

(defun tool-set ()
  (list register-tool remember))
