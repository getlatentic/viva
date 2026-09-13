;;;; Which model an agent reaches, resolved from the environment.
;;;;
;;;; One table, because every entry point needs the same three lines -- endpoint,
;;;; key, model id -- and each copy is another thing to update when one of them
;;;; moves. A choice whose credential is absent is simply not offered: a missing
;;;; key should be a missing option, never a run that fails at the first request.

(in-package #:viva.models)

(defstruct (choice (:conc-name choice-))
  (label "" :type string)
  ;; The endpoint this came from, kept so a person can ask for `bedrock` and
  ;; get its default without knowing which model that is today.
  (endpoint-label nil)
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
    ;;
    ;; MANY MODELS, ONE ENDPOINT. Bedrock serves a catalogue behind one base
    ;; URL, so the entry carries a list and the table still holds each
    ;; endpoint once. The base URL is deployment-specific -- BEDROCK_ENDPOINT
    ;; overrides it, and a deployment in another region must.
    ;;
    ;; EVERY ID HERE IS AWS-BILLED, so promotional credits pay for it. The
    ;; seller of record is decided by the id and nothing in the API says
    ;; which: `anthropic.*` -- all of Claude -- is sold by Anthropic through
    ;; AWS Marketplace and credits NEVER apply to it. The run succeeds and the
    ;; invoice arrives a month later, which is why no Claude id is on this
    ;; list. Add one only deliberately.
    (:label "bedrock" :key "BEDROCK_API_KEY" :effort "low"
     :endpoint-var "BEDROCK_ENDPOINT" :endpoint "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions"
     :model-var "BEDROCK_MODEL"
     ;; PREFIXED, every one. `gpt-oss-120b` is already the experiment-facing
     ;; name for OpenRouter's copy of the same weights (CLI:+ARM-LABELS+), and
     ;; two arms answering to one name is how two sweeps stop being comparable.
     ;; The prefix also keeps the seller visible, which is the thing that
     ;; decides whether credits pay.
     :models (("bedrock/gpt-oss-120b" . "openai.gpt-oss-120b")
              ;; Good prose, weaker at holding a field format than 120b, so
              ;; reach for it where the answer is text rather than structure.
              ("bedrock/gpt-oss-20b" . "openai.gpt-oss-20b")
              ("bedrock/glm-5" . "zai.glm-5")
              ("bedrock/kimi-k2.5" . "moonshotai.kimi-k2.5")
              ("bedrock/minimax-m2.5" . "minimax.minimax-m2.5")
              ("bedrock/deepseek-v3.2" . "deepseek.v3.2")
              ("bedrock/qwen3-coder" . "qwen.qwen3-coder-480b-a35b-instruct")
              ("bedrock/nemotron-3-super" . "nvidia.nemotron-super-3-120b"))))
  "OpenAI-compatible endpoints, in preference order.")

(defun equal-label (wanted found)
  (and (stringp found) (string-equal wanted found)))

(defun from-environment (name)
  (let ((value (sb-posix:getenv name)))
    (and value (plusp (length value)) value)))

(defun entry-limit (entry)
  (or (a:when-let ((given (from-environment "VIVA_CONTEXT_LIMIT")))
        (parse-integer given :junk-allowed t))
      (getf entry :context-limit 128000)))

(defun entry-models (entry)
  "The (LABEL . MODEL-ID) pairs this endpoint offers.

An endpoint naming one model answers under its own name. One naming several
answers under each model's name, and under its own for the first -- so
`bedrock` keeps working while `gpt-oss-20b` becomes sayable."
  (a:if-let ((listed (getf entry :models)))
    (let ((override (from-environment (getf entry :model-var))))
      (if override
          (cons (cons (getf entry :label) override) listed)
          listed))
    (list (cons (getf entry :label)
                (or (from-environment (getf entry :model-var)) (getf entry :model))))))

(defun entry-choices (entry &key (auth (auth:read-auth)))
  "ENTRY as usable choices, or NIL where it has no key.

The auth file is read once by the caller and passed down. Reading it per
provider would open and parse the same file for every entry in the catalogue,
on every call that asks what is available."
  (a:when-let ((key (auth:key-for (getf entry :label) (getf entry :key) :auth auth)))
    (let ((provider (provider:openai-provider
                     :endpoint (or (from-environment (getf entry :endpoint-var))
                                   (getf entry :endpoint))
                     :api-key key)))
      (loop for (label . model) in (entry-models entry)
            collect (make-choice :label label
                                 :endpoint-label (getf entry :label)
                                 :model model
                                 :effort (getf entry :effort)
                                 :context-limit (entry-limit entry)
                                 :provider provider)))))

(defun endpoint-defaults (choices)
  "One choice per endpoint: the first each offers.

WHAT A SWEEP MEANS BY `every arm`. An endpoint serving eight models would
otherwise turn one battery into eight, which is a bill rather than a default.
Naming a model explicitly still reaches every one of them."
  (let ((seen '()))
    (loop for choice in choices
          for endpoint = (or (choice-endpoint-label choice) (choice-label choice))
          unless (member endpoint seen :test #'equal)
            do (push endpoint seen) and collect choice)))

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
  ;; The auth file, read once for the whole catalogue rather than once per
  ;; provider in it.
  (let ((auth (auth:read-auth)))
    (remove nil (append (loop for entry in +catalogue+
                              append (entry-choices entry :auth auth))
                        (list (local-choice))))))

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
                 ;; THE ENDPOINT'S OWN NAME, last. `bedrock` names a catalogue
                 ;; rather than a model, and a person who asks for it means
                 ;; whichever of them is first.
                 (find label available :key #'choice-endpoint-label :test #'equal-label)
                 (error "No model called ~s. Available: ~{~a~^, ~}"
                        label (mapcar #'choice-label available)))))))
