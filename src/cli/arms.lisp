;;;; Which model an arm reaches, and how.
;;;;
;;;; One place, because every experiment needs the same three lines and each
;;;; copy is another thing to update when an endpoint or a model id moves. An
;;;; arm whose credentials are absent is simply not offered -- a missing key
;;;; should be a missing column, never a row of zeros that reads as a model
;;;; failing the task.

(in-package #:vivarium.cli)

(defstruct (arm (:conc-name arm-))
  (label "" :type string)
  (provider nil)
  (model "" :type string)
  (effort nil))

(defun env (name)
  (let ((value (sb-posix:getenv name)))
    (and value (plusp (length value)) value)))

(defun listening-p (endpoint)
  "Is anything answering at ENDPOINT? Cheap TCP connect, no request."
  (when endpoint
    (let* ((after (search "//" endpoint))
           (rest (subseq endpoint (+ after 2)))
           (host-port (subseq rest 0 (position #\/ rest)))
           (colon (position #\: host-port)))
      (ignore-errors
       (let ((socket (usocket:socket-connect (subseq host-port 0 colon)
                                             (parse-integer (subseq host-port (1+ colon)))
                                             :timeout 1)))
         (usocket:socket-close socket)
         t)))))

(defun openai-compatible (endpoint key) (provider:openai-provider :endpoint endpoint :api-key key))

(defun available-arms ()
  (remove
   nil
   (list
    (a:when-let ((key (env "OPENROUTER_API_KEY")))
      (make-arm :label "gpt-oss-120b" :effort "low"
                :model (or (env "OPENROUTER_MODEL") "openai/gpt-oss-120b")
                :provider (openai-compatible "https://openrouter.ai/api/v1/chat/completions" key)))
    (a:when-let ((key (env "DEEPSEEK_API_KEY")))
      (make-arm :label "deepseek-flash"
                :model (or (env "DEEPSEEK_MODEL") "deepseek-v4-flash")
                :provider (openai-compatible
                           (or (env "DEEPSEEK_ENDPOINT")
                               "https://api.deepseek.com/v1/chat/completions")
                           key)))
    ;; Bedrock, through its OpenAI-compatible endpoint. A BEARER TOKEN, not
    ;; SigV4: /v1/models answers 200 to a plain Authorization header, so no
    ;; request signing is needed and the ordinary provider works unchanged.
    ;; Verified before writing this rather than assumed.
    (a:when-let ((key (env "BEDROCK_API_KEY")))
      (make-arm :label "bedrock" :effort "low"
                :model (or (env "BEDROCK_MODEL") "google.gemma-4-31b")
                :provider (openai-compatible
                           (or (env "BEDROCK_ENDPOINT")
                               "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions")
                           key)))
    ;; Local llama-server, and the only arm that can carry a GBNF grammar --
    ;; which is why E5's constrained arm cannot run anywhere else. Offered only
    ;; if something is actually listening: a configured endpoint with no server
    ;; behind it produced a whole column of "err" in one sweep, which costs an
    ;; attempt per cell and reads like a model failing rather than a missing one.
    (a:when-let ((endpoint (and (listening-p (env "VIVARIUM_LOCAL_ENDPOINT"))
                                (env "VIVARIUM_LOCAL_ENDPOINT"))))
      (make-arm :label "local" :effort "low"
                :model (or (env "VIVARIUM_LOCAL_MODEL") "gpt-oss-20b")
                :provider (provider:llama-cpp-provider
                           :endpoint endpoint
                           :output-prefix provider:+harmony-output-prefix+))))))

(defun arms-named (names)
  "NAMES is NIL for every available arm, or a list of labels."
  (let ((available (available-arms)))
    (if (null names)
        available
        (mapcar (lambda (name)
                  (or (find name available :key #'arm-label :test #'string-equal)
                      (error "No arm called ~s. Available: ~{~a~^, ~}"
                             name (mapcar #'arm-label available))))
                names))))
