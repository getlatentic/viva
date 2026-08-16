;;;; KC6 pre-check ZERO: can the entity under test reach the machinery at all?
;;;;
;;;; Pre-check one traverses the evolution lifecycle with a scripted agent and
;;;; passes. It proves the LISP wire works. It says nothing about the wire a
;;;; MODEL uses, and those are different wires -- a distinction this project
;;;; has already paid for once, when a tool that passed a Lisp unit test was
;;;; being advertised to the model with a malformed schema.
;;;;
;;;; Two questions, both of which must be YES before KC6 means anything:
;;;;
;;;;   1. Does the model-visible tool set contain a verb that reaches the
;;;;      evolution owner? If not, arm A describes capabilities nothing can
;;;;      invoke, arm B's door closes a path no model could take, and A-vs-B
;;;;      compares two identical configurations.
;;;;
;;;;   2. Does anything in the shipped organism RESOLVE a component? If not, a
;;;;      version the agent creates is called by nothing, instrumentality is
;;;;      zero by construction, and the lifecycle -- however well proven -- is
;;;;      a lifecycle for versions of things nobody runs.
;;;;
;;;;   sbcl --script experiments/kc6/reachability.lisp

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:pathname-directory-pathname *load-truename*))))

(push *root* (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))

(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :vivarium/cli :silent t))

(defparameter *evolution-verbs*
  '("create_candidate" "activate_candidate" "promote_candidate"
    "create_capability" "activate_capability" "promote_capability"
    "install" "rollback")
  "Any one of these in the model's tool set means the door is reachable.
Named broadly on purpose: this check must pass for whatever surface is
eventually chosen, not for one spelling of it.")

(defun model-visible-tools ()
  (let ((sandbox "/tmp/kc6-reachability/"))
    (ensure-directories-exist sandbox)
    (let ((agent (vivarium.harness:make-workspace-agent
                  :cwd sandbox :root sandbox :model "deepseek")))
      (sort (mapcar #'vivarium.tool:tool-name (vivarium.agent:tools agent)) #'string<))))

(defun component-consumers ()
  "Files under src/ that resolve a component. Tests and probes do not count:
the question is whether the SHIPPED organism runs anything through the door."
  (remove-if-not
   (lambda (path)
     (let ((text (uiop:read-file-string path)))
       (and (search "call-component" text)
            (not (search "defun call-component" text))
            (not (search "#:call-component" text)))))
   (directory (merge-pathnames "src/**/*.lisp" *root*))))

(let* ((tools (model-visible-tools))
       (reachable (intersection *evolution-verbs* tools :test #'string-equal))
       (consumers (component-consumers))
       (failures 0))
  (format t "~&model-visible tools (~d): ~{~a~^ ~}~%" (length tools) tools)

  (if reachable
      (format t "~&ok    evolution is reachable by the model: ~{~a~^ ~}~%" reachable)
      (progn
        (incf failures)
        (format t "~&FAIL  no model-visible verb reaches the evolution owner.~%~
                     ~&      Arm A describes capabilities no model can invoke, and~%~
                     ~&      arm B's door closes a path no model could take.~%")))

  (if consumers
      (format t "~&ok    the organism resolves components in: ~{~a~^ ~}~%"
              (mapcar #'file-namestring consumers))
      (progn
        (incf failures)
        (format t "~&FAIL  nothing in src/ resolves a component.~%~
                     ~&      A version the agent creates would be called by nothing,~%~
                     ~&      so instrumentality is zero by construction and the~%~
                     ~&      pre-check that measures it cannot help.~%")))

  (format t "~&~%KC6 arm A is ~:[NOT REACHABLE -- the battery must not run~;reachable~]~%"
          (zerop failures))
  (finish-output)
  (sb-ext:exit :code (if (zerop failures) 0 1)))
