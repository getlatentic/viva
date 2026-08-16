;;;; The model-facing door: five tools through which an agent can mint, keep
;;;; and run compiled capability of its own during a task.
;;;;
;;;; Everything under this file was already proven and none of it was
;;;; reachable. The evolution owner had a verified lifecycle, a witnessed door,
;;;; a durable ledger and no way for a model to enter it -- a workspace agent
;;;; saw nine tools and not one of them created, activated or ran a version.
;;;; KC6's pre-check zero is what said so out loud.
;;;;
;;;; A CAPABILITY IS (LAMBDA (INPUT) ...) -- one string in, one value out.
;;;; That constraint is deliberate and it is the whole reason this surface is
;;;; five small tools instead of a language binding. A JSON schema can describe
;;;; a string; it cannot describe an arbitrary Lisp lambda list without
;;;; teaching the model a second calling convention it will get wrong, and the
;;;; frictions this exists for -- reshape this format, parse this dialect,
;;;; normalise this output -- are string to string anyway.
;;;;
;;;; These tools live daemon-side because VIVARIUM/DAEMON depends on
;;;; VIVARIUM/WORKSPACE and not the reverse, and they reach an agent through
;;;; the :EXTRA-TOOLS seam MAKE-WORKSPACE-AGENT already has. Nothing in the
;;;; workspace layer learns about evolution.
;;;;
;;;; ARM B falls out of the table rather than out of this file: CREATE is open,
;;;; ACTIVATE and PROMOTE are refused by the door, and the refusal text says so
;;;; plainly so a competent agent stops instead of thrashing against it.

(in-package #:vivarium.actor)

;;; Task identity
;;;
;;; Pins are per task and this agent is not inside a task tree, so it needs an
;;; identity of its own -- stable for the agent's life, because a pin keyed by
;;; something that changed per turn would be a capability the agent could
;;; create and never see again.

(defvar *capability-tasks* (make-hash-table :test #'eq :weakness :key)
  "Agent -> task identity. Weak on the key: an agent that is gone takes its
entry with it, and this table is not a reason to retain one.")

(defvar *capability-lock* (bt:make-lock "vivarium.capability"))
(defvar *capability-counter* 0)

(defun agent-task (agent)
  (bt:with-lock-held (*capability-lock*)
    (or (gethash agent *capability-tasks*)
        (setf (gethash agent *capability-tasks*)
              (format nil "agent-~d" (incf *capability-counter*))))))

(defvar *capability-seen* (make-hash-table :test #'eq :weakness :key)
  "Agent -> its resolution dedup table, so first use is first use for the
agent's whole run rather than for one tool call.")

(defun agent-seen (agent)
  (bt:with-lock-held (*capability-lock*)
    (or (gethash agent *capability-seen*)
        (setf (gethash agent *capability-seen*) (make-hash-table :test #'equal)))))

(defun agent-cell (agent)
  "The session this agent belongs to, if it belongs to one. Improvement events
are the organism narrating what it did to itself, and every other one of them
reaches the session that caused it; capability use rigged its task with NIL and
reached the ledger alone, so a watching session saw its own agent rewrite
itself in silence."
  (find agent (all-cells) :key #'cell-agent))

(defmacro with-capability-context ((agent) &body body)
  "Bind what a resolution needs, here, because this is where resolution
happens. The supervisor binds the same three specials around a task worker;
a CLI agent has no supervisor and would otherwise resolve against nothing."
  (a:once-only (agent)
    `(let ((*activation-box* (task-context-box (agent-task ,agent) (agent-cell ,agent)))
           (*resolution-task* (agent-task ,agent))
           (*resolutions-seen* (agent-seen ,agent)))
       ,@body)))

(defun refusal-text (answer verb)
  "A refusal the model can act on. The door's refusal has to be unmistakable:
arm B measures the door's overhead, and an agent retrying a refusal it did not
understand would charge that thrash to the machinery."
  (if (equal answer '(:refused :door))
      (format nil "Refused: live self-modification is disabled in this ~
configuration. ~a is unavailable for this whole run -- do not retry it, and ~
solve the task with the ordinary tools." verb)
      (format nil "Refused: ~(~a~)." (second (a:ensure-list answer)))))

(defun capability-agent ()
  (or harness:*agent*
      (error "No agent is running; a capability tool cannot act.")))

;;; The tools

(tool:define-tool create-capability (args context)
  :name "create_capability"
  :description "Compile a new version of a named capability into the running
image. The source must be exactly one lambda taking one string and returning
one value, e.g. (lambda (input) (string-upcase input)).

Nothing changes until you activate it. If it does not compile you get the
error back and no version is created."
  :parameters (("name" :string "What this capability is called. Reusing a name creates a new version of it." :required-p t)
               ("source" :string "One lambda form of exactly one argument, e.g. (lambda (input) ...)" :required-p t)
               ("note" :string "One line: what this does and why" :required-p nil))
  ;; Task-independent -- create is the verb the door leaves open in every arm --
  ;; but still the session's business to see.
  (let* ((agent (capability-agent))
         (name (gethash "name" args))
         (source (gethash "source" args)))
    (multiple-value-bind (form condition)
        (handler-case (let ((*read-eval* nil))
                        ;; *READ-EVAL* nil: reading the model's text must not
                        ;; execute it. Compilation is the deliberate step and
                        ;; it happens below, once, where its failure is caught.
                        (values (read-from-string source) nil))
          (error (c) (values nil c)))
      (cond
        (condition
         (tool:make-tool-result
          :output (format nil "Could not read that source: ~a" condition)
          :error-p t))
        ((not (and (consp form) (eq 'lambda (first form))))
         (tool:make-tool-result
          :output "Source must be a single lambda form, e.g. (lambda (input) ...)"
          :error-p t))
        (t
         (multiple-value-bind (id compile-condition)
             (create-candidate name form :cell (agent-cell agent))
           (if id
               (tool:make-tool-result
                :output (format nil "Created version ~d of ~a.~@[ ~a~] ~
Not in force yet -- activate_capability ~d to use it."
                                id name (gethash "note" args) id))
               (tool:make-tool-result
                :output (format nil "That did not compile: ~a" compile-condition)
                :error-p t))))))))

(tool:define-tool activate-capability (args context)
  :name "activate_capability"
  :description "Put a version you created in force for this task. It takes
effect from your next call_capability and affects nobody else's work."
  :parameters (("version" :integer "The version number create_capability gave you" :required-p t))
  (let* ((agent (capability-agent))
         (version (gethash "version" args))
         (answer (activate-candidate (agent-task agent) version
                                     :cell (agent-cell agent))))
    (if (eql answer version)
        (tool:make-tool-result
         :output (format nil "Version ~d is in force for this task." version))
        (tool:make-tool-result :output (refusal-text answer "activate_capability")
                               :error-p t))))

(tool:define-tool call-capability (args context)
  :name "call_capability"
  :description "Run a capability on one string and get its result. Resolves to
the version you activated for this task, or the promoted default if you have
activated none."
  :parameters (("name" :string "The capability to run" :required-p t)
               ("input" :string "The one string argument it receives" :required-p t))
  (let ((agent (capability-agent))
        (name (gethash "name" args)))
    (with-capability-context (agent)
      (handler-case
          (let ((result (call-component name (gethash "input" args))))
            (tool:make-tool-result
             :output (if (stringp result) result (princ-to-string result))))
        ;; A capability the model wrote is the model's mistake to see and fix,
        ;; never the run's death. This is the one place arbitrary authored code
        ;; executes, and it executes inside a handler.
        (error (condition)
          (tool:make-tool-result
           :output (format nil "~a failed: ~a" name condition) :error-p t))))))

(tool:define-tool promote-capability (args context)
  :name "promote_capability"
  :description "Make a version the default for every future task, not just
this one. Do this only once you have evidence it works -- it changes what
everybody resolves."
  :parameters (("version" :integer "The version to promote" :required-p t))
  (let* ((agent (capability-agent))
         (version (gethash "version" args))
         (answer (promote-candidate version :cell (agent-cell agent))))
    (if (eql answer version)
        (tool:make-tool-result
         :output (format nil "Version ~d is now the promoted default." version))
        (tool:make-tool-result :output (refusal-text answer "promote_capability")
                               :error-p t))))

(tool:define-tool list-capabilities (args context)
  :name "list_capabilities"
  :description "What capabilities exist: the promoted defaults, and whatever
you have put in force for this task."
  :parameters ()
  (let* ((agent (capability-agent))
         (registry (evolution-registry))
         (pins (vivarium.evolution:pins-of registry (agent-task agent))))
    (tool:make-tool-result
     :output
     (if (null pins)
         "Nothing is in force for this task. Promoted defaults resolve."
         (format nil "In force for this task:~{~%  ~a -> version ~a~}"
                 (loop for (name . id) in pins append (list name id)))))))

(defun capability-tools ()
  "The door, as a tool set. Passed to MAKE-WORKSPACE-AGENT as :EXTRA-TOOLS by
whoever is configuring an arm; absent, an agent cannot self-modify at all,
which is exactly KC6's arm C."
  (list create-capability activate-capability call-capability
        promote-capability list-capabilities))
