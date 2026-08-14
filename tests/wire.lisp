;;;; Reading a non-streamed response, driven from recorded server bodies.
;;;;
;;;; "OpenAI-compatible" is a family resemblance. These are the exact response
;;;; shapes of the three servers this harness talks to, trimmed but not
;;;; normalised: where they disagree is the whole point of the file.

(in-package #:vivarium.tests)

(defun parsed (body) (vivarium.client::parse-response body))

(defun thinking-of (message)
  (let ((blocks (remove-if-not #'msg:thinking-p (msg:message-content message))))
    (and blocks (msg:thinking-value (first blocks)))))

;;; WIRE itself

(define-test "a JSON null reads as absent however the parser spells it"
  (is eq nil (wire:present (com.inuoe.jzon:parse "null")))
  (is eq nil (wire:present :null))
  (is eq nil (wire:present nil))
  (is string= "kept" (wire:present "kept")))

(define-test "text-field refuses a non-string rather than coercing it"
  (let ((table (com.inuoe.jzon:parse "{\"a\":null,\"b\":\"\",\"c\":7,\"d\":\"ok\"}")))
    (is eq nil (wire:text-field table "a"))
    (is eq nil (wire:text-field table "b"))
    (is eq nil (wire:text-field table "c"))
    (is eq nil (wire:text-field table "missing"))
    (is string= "ok" (wire:text-field table "d"))))

;;; The three servers

(define-test "OpenRouter: content null beside tool calls parses as tool calls"
  ;; Regression. jzon renders JSON null as a symbol, which is true and has no
  ;; length, so the old guard `(and text (plusp (length text)))` signalled
  ;; "The value NULL is not of type SEQUENCE" -- naming neither field nor server.
  (let* ((message (parsed "{\"choices\":[{\"index\":0,\"finish_reason\":\"tool_calls\",
      \"message\":{\"role\":\"assistant\",\"content\":null,\"refusal\":null,
        \"reasoning\":\"We need to use add_tool.\",
        \"tool_calls\":[{\"type\":\"function\",\"index\":0,\"id\":\"tooluse_3aTT\",
          \"function\":{\"name\":\"add_tool\",\"arguments\":\"{\\\"a\\\": 17, \\\"b\\\": 25}\"}}]}}],
      \"usage\":{\"total_tokens\":186}}"))
         (calls (msg:tool-calls-in message)))
    (is eq :tool-calls (msg:assistant-message-stop-reason message))
    (is = 1 (length calls))
    (is string= "add_tool" (msg:tool-call-name (first calls)))
    (is = 17 (gethash "a" (msg:tool-call-arguments (first calls))))
    (is = 25 (gethash "b" (msg:tool-call-arguments (first calls))))))

(define-test "OpenRouter spells chain of thought `reasoning`, and it is kept"
  ;; Reading only `reasoning_content` drops it, and a reasoning run that emits
  ;; no content then looks silent -- the failure this project has already paid
  ;; for once against llama.cpp.
  (let ((message (parsed "{\"choices\":[{\"finish_reason\":\"stop\",
      \"message\":{\"role\":\"assistant\",\"content\":\"42\",
        \"reasoning\":\"adding them up\"}}]}")))
    (is string= "42" (msg:text-of message))
    (is string= "adding them up" (thinking-of message))))

(define-test "llama.cpp and DeepSeek spell it `reasoning_content`, and it is kept"
  (let ((message (parsed "{\"choices\":[{\"finish_reason\":\"stop\",
      \"message\":{\"role\":\"assistant\",\"content\":\"42\",
        \"reasoning_content\":\"adding them up\"}}]}")))
    (is string= "42" (msg:text-of message))
    (is string= "adding them up" (thinking-of message))))

(define-test "a message that is only reasoning still produces a message"
  (let ((message (parsed "{\"choices\":[{\"finish_reason\":\"length\",
      \"message\":{\"role\":\"assistant\",\"content\":null,
        \"reasoning_content\":\"thinking\"}}]}")))
    (is eq :length (msg:assistant-message-stop-reason message))
    (is string= "" (msg:text-of message))
    (is string= "thinking" (thinking-of message))))

;;; Failure shapes

(define-test "a null choices array is refused with the body, not a type error"
  (fail (parsed "{\"choices\":null}") 'client:client-error)
  (fail (parsed "{\"choices\":[]}") 'client:client-error))

(define-test "malformed tool arguments do not take the run down"
  (let* ((message (parsed "{\"choices\":[{\"finish_reason\":\"tool_calls\",
      \"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c1\",
        \"function\":{\"name\":\"add_tool\",\"arguments\":\"{truncated\"}}]}}]}"))
         (call (first (msg:tool-calls-in message))))
    (is string= "add_tool" (msg:tool-call-name call))
    (is = 0 (hash-table-count (msg:tool-call-arguments call)))))

(define-test "a tool call with a null id and no arguments still names its tool"
  (let* ((message (parsed "{\"choices\":[{\"finish_reason\":\"tool_calls\",
      \"message\":{\"content\":null,\"tool_calls\":[{\"id\":null,
        \"function\":{\"name\":\"add_tool\",\"arguments\":null}}]}}]}"))
         (call (first (msg:tool-calls-in message))))
    (is string= "" (msg:tool-call-id call))
    (is string= "add_tool" (msg:tool-call-name call))
    (is = 0 (hash-table-count (msg:tool-call-arguments call)))))

(define-test "streamed reasoning is read under either spelling"
  (let ((openrouter (collect-from (sse "{\"choices\":[{\"delta\":{\"reasoning\":\"why\"}}]}"
                                       "{\"choices\":[{\"delta\":{\"content\":\"42\"},\"finish_reason\":\"stop\"}]}")))
        (llama (collect-from (sse "{\"choices\":[{\"delta\":{\"reasoning_content\":\"why\"}}]}"
                                  "{\"choices\":[{\"delta\":{\"content\":\"42\"},\"finish_reason\":\"stop\"}]}"))))
    (is string= "why" (thinking-of openrouter))
    (is string= "why" (thinking-of llama))))
