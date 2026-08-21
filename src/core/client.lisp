;;;; The provider boundary: an ordinary OpenAI-compatible chat completion.
;;;;
;;;; Nothing here knows which server is on the other end. What one server adds
;;;; over another lives in PROVIDER.LISP, and this file only asks it to augment
;;;; a finished payload.

(in-package #:vivarium.client)

(defvar *default-provider* (provider:make-default-provider)
  "Used by an agent that carries none of its own.")

(defun provider-for (agent)
  (or (agent:agent-provider agent) *default-provider*))

(define-condition client-error (error)
  ((detail :initarg :detail :reader client-error-detail))
  (:report (lambda (condition stream)
             (format stream "Model request failed: ~a" (client-error-detail condition)))))

(defun obj (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash key table) value))
    table))

;;; Tools out. The schema itself is SCHEMA.LISP's business -- the provider only
;;; decides where it goes in the request.

(defun tool-json (tool)
  (obj "type" "function"
       "function" (obj "name" (tool:tool-name tool)
                       "description" (tool:tool-description tool)
                       "parameters" (schema:parameter-schema (tool:tool-parameters tool)))))

;;; Messages out

(defun tool-call-json (call)
  (obj "id" (msg:tool-call-id call)
       "type" "function"
       "function" (obj "name" (msg:tool-call-name call)
                       "arguments" (jzon:stringify (or (msg:tool-call-arguments call)
                                                       (make-hash-table :test #'equal))))))

(defun message-json (message)
  (etypecase message
    (msg:tool-result-message
     (obj "role" "tool"
          "tool_call_id" (msg:tool-result-message-call-id message)
          "content" (msg:tool-result-message-output message)))
    (msg:assistant-message
     (let ((calls (msg:tool-calls-in message))
           (json (obj "role" "assistant" "content" (msg:text-of message))))
       (when calls
         (setf (gethash "tool_calls" json)
               (map 'vector #'tool-call-json calls)))
       json))
    (msg:message
     (obj "role" (string-downcase (symbol-name (msg:message-role message)))
          "content" (msg:text-of message)))))

(defvar *on-request* nil
  "Called with (AGENT PAYLOAD) just before a request goes out, or NIL.

A hook, so that anything wanting to know what was ACTUALLY SENT reads the
payload rather than re-reading the agent it was built from. Those are the same
string until they are not, and the run where they differ is the run nobody can
explain: a skills loader can be correct in-process while the prompt the model
receives is missing what it wrote, and this project has already paid once for a
tool schema that was right in the image and malformed on the wire.")

(defun request-payload (agent messages)
  "The full request body. Reads the prompt and tool set from AGENT now, not
when the run started -- that is what lets a mid-run change take effect here."
  (let* ((prompt (agent:system-prompt agent))
         (tools (agent:tools agent))
         (system (when (plusp (length prompt))
                   (list (obj "role" "system" "content" prompt))))
         (payload (obj "model" (agent:agent-model agent)
                       "messages" (coerce (append system (mapcar #'message-json messages))
                                          'vector)
                       "temperature" (agent:agent-temperature agent)
                       "max_tokens" (agent:agent-max-tokens agent)
                       "seed" (agent:agent-seed agent)
                       "stream" nil)))
    (when tools
      (setf (gethash "tools" payload) (map 'vector #'tool-json tools)
            (gethash "parallel_tool_calls" payload) (agent:agent-parallel-tools-p agent)))
    (let ((final (provider:augment-payload (provider-for agent) payload agent)))
      ;; After AUGMENT-PAYLOAD: a provider may still change what is sent, and
      ;; observing before it would report a body that never left.
      (when *on-request* (ignore-errors (funcall *on-request* agent final)))
      final)))

;;; Response in

(defun stop-reason (finish-reason)
  (cond ((equal finish-reason "stop") :stop)
        ((equal finish-reason "length") :length)
        ((equal finish-reason "tool_calls") :tool-calls)
        ((null finish-reason) :stop)
        (t :stop)))

(defun parse-arguments (text)
  "Tool arguments arrive as a JSON string. A model that emitted a truncated or
malformed one must not take the run down with it."
  (handler-case (jzon:parse (or text "{}"))
    (error () (make-hash-table :test #'equal))))

(defun parse-tool-call (json)
  (let ((function (wire:field json "function")))
    (msg:make-tool-call :id (or (wire:text-field json "id") "")
                        :name (or (wire:text-field function "name") "")
                        :arguments (parse-arguments (wire:text-field function "arguments")))))

(defun parse-content (message)
  "Reasoning models put chain-of-thought beside `content` and leave `content`
itself empty until they are done thinking. Dropping it loses the only evidence
of what a run that produced no answer actually did -- and with a small token
budget that is every run. It becomes a THINKING block, which MESSAGE-JSON does
not echo back on the next request.

Every field here goes through WIRE: a message that is entirely tool calls has a
`content` of JSON null, not an absent key."
  (let ((text (wire:text-field message "content"))
        (reasoning (wire:reasoning-field message))
        (calls (wire:field message "tool_calls")))
    (append (when reasoning (list (msg:make-thinking reasoning)))
            (when text (list (msg:make-text text)))
            (when (vectorp calls) (map 'list #'parse-tool-call calls)))))

(defun parse-response (body)
  (let* ((json (jzon:parse body))
         (choices (wire:field json "choices")))
    (when (or (not (vectorp choices)) (zerop (length choices)))
      (error 'client-error :detail (format nil "no choices in response: ~a" body)))
    (let* ((choice (aref choices 0))
           (message (wire:field choice "message"))
           (content (parse-content message))
           (reason (stop-reason (wire:text-field choice "finish_reason"))))
      (msg:make-assistant-message
       :content content
       :usage (wire:field json "usage")
       ;; :LENGTH must survive even when tool calls are present -- it is exactly
       ;; the case where those calls carry truncated arguments, and the loop
       ;; fails the whole batch on it.
       :stop-reason (if (and (eq reason :stop) (some #'msg:tool-call-p content))
                        :tool-calls
                        reason)))))

(defun post-blocking (agent messages)
  (let ((provider (provider-for agent)))
    (parse-response (dex:post (provider:provider-endpoint provider)
                            :headers (provider:headers provider)
                            :content (jzon:stringify (request-payload agent messages))
                            :read-timeout 600))))

(defun post-streaming (agent messages)
  "Stream the response, letting the agent watch it arrive and stop it early.

ABORT-P is checked between events, so a steer arriving mid-generation ends the
request instead of waiting for it. Neither Pi nor Codex can do that: both can
preempt a *waiting* tool, but an in-flight completion runs to its end."
  (let ((payload (request-payload agent messages))
        (provider (provider-for agent)))
    (setf (gethash "stream" payload) t)
    ;; Ask for the token counts. An OpenAI-compatible server sends them on a
    ;; streamed response only when this is set, and a provider that does not
    ;; know the option ignores it -- so the cost of asking is nothing, and the
    ;; cost of not asking was every streamed run reporting no usage at all.
    (setf (gethash "stream_options" payload)
          (schema:obj "include_usage" t))
    (let ((input (dex:post (provider:provider-endpoint provider)
                           :headers (provider:headers provider)
                           :content (jzon:stringify payload)
                           :want-stream t
                           :read-timeout 600)))
      (unwind-protect
           (stream:collect input
                           :on-delta (lambda (delta)
                                       (agent:emit agent (list :type :delta :delta delta)))
                           :abort-p (lambda () (agent:should-abort-p agent)))
        (ignore-errors (close input))))))

(defgeneric complete (agent messages)
  (:documentation "One model request. Returns an ASSISTANT-MESSAGE.
Generic because the provider belongs to the agent: a scored trial can swap in a
scripted responder without the loop knowing, and a self-modifying agent can
change its own provider mid-run.")
  (:method (agent messages)
    ;; BEFORE-REQUEST and AFTER-RESPONSE bracket the only moment the wire is
    ;; reachable. An extension that wants to see or change what is actually sent
    ;; has nowhere else to stand.
    (let ((messages (or (agent:before-request agent messages) messages)))
      (handler-case
          (let ((message (if (agent:agent-stream-p agent)
                             (post-streaming agent messages)
                             (post-blocking agent messages))))
            (or (agent:after-response agent message) message))
        (client-error (condition) (error condition))
        (error (condition) (error 'client-error :detail (princ-to-string condition)))))))
