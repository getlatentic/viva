;;;; What one server adds over another, and that the core knows none of it.

(in-package #:viva.tests)

(defun payload-for (agent)
  (client:request-payload agent (list (user "hello"))))

(define-test "the default provider sends a plain chat completion and nothing else"
  (let* ((agent (make-instance 'agent:queued-agent :reasoning-effort "low"
                                                   :grammar "root ::= \"x\""))
         (payload (payload-for agent)))
    ;; Both were asked for, and a server that cannot honour them is not told.
    (false (nth-value 1 (gethash "grammar" payload)))
    (false (nth-value 1 (gethash "chat_template_kwargs" payload)))
    (false (nth-value 1 (gethash "reasoning_effort" payload)))
    (true (nth-value 1 (gethash "messages" payload)))
    (false (provider:supports-grammar-p (make-instance 'provider:provider)))))

(define-test "llama.cpp gets a grammar and template arguments"
  (let* ((agent (make-instance 'agent:queued-agent
                               :provider (provider:llama-cpp-provider)
                               :reasoning-effort "low"
                               :grammar "root ::= \"x\""))
         (payload (payload-for agent)))
    (is string= "root ::= \"x\"" (gethash "grammar" payload))
    (is string= "low" (gethash "reasoning_effort" (gethash "chat_template_kwargs" payload)))
    ;; It reads effort from the template, not from a top-level field.
    (false (nth-value 1 (gethash "reasoning_effort" payload)))))

(define-test "a hosted OpenAI-compatible server gets effort top-level and no grammar"
  (let* ((agent (make-instance 'agent:queued-agent
                               :provider (provider:openai-provider :api-key "sk-test")
                               :reasoning-effort "high"
                               :grammar "root ::= \"x\""))
         (payload (payload-for agent)))
    (is string= "high" (gethash "reasoning_effort" payload))
    (false (nth-value 1 (gethash "grammar" payload)))
    (false (nth-value 1 (gethash "chat_template_kwargs" payload)))))

(define-test "an api key becomes a bearer header, and its absence sends none"
  (let ((keyed (provider:openai-provider :api-key "sk-test"))
        (bare (provider:llama-cpp-provider)))
    (is string= "Bearer sk-test" (cdr (assoc "Authorization" (provider:headers keyed)
                                             :test #'string=)))
    (false (assoc "Authorization" (provider:headers bare) :test #'string=))))

(define-test "the grammar prefix is a property of the server, not of s-expressions"
  ;; Verified against a real server: a bare s-expression grammar makes
  ;; llama-server reject its own model's output, because the grammar forbade the
  ;; channel markers the server then tried to parse.
  (let ((harmony (provider:llama-cpp-provider
                  :output-prefix provider:+harmony-output-prefix+))
        (plain (provider:llama-cpp-provider))
        (hosted (provider:openai-provider)))
    (is string= "<|channel|>final<|message|>" (sexp:grammar-prefix-for harmony))
    (false (sexp:grammar-prefix-for plain))
    (false (sexp:grammar-prefix-for hosted))))

(define-test "two agents can talk to different servers at once"
  ;; The reason a provider lives on the agent rather than in a special: one arm
  ;; of a comparison on a local model, the other on a hosted one, same loop.
  (let ((local (make-instance 'agent:queued-agent
                              :provider (provider:llama-cpp-provider
                                         :endpoint "http://localhost:8099/v1/chat/completions")))
        (hosted (make-instance 'agent:queued-agent
                               :provider (provider:openai-provider :api-key "sk-test"))))
    (is string= "http://localhost:8099/v1/chat/completions"
        (provider:provider-endpoint (agent:agent-provider local)))
    (is string= "https://api.openai.com/v1/chat/completions"
        (provider:provider-endpoint (agent:agent-provider hosted)))))
