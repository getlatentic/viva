;;;; Pi's agent loop, ported.
;;;;
;;;; Structure follows packages/agent/src/agent-loop.ts:155 `runLoop` closely
;;;; enough that the two can be compared line by line, because a control arm
;;;; that quietly diverges is worse than no control arm. The deviations are
;;;; listed in ~/workspace/research/live-image-harness/pi-port.md.

(in-package #:vivarium.loop)

(defstruct (context (:conc-name context-))
  (messages '() :type list))

(defun push-message (context collected message)
  "Append MESSAGE to both the live context and the run's transcript."
  (setf (context-messages context) (append (context-messages context) (list message)))
  (vector-push-extend message collected)
  message)

(defun find-tool (agent name)
  (find name (agent:tools agent) :key #'tool:tool-name :test #'string=))

;;; Tool batch execution

(defun result-message (call result)
  (msg:make-tool-result-message
   :call-id (msg:tool-call-id call)
   :output (tool:tool-result-output result)
   :error-p (tool:tool-result-error-p result)))

(defun run-tool (agent call context)
  "The call itself, after BEFORE-TOOL has had its say.

A TOOL-RESULT from the hook short-circuits: the tool does not run, and the
refusal reaches the model as a result it can read rather than as a crash. A
TOOL-CALL from the hook replaces the call, so arguments can be rewritten."
  (let ((decision (agent:before-tool agent call)))
    (etypecase decision
      (tool:tool-result (values decision call))
      (msg:tool-call (values (run-tool-directly agent decision context) decision))
      (null (values (run-tool-directly agent call context) call)))))

(defun run-tool-directly (agent call context)
  (a:if-let ((tool (find-tool agent (msg:tool-call-name call))))
    (tool:execute tool (msg:tool-call-arguments call) context)
    (tool:make-tool-result
     :output (format nil "No such tool: ~a" (msg:tool-call-name call))
     :error-p t)))

(defun execute-one (agent call context)
  "Run one tool call, returning (values result-message terminate-p)."
  (agent:emit agent (list :type :tool-start :call call))
  (multiple-value-bind (result actual) (run-tool agent call context)
    (let ((result (or (agent:after-tool agent actual result) result)))
      (agent:emit agent (list :type :tool-end :call actual :result result))
      (values (result-message actual result) (tool:tool-result-terminate-p result)))))

(defun execute-batch (agent calls context)
  "Run every call in CALLS. Returns (values result-messages terminate-p).
Parallel execution is per-call threads; a batch is small and short-lived, so a
pool would cost more coordination than it saves."
  (let ((outcomes
          (if (agent:agent-parallel-tools-p agent)
              (let ((threads (mapcar (lambda (call)
                                       (bt:make-thread
                                        (lambda ()
                                          (multiple-value-list (execute-one agent call context)))
                                        :name (format nil "tool-~a" (msg:tool-call-name call))))
                                     calls)))
                (mapcar #'bt:join-thread threads))
              (mapcar (lambda (call)
                        (multiple-value-list (execute-one agent call context)))
                      calls))))
    (values (mapcar #'first outcomes)
            (some #'second outcomes))))

(defun fail-truncated-batch (agent calls)
  "A :LENGTH stop means the message was cut off, so every call in it may carry
truncated arguments. Fail them all rather than execute possibly-borked calls."
  (mapcar (lambda (call)
            (let ((result (tool:make-tool-result
                           :output "Tool call was truncated by the token limit and was not executed."
                           :error-p t)))
              (agent:emit agent (list :type :tool-end :call call :result result))
              (result-message call result)))
          calls))

;;; The loop

(defun inject (agent context collected messages)
  (dolist (message messages)
    (agent:emit agent (list :type :message :message message))
    (push-message context collected message)))

(defun apply-next-turn (agent message results context)
  "Pi's prepareNextTurn: a chance to swap model or context between iterations."
  (let ((snapshot (agent:prepare-next-turn agent message results context)))
    (when snapshot
      (a:when-let ((model (getf snapshot :model)))
        (setf (agent:agent-model agent) model))
      (or (getf snapshot :context) context))))

(defun run-iteration (agent context collected)
  "One assistant response and its tool batch.
Returns (values continue-p stop-p context), where CONTINUE-P is Pi's
`hasMoreToolCalls` and STOP-P ends the whole run."
  (let ((message (client:complete agent (context-messages context))))
    (agent:emit agent (list :type :message :message message))
    (push-message context collected message)
    (if (member (msg:assistant-message-stop-reason message) '(:error :aborted))
        (values nil t context)
        (let* ((calls (msg:tool-calls-in message))
               (truncated (eq (msg:assistant-message-stop-reason message) :length)))
          (multiple-value-bind (results terminate-p)
              (cond ((null calls) (values '() nil))
                    (truncated (values (fail-truncated-batch agent calls) nil))
                    (t (execute-batch agent calls context)))
            (dolist (result results) (push-message context collected result))
            (agent:emit agent (list :type :turn-end :message message :results results))
            (let ((next (or (apply-next-turn agent message results context) context)))
              (values (and calls (not terminate-p))
                      (and (agent:should-stop-after-turn agent message results next) t)
                      next)))))))

(defun run (agent initial-messages &key (context (make-context)))
  "Run AGENT until it stops. Returns the messages the run produced.

Outer loop restarts on follow-up messages; inner loop continues while there are
tool calls or steering messages. Steering is polled at the end of every inner
iteration and injected before the next assistant response, so a message queued
mid-run lands on the very next request rather than after the run."
  (let ((collected (make-array 0 :adjustable t :fill-pointer t)))
    (inject agent context collected initial-messages)
    (let ((pending (agent:steering-messages agent)))
      (loop named outer do
        (let ((more-calls t))
          (loop while (or more-calls pending) do
            (agent:emit agent (list :type :turn-start))
            (when pending
              (inject agent context collected pending)
              (setf pending '()))
            (multiple-value-bind (continue-p stop-p next) (run-iteration agent context collected)
              (setf more-calls continue-p context next)
              (when stop-p
                (agent:emit agent (list :type :run-end :messages collected))
                (return-from run (coerce collected 'list)))
              (setf pending (agent:steering-messages agent)))))
        (let ((follow-up (agent:follow-up-messages agent)))
          (if follow-up
              (setf pending follow-up)
              (return-from outer)))))
    (agent:emit agent (list :type :run-end :messages collected))
    (coerce collected 'list)))
