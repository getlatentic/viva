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
                  :cwd sandbox :root sandbox :model "deepseek"
                  :extra-tools (vivarium.actor:capability-tools))))
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

(defun schema-complaints ()
  "What is wrong with the JSON the model is actually SENT.

Not the Lisp objects -- the wire. B14 concluded that a model could not derive a
predicate, and the truth was that its tool advertised `args` as an array with
no `items`: the schema was malformed and the capability was never really
offered. That cost an entire experiment, and this is the check that would have
caught it in a second."
  (schema-complaints-of
   (loop for tool in (vivarium.actor:capability-tools)
         collect (cons (vivarium.tool:tool-name tool)
                       (gethash "parameters"
                                (gethash "function"
                                         (vivarium.client::tool-json tool)))))))

(defun schema-complaints-of (pairs)
  "The complaint logic, over (NAME . PARAMETERS) so it can be fed known-bad
input. Several of these cannot currently be produced -- the schema builder
refuses a bare :array at source, and :required-p makes a required key a
property by construction -- and a check nobody can make fail is not a check.
So it is exercised on synthetic malformed schemas by --self-test."
  (loop for (name . parameters) in pairs
        for properties = (and parameters (gethash "properties" parameters))
        append (append
                (unless (equal "object" (and parameters (gethash "type" parameters)))
                  (list (format nil "~a: parameters is not an object schema" name)))
                (unless properties
                  (list (format nil "~a: no properties" name)))
                (when properties
                  (loop for key being the hash-keys of properties
                          using (hash-value schema)
                        for type = (gethash "type" schema)
                        append (append
                                (unless type
                                  (list (format nil "~a.~a: no type" name key)))
                                (when (and (equal "array" type)
                                           (null (gethash "items" schema)))
                                  (list (format nil "~a.~a: array with no items"
                                                name key))))))
                (loop for required across (or (and parameters
                                                   (gethash "required" parameters))
                                              #())
                      unless (and properties (nth-value 1 (gethash required properties)))
                        collect (format nil "~a: required ~a is not a property"
                                        name required)))))

(defun table (&rest pairs)
  (let ((made (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key made) value))
    made))

(defun schema-case (parameters) (list (cons "probe" parameters)))

(defun run-schema-self-test ()
  "The gate failing, on each shape it claims to catch, and staying quiet on a
good one -- an alarm that never fires and an alarm always firing are equally
useless."
  (let ((missed '()))
    (flet ((check (label pairs)
             (let ((complaints (schema-complaints-of pairs)))
               (format t "~&  ~:[MISSED~;caught~]  ~a~@[: ~a~]~%"
                       complaints label (first complaints))
               (unless complaints (push label missed)))))
      (check "array without items"
             (schema-case (table "type" "object" "properties"
                                 (table "args" (table "type" "array")))))
      (check "untyped property"
             (schema-case (table "type" "object" "properties"
                                 (table "args" (table "description" "x")))))
      (check "required that is not a property"
             (schema-case (table "type" "object"
                                 "properties" (table "a" (table "type" "string"))
                                 "required" (vector "b"))))
      (check "parameters not an object"
             (schema-case (table "type" "string"))))
    (let ((clean (schema-complaints-of
                  (schema-case (table "type" "object"
                                      "properties" (table "a" (table "type" "string"))
                                      "required" (vector "a"))))))
      (format t "~&  ~:[caught~;MISSED~]  a well-formed schema stays quiet~%" clean)
      (when clean (push "false alarm" missed)))
    (if missed
        (progn (format t "~&~%schema gate is NOT load-bearing: ~{~a~^, ~}~%" missed)
               (sb-ext:exit :code 1))
        (progn (format t "~&~%schema gate fails on every shape it claims to catch~%")
               (sb-ext:exit :code 0)))))

(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  (run-schema-self-test))

(let* ((tools (model-visible-tools))
       (reachable (intersection *evolution-verbs* tools :test #'string-equal))
       (consumers (component-consumers))
       (schema-problems (schema-complaints))
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

  (if (null schema-problems)
      (format t "~&ok    every capability schema is well formed on the wire~%")
      (progn
        (incf failures)
        (format t "~&FAIL  the JSON the model is sent is malformed:~{~%      ~a~}~%"
                schema-problems)))

  (format t "~&~%KC6 arm A is ~:[NOT REACHABLE -- the battery must not run~;reachable~]~%"
          (zerop failures))
  (finish-output)
  (sb-ext:exit :code (if (zerop failures) 0 1)))
