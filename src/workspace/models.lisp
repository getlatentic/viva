;;;; Which model an agent reaches, resolved from the environment.
;;;;
;;;; One table, because every entry point needs the same three lines -- endpoint,
;;;; key, model id -- and each copy is another thing to update when one of them
;;;; moves. A choice whose credential is absent is simply not offered: a missing
;;;; key should be a missing option, never a run that fails at the first request.

(in-package #:viva.models)

(defstruct (choice (:conc-name choice-))
  (label "" :type string)
  (provider nil)
  (model "" :type string)
  (effort nil)
  ;; What the model will accept, for deciding when to compact. Conservative on
  ;; purpose: too high fails the request compaction existed to prevent, and the
  ;; cost of too low is one summary nobody needed.
  (context-limit 128000 :type integer))

(defparameter +catalogue+
  '((:label "openai" :key "OPENAI_API_KEY"
     :endpoint-var "OPENAI_ENDPOINT" :endpoint "https://api.openai.com/v1/chat/completions"
     :model-var "OPENAI_MODEL" :model "gpt-4.1-mini")
    (:label "openrouter" :key "OPENROUTER_API_KEY" :effort "low"
     :endpoint-var "OPENROUTER_ENDPOINT" :endpoint "https://openrouter.ai/api/v1/chat/completions"
     :model-var "OPENROUTER_MODEL" :model "openai/gpt-oss-120b")
    (:label "deepseek" :key "DEEPSEEK_API_KEY"
     :endpoint-var "DEEPSEEK_ENDPOINT" :endpoint "https://api.deepseek.com/v1/chat/completions"
     :model-var "DEEPSEEK_MODEL" :model "deepseek-v4-flash")
    ;; Bedrock through its OpenAI-compatible endpoint: a BEARER TOKEN, not
    ;; SigV4. Verified against /v1/models before this was written rather than
    ;; assumed, which is why there is no request signing anywhere in the tree.
    (:label "bedrock" :key "BEDROCK_API_KEY" :effort "low"
     :endpoint-var "BEDROCK_ENDPOINT" :endpoint "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions"
     :model-var "BEDROCK_MODEL" :model "google.gemma-4-31b"))
  "OpenAI-compatible endpoints, in preference order.")

(defun from-environment (name)
  (let ((value (sb-posix:getenv name)))
    (and value (plusp (length value)) value)))

(defun entry-choice (entry)
  (a:when-let ((key (from-environment (getf entry :key))))
    (make-choice :label (getf entry :label)
                 :model (or (from-environment (getf entry :model-var)) (getf entry :model))
                 :effort (getf entry :effort)
                 :context-limit (or (a:when-let ((given (from-environment "VIVA_CONTEXT_LIMIT")))
                                      (parse-integer given :junk-allowed t))
                                    (getf entry :context-limit 128000))
                 :provider (provider:openai-provider
                            :endpoint (or (from-environment (getf entry :endpoint-var))
                                          (getf entry :endpoint))
                            :api-key key))))

(defun local-choice ()
  "A llama.cpp server, when one is configured. Not probed here -- probing needs a
socket library the library layer has no other use for, so a caller that cares
whether it is up checks before offering it."
  (a:when-let ((endpoint (from-environment "VIVA_LOCAL_ENDPOINT")))
    (make-choice :label "local" :effort "low"
                 :model (or (from-environment "VIVA_LOCAL_MODEL") "gpt-oss-20b")
                 :provider (provider:llama-cpp-provider
                            :endpoint endpoint
                            :output-prefix provider:+harmony-output-prefix+))))

(defun available-models ()
  (remove nil (append (mapcar #'entry-choice +catalogue+) (list (local-choice)))))

(defun resolve-model (&optional label)
  "The named choice, or the first available one. Signals when there is none, and
says what would make one appear."
  (let ((available (available-models)))
    (cond ((null available)
           (error "No model is configured. Set one of ~{~a~^, ~} in the ~
environment or in .env at the repository root."
                  (mapcar (lambda (entry) (getf entry :key)) +catalogue+)))
          ((null label) (first available))
          ;; By the choice's name, or by the model it resolves to. A session
          ;; records the model it ran under, and bringing it back means
          ;; asking for that model -- which only the second form can do.
          (t (or (find label available :key #'choice-label :test #'string-equal)
                 (find label available :key #'choice-model :test #'string=)
                 (error "No model called ~s. Available: ~{~a~^, ~}"
                        label (mapcar #'choice-label available)))))))
