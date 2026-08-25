;;;; SSE parsing and reassembly, driven from strings so no server is needed.

(in-package #:viva.tests)

(defun sse (&rest payloads)
  (with-output-to-string (out)
    (dolist (payload payloads)
      (format out "data: ~a~%~%" payload))
    (format out "data: [DONE]~%~%")))

(defun collect-from (text &key abort-p)
  (with-input-from-string (input text)
    (stream*:collect input :abort-p abort-p)))

(defun chunk (&key content reasoning tool-calls finish)
  (format nil "{\"choices\":[{\"delta\":{~@[\"content\":~s~]~@[~*,~]~@[\"reasoning_content\":~s~]~@[~*,~]~@[\"tool_calls\":~a~]}~@[,\"finish_reason\":~s~]}]}"
          content (and content (or reasoning tool-calls))
          reasoning (and reasoning tool-calls)
          tool-calls finish))

(define-test "text arriving in fragments is reassembled"
  (let ((message (collect-from (sse (chunk :content "Hel")
                                    (chunk :content "lo, ")
                                    (chunk :content "world")
                                    (chunk :finish "stop")))))
    (is string= "Hello, world" (msg:text-of message))
    (is eq :stop (msg:assistant-message-stop-reason message))))

(define-test "reasoning is kept separate from content"
  (let* ((message (collect-from (sse (chunk :reasoning "thinking hard")
                                     (chunk :content "the answer")
                                     (chunk :finish "stop"))))
         (thinking (remove-if-not #'msg:thinking-p (msg:message-content message))))
    (is string= "the answer" (msg:text-of message))
    (is = 1 (length thinking))
    (is string= "thinking hard" (msg:thinking-value (first thinking)))))

(define-test "a tool call split across chunks is reassembled"
  ;; The awkward case: name arrives once, arguments arrive as JSON fragments
  ;; that are not individually parseable.
  (let* ((message (collect-from
                   (sse (chunk :tool-calls "[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"shipping_cost\",\"arguments\":\"\"}}]")
                        (chunk :tool-calls "[{\"index\":0,\"function\":{\"arguments\":\"{\\\"wei\"}}]")
                        (chunk :tool-calls "[{\"index\":0,\"function\":{\"arguments\":\"ght\\\":7}\"}}]")
                        (chunk :finish "tool_calls"))))
         (calls (msg:tool-calls-in message)))
    (is = 1 (length calls))
    (is string= "shipping_cost" (msg:tool-call-name (first calls)))
    (is string= "call_1" (msg:tool-call-id (first calls)))
    (is = 7 (gethash "weight" (msg:tool-call-arguments (first calls))))
    (is eq :tool-calls (msg:assistant-message-stop-reason message))))

(define-test "two parallel tool calls stay separate by index"
  (let* ((message (collect-from
                   (sse (chunk :tool-calls "[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"first\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"second\",\"arguments\":\"{}\"}}]")
                        (chunk :finish "tool_calls"))))
         (calls (msg:tool-calls-in message)))
    (is = 2 (length calls))
    (is equal '("first" "second") (mapcar #'msg:tool-call-name calls))))

(define-test "a length finish survives streaming"
  (let ((message (collect-from (sse (chunk :content "cut off") (chunk :finish "length")))))
    (is eq :length (msg:assistant-message-stop-reason message))))

(define-test "malformed arguments do not take the run down"
  (let* ((message (collect-from
                   (sse (chunk :tool-calls "[{\"index\":0,\"id\":\"x\",\"function\":{\"name\":\"broken\",\"arguments\":\"{not json\"}}]")
                        (chunk :finish "tool_calls"))))
         (call (first (msg:tool-calls-in message))))
    (is string= "broken" (msg:tool-call-name call))
    (is = 0 (hash-table-count (msg:tool-call-arguments call)))))

(define-test "a keep-alive comment between events is ignored"
  (let ((text (format nil "data: ~a~%~%: ping~%~%data: ~a~%~%data: [DONE]~%~%"
                      (chunk :content "a") (chunk :content "b"))))
    (is string= "ab" (msg:text-of (collect-from text)))))

(define-test "an abort stops mid-stream and keeps what had arrived"
  ;; ABORT-P is checked before every line read, not every event, and SSE puts a
  ;; blank line between events -- so the abort lands finer than event
  ;; granularity. The property that matters is that it stopped early and did not
  ;; discard what had already arrived.
  (let* ((text (sse (chunk :content "one ") (chunk :content "two ")
                    (chunk :content "three") (chunk :finish "stop")))
         (whole (msg:text-of (collect-from text)))
         (seen 0)
         (partial (collect-from text :abort-p (lambda () (> (incf seen) 2)))))
    (is string= "one two three" whole)
    (is eq :aborted (msg:assistant-message-stop-reason partial))
    (is = 0 (search (msg:text-of partial) whole))
    (true (< (length (msg:text-of partial)) (length whole)))
    (true (plusp (length (msg:text-of partial))))))

(define-test "a stream that ends without DONE still yields what it sent"
  (let ((message (collect-from (format nil "data: ~a~%~%" (chunk :content "truncated")))))
    (is string= "truncated" (msg:text-of message))))

;;; The agent-level abort policy

(define-test "a queued steer aborts the request in flight when asked to"
  (let ((agent (make-instance 'agent:queued-agent :abort-on-steer t)))
    (false (agent:should-abort-p agent))
    (agent:queue-steering agent (user "stop"))
    (true (agent:should-abort-p agent))))

(define-test "without the policy a steer waits, matching Pi and Codex"
  (let ((agent (make-instance 'agent:queued-agent)))
    (agent:queue-steering agent (user "stop"))
    (false (agent:should-abort-p agent))))
