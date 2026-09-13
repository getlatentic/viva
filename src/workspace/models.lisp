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
     :model-var "OPENAI_MODEL"
     :models ("gpt-4.1-mini"))
    (:label "openrouter" :key "OPENROUTER_API_KEY" :effort "low"
     :endpoint-var "OPENROUTER_ENDPOINT" :endpoint "https://openrouter.ai/api/v1/chat/completions"
     :model-var "OPENROUTER_MODEL"
     :models ("openai/gpt-oss-120b"))
    ;; ONE ID, AND A PLACE TO ADD THE REST. DeepSeek serves a family -- flash
    ;; and pro, and revisions of each -- and this lists only the id this
    ;; repository has actually run against. Guessing the others would put a
    ;; 404 in the one table people trust; `models` in auth.json adds them
    ;; without waiting for a release.
    (:label "deepseek" :key "DEEPSEEK_API_KEY"
     :endpoint-var "DEEPSEEK_ENDPOINT" :endpoint "https://api.deepseek.com/v1/chat/completions"
     :model-var "DEEPSEEK_MODEL"
     :models ("deepseek-v4-flash"))
    ;; Bedrock through its OpenAI-compatible endpoint: a BEARER TOKEN, not
    ;; SigV4. Verified against /v1/models before this was written rather than
    ;; assumed, which is why there is no request signing anywhere in the tree.
    ;; The base URL is deployment-specific -- another region is another URL,
    ;; and auth.json's `endpoint` is where that goes.
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
     :models ("openai.gpt-oss-120b"
              ;; Good prose, weaker at holding a field format than 120b, so
              ;; reach for it where the answer is text rather than structure.
              "openai.gpt-oss-20b"
              "openai.gpt-oss-safeguard-120b"
              "openai.gpt-oss-safeguard-20b"
              "zai.glm-5"
              "moonshotai.kimi-k2.5"
              "minimax.minimax-m2.5"
              "deepseek.v3.2"
              "qwen.qwen3-coder-480b-a35b-instruct"
              "nvidia.nemotron-super-3-120b")))
  "Providers, each with the models it serves, in preference order.

ONE KEY PER PROVIDER, MANY MODELS UNDER IT -- the shape Pi's `Provider` has:
one `auth`, and `getModels()`. An entry per model would repeat the key and the
endpoint on every line, and a person adding a model would have to get three
things right instead of one.")

(defun equal-label (wanted found)
  (and (stringp found) (string-equal wanted found)))

(defun from-environment (name)
  (let ((value (sb-posix:getenv name)))
    (and value (plusp (length value)) value)))

(defun endpoint-for (entry auth)
  "Where this provider lives: auth.json, then the environment, then the default.

THE SAME ORDER AUTH:KEY-FOR USES, and for its reason: the environment is where
a shell leaves whatever it happened to export, and the file is where somebody
wrote something down on purpose. One file resolving its key one way and its
endpoint the other is a rule nobody could hold."
  (or (auth:entry-setting (getf entry :label) "endpoint" :auth auth)
      (from-environment (getf entry :endpoint-var))
      (getf entry :endpoint)))

(defun pinned-model (entry auth)
  "The model this machine means by the endpoint's own name, if it names one."
  (or (auth:entry-setting (getf entry :label) "model" :auth auth)
      (from-environment (getf entry :model-var))))

(defun entry-limit (entry)
  (or (a:when-let ((given (from-environment "VIVA_CONTEXT_LIMIT")))
        (parse-integer given :junk-allowed t))
      (getf entry :context-limit 128000)))

(defun listed-models (entry auth)
  "The model ids this provider offers: auth.json's list, else the built-in one.

AUTH.JSON WINS OUTRIGHT rather than merging. A provider serves a family that
changes faster than this table does, and somebody who wrote down four ids
means those four -- a merge would keep handing back a fifth they had removed."
  (or (a:when-let ((named (auth:entry-list (getf entry :label) "models" :auth auth)))
        named)
      (getf entry :models)))

(defun entry-models (entry auth)
  "The (LABEL . MODEL-ID) pairs this provider offers.

LABEL IS `provider/id`, always. `deepseek` is a provider and not a model, so a
choice called `deepseek` was a promise about whichever id the table happened to
list first. The id goes in whole: a short alias beside it is a second name to
keep true, and the id is the thing that reaches the wire.

The provider's own name still resolves, to whatever it pins or lists first, so
`--model deepseek` keeps meaning `this provider, its usual model`."
  (let* ((label (getf entry :label))
         (pinned (pinned-model entry auth))
         (ids (listed-models entry auth)))
    (loop for id in (if (and pinned (not (member pinned ids :test #'equal)))
                        (cons pinned ids)
                        (cons (or pinned (first ids)) (rest* pinned ids)))
          collect (cons (format nil "~a/~a" label id) id))))

(defun rest* (pinned ids)
  "IDS without the one already placed first."
  (if pinned (remove pinned ids :test #'equal :count 1) (rest ids)))

(defun entry-choices (entry &key (auth (auth:read-auth)))
  "ENTRY as usable choices, or NIL where it has no key.

The auth file is read once by the caller and passed down. Reading it per
provider would open and parse the same file for every entry in the catalogue,
on every call that asks what is available."
  (a:when-let ((key (auth:key-for (getf entry :label) (getf entry :key) :auth auth)))
    (let ((provider (provider:openai-provider
                     :endpoint (endpoint-for entry auth)
                     :api-key key)))
      (loop for (label . model) in (entry-models entry auth)
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
           ;; NAMES THE FILE. The old message named the environment and a file
          ;; of shell exports, which is what people then made -- so the
          ;; discoverable answer was the one being removed.
          (error "No model is configured. Put a key in ~a, shaped like:~%~%~a~%~%~
Or set one of ~{~a~^, ~} in the environment."
                 (env:auth-path) auth:*file-shape*
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
