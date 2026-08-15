;;;; Behaviours the port must preserve.
;;;;
;;;; Every test drives a scripted responder rather than a model, so what is
;;;; under test is the loop's control flow -- which is the whole point of the
;;;; port. Model-level fidelity against real Pi is a separate measurement.

(defpackage #:vivarium.tests
  (:use #:cl #:parachute)
  (:local-nicknames (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client)
                    (#:provider #:vivarium.provider)
                    (#:ledger #:vivarium.ledger)
                    (#:image #:vivarium.image)
                    (#:schema #:vivarium.schema)
                    (#:derive #:vivarium.derive)
                    (#:self #:vivarium.self)
                    (#:trial #:vivarium.trial)
                    (#:arena #:vivarium.arena)
                    (#:stream* #:vivarium.stream)
                    (#:wire #:vivarium.wire)
                    (#:tasks #:vivarium.tasks)
                    (#:service #:vivarium.service)
                    (#:cli #:vivarium.cli)
                    (#:sexp #:vivarium.sexp)
                    (#:image-tools #:vivarium.image-tools)
                    (#:loop* #:vivarium.loop)
                    (#:env #:vivarium.env)
                    (#:glob #:vivarium.glob)
                    (#:edit #:vivarium.edit)
                    (#:workspace #:vivarium.workspace)
                    (#:skill #:vivarium.skill)
                    (#:memory #:vivarium.memory)
                    (#:extension #:vivarium.extension)
                    (#:session #:vivarium.session)
                    (#:harness #:vivarium.harness)))

(in-package #:vivarium.tests)

;;; A responder that reads canned assistant messages off a script and records
;;; the exact system prompt and tool names each request was built with.

(defclass scripted-agent (agent:queued-agent)
  ((script :initarg :script :accessor script)
   (requests :initform '() :accessor requests)))

(defmethod client:complete ((agent scripted-agent) messages)
  (push (list :prompt (agent:system-prompt agent)
              :tools (mapcar #'tool:tool-name (agent:tools agent))
              :messages (length messages))
        (requests agent))
  (or (pop (script agent))
      (msg:make-assistant-message :content (list (msg:make-text "script exhausted"))
                                  :stop-reason :stop)))

(defun requests-made (agent) (reverse (requests agent)))

(defun say (text &key (stop :stop))
  (msg:make-assistant-message :content (list (msg:make-text text)) :stop-reason stop))

(defun call-tool (name &key (id "c1") (arguments nil) (stop :tool-calls))
  (msg:make-assistant-message
   :content (list (msg:make-tool-call :id id :name name
                                      :arguments (or arguments (make-hash-table :test #'equal))))
   :stop-reason stop))

(defun user (text)
  (msg:make-user-message :content (list (msg:make-text text))))

(defvar *ran* nil)

(tool:define-tool echo-tool (args ctx)
  :description "Echo a value."
  :parameters (("value" :string "Anything" :required-p t))
  (push :ran *ran*)
  (or (gethash "value" args) "empty"))

(tool:define-tool exploding-tool (args ctx)
  :description "Always signals."
  :parameters ()
  (error "boom"))

(tool:define-tool halting-tool (args ctx)
  :description "Ends the batch."
  :parameters ()
  (tool:make-tool-result :output "done" :terminate-p t))

(defun make-agent (script &rest initargs)
  (apply #'make-instance 'scripted-agent :script script
                                         :tools (list echo-tool exploding-tool halting-tool)
                                         initargs))

;;; Tests

(define-test "plain response ends the run in one request"
  (let* ((agent (make-agent (list (say "hello"))))
         (messages (loop*:run agent (list (user "hi")))))
    (is = 1 (length (requests-made agent)))
    (is = 2 (length messages))
    (is string= "hello" (msg:text-of (second messages)))))

(defun arguments (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr do (setf (gethash key table) value))
    table))

(define-test "a tool call is executed and its result feeds the next request"
  (let* ((*ran* '())
         (agent (make-agent (list (call-tool "echo_tool" :arguments (arguments "value" "hi"))
                                  (say "done"))))
         (messages (loop*:run agent (list (user "go")))))
    (is = 2 (length (requests-made agent)))
    (is equal '(:ran) *ran*)
    (of-type 'msg:tool-result-message (third messages))
    (is string= "hi" (msg:tool-result-message-output (third messages)))))

(define-test "a call missing a required argument is rejected without running the tool"
  (let* ((*ran* '())
         (agent (make-agent (list (call-tool "echo_tool") (say "recovered"))))
         (messages (loop*:run agent (list (user "go")))))
    (is equal '() *ran*)
    (true (msg:tool-result-message-error-p (third messages)))
    (true (search "missing required: value" (msg:tool-result-message-output (third messages))))
    (is string= "recovered" (msg:text-of (fourth messages)))))

(define-test "a :length stop fails the whole batch without executing it"
  (let* ((*ran* '())
         (agent (make-agent (list (call-tool "echo_tool" :stop :length) (say "recovered"))))
         (messages (loop*:run agent (list (user "go")))))
    (is equal '() *ran*)
    (let ((result (third messages)))
      (of-type 'msg:tool-result-message result)
      (true (msg:tool-result-message-error-p result))
      (true (search "truncated" (msg:tool-result-message-output result))))))

(define-test "a tool that signals fails its own call, not the run"
  (let* ((agent (make-agent (list (call-tool "exploding_tool") (say "carried on"))))
         (messages (loop*:run agent (list (user "go")))))
    (true (msg:tool-result-message-error-p (third messages)))
    (true (search "boom" (msg:tool-result-message-output (third messages))))
    (is string= "carried on" (msg:text-of (fourth messages)))))

(define-test "an unknown tool produces an error result rather than a crash"
  (let* ((agent (make-agent (list (call-tool "no_such_tool") (say "ok"))))
         (messages (loop*:run agent (list (user "go")))))
    (true (msg:tool-result-message-error-p (third messages)))
    (true (search "No such tool" (msg:tool-result-message-output (third messages))))))

(define-test "a terminating tool ends the batch loop"
  (let* ((agent (make-agent (list (call-tool "halting_tool") (say "never reached"))))
         (messages (loop*:run agent (list (user "go")))))
    (is = 1 (length (requests-made agent)))
    (is = 3 (length messages))))

(define-test "steering lands before the next request, not after the run"
  (let ((agent (make-agent (list (call-tool "echo_tool") (say "acknowledged")))))
    (agent:queue-steering agent (user "actually, stop"))
    (let ((messages (loop*:run agent (list (user "go")))))
      (declare (ignore messages))
      ;; Two requests: the steering message was injected before the second, so
      ;; the second request saw one more message than the tool result alone.
      (is = 2 (length (requests-made agent)))
      (is = 4 (getf (second (requests-made agent)) :messages)))))

(define-test "a follow-up restarts the loop after it would have stopped"
  (let ((agent (make-agent (list (say "first") (say "second")))))
    (agent:queue-follow-up agent (user "one more thing"))
    (loop*:run agent (list (user "go")))
    (is = 2 (length (requests-made agent)))))

(define-test "the system prompt is read per request, so a mid-run change lands"
  (let ((agent (make-agent (list (call-tool "echo_tool") (say "done"))
                           :system-prompt "before")))
    (setf (agent:system-prompt agent) "before")
    ;; Change the agent while it is mid-run, from the tool it is executing.
    (let ((mutator (make-instance 'tool:function-tool
                                  :name "echo_tool"
                                  :description "Mutates its own agent."
                                  :parameters '()
                                  :body (lambda (args ctx)
                                          (declare (ignore args ctx))
                                          (setf (agent:system-prompt agent) "after")
                                          "mutated"))))
      (setf (agent:tools agent) (list mutator)))
    (loop*:run agent (list (user "go")))
    (let ((prompts (mapcar (lambda (r) (getf r :prompt)) (requests-made agent))))
      (is equal '("before" "after") prompts))))

(define-test "a tool added mid-run is available on the next request"
  (let ((agent (make-agent (list (call-tool "echo_tool") (say "done")))))
    (let ((adder (make-instance 'tool:function-tool
                                :name "echo_tool"
                                :description "Grants a new capability."
                                :parameters '()
                                :body (lambda (args ctx)
                                        (declare (ignore args ctx))
                                        (push halting-tool (slot-value agent 'vivarium.agent::%tools))
                                        "granted"))))
      (setf (agent:tools agent) (list adder)))
    (loop*:run agent (list (user "go")))
    (let ((tools (mapcar (lambda (r) (getf r :tools)) (requests-made agent))))
      (is = 1 (length (first tools)))
      (is = 2 (length (second tools))))))
