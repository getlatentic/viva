;;;; Where one model server differs from another.
;;;;
;;;; The request is an ordinary OpenAI-compatible chat completion and the core
;;;; knows nothing else. Everything a particular server adds on top -- grammars,
;;;; template keyword arguments, an output protocol a constrained grammar has to
;;;; respect -- lives behind these generic functions, so a server that lacks a
;;;; feature simply does not answer for it rather than the core testing for it.
;;;;
;;;; The default is deliberately the least capable thing: plain chat completions
;;;; with no extensions. A provider earns its extras by declaring them.

(in-package #:viva.provider)

(defclass provider ()
  ((endpoint :initarg :endpoint :accessor provider-endpoint
             :initform "http://localhost:8080/v1/chat/completions" :type string)
   (api-key :initarg :api-key :accessor provider-api-key :initform nil)
   (name :initarg :name :accessor provider-name :initform "openai-compatible")))

(defun make-default-provider ()
  "A plain OpenAI-compatible server at the conventional local address.
Least-capable on purpose: no grammar, no template arguments."
  (make-instance 'provider))

(defmethod print-object ((provider provider) stream)
  (print-unreadable-object (provider stream :type t)
    (format stream "~a ~a" (provider-name provider) (provider-endpoint provider))))

(defgeneric headers (provider)
  (:method ((provider provider))
    (append '(("Content-Type" . "application/json"))
            (a:when-let ((key (provider-api-key provider)))
              (list (cons "Authorization" (format nil "Bearer ~a" key)))))))

(defgeneric request-url (provider &key stream)
  (:documentation "Where one request goes, and the streaming form when STREAM.

Generic because not every API puts streaming in the body. IBM's gives it a
route of its own, so the address cannot be read off a slot alone.")
  (:method ((provider provider) &key stream)
    (declare (ignore stream))
    (provider-endpoint provider)))

(defgeneric supports-grammar-p (provider)
  (:documentation "Can this server constrain sampling to a supplied grammar?")
  (:method ((provider provider)) nil))

(defgeneric constrained-output-prefix (provider)
  (:documentation "Literal a constrained grammar must begin with.

A grammar constrains the whole completion, including whatever framing the
server's chat template expects afterwards. Where that framing exists, a grammar
that omits it produces output the server cannot parse. NIL where there is none."
  )
  (:method ((provider provider)) nil))

(defgeneric augment-payload (provider payload agent)
  (:documentation "Add server-specific fields to a finished request body.
Called last, so a provider can also override what the core set.")
  (:method ((provider provider) payload agent)
    (declare (ignore agent))
    payload))

;;; llama.cpp
;;;
;;; Wanted for scored work because it exposes a seed, full sampler control,
;;; parallel slots and GBNF. The last of those is why CONSTRAINED-OUTPUT-PREFIX
;;; exists at all.

(defclass llama-cpp (provider)
  ((name :initform "llama.cpp")
   (output-prefix :initarg :output-prefix :accessor llama-output-prefix :initform nil
                  :documentation "Set for a model whose template frames its output.
Harmony models (gpt-oss) need \"<|channel|>final<|message|>\": without it
llama-server rejects its own model's output as unparseable.")))

(defmethod supports-grammar-p ((provider llama-cpp)) t)

(defmethod constrained-output-prefix ((provider llama-cpp))
  (llama-output-prefix provider))

(defmethod augment-payload ((provider llama-cpp) payload agent)
  (a:when-let ((grammar (agent:agent-grammar agent)))
    (setf (gethash "grammar" payload) grammar))
  (a:when-let ((effort (agent:agent-reasoning-effort agent)))
    ;; llama.cpp reads this from the chat template rather than from a field.
    (setf (gethash "chat_template_kwargs" payload)
          (let ((kwargs (make-hash-table :test #'equal)))
            (setf (gethash "reasoning_effort" kwargs) effort)
            kwargs)))
  payload)

(defparameter +harmony-output-prefix+ "<|channel|>final<|message|>"
  "What a harmony model (gpt-oss and kin) frames its final message with.")

(defun llama-cpp-provider (&key (endpoint "http://localhost:8080/v1/chat/completions")
                                output-prefix api-key)
  (make-instance 'llama-cpp :endpoint endpoint :output-prefix output-prefix
                            :api-key api-key))

;;; A hosted OpenAI-compatible API
;;;
;;; No grammar, no template keyword arguments. Reasoning effort is a top-level
;;; field here, which is exactly the kind of difference this file exists to hold.

(defclass openai (provider)
  ((name :initform "openai")
   (endpoint :initform "https://api.openai.com/v1/chat/completions")))

(defmethod augment-payload ((provider openai) payload agent)
  (a:when-let ((effort (agent:agent-reasoning-effort agent)))
    (setf (gethash "reasoning_effort" payload) effort))
  payload)

(defun openai-provider (&key api-key (endpoint "https://api.openai.com/v1/chat/completions"))
  (make-instance 'openai :endpoint endpoint :api-key api-key))

;;; watsonx
;;;
;;; IBM's inference API carries OpenAI-shaped messages inside a request of its
;;; own, and four differences live here: the body names the project that pays
;;; for the call, the model is `model_id`, streaming is a second route rather
;;; than a field, and the key buys an access token that every request spends.

(defparameter *iam-token-url* "https://iam.cloud.ibm.com/identity/token"
  "Where an API key is exchanged for an access token.")

(defun mint-iam-token (api-key)
  "Exchange API-KEY for an access token. Values: the token, and how many seconds
it is good for."
  (let ((answer (com.inuoe.jzon:parse
                 (dexador:post *iam-token-url*
                               :headers '(("Accept" . "application/json"))
                               :content `(("grant_type" . "urn:ibm:params:oauth:grant-type:apikey")
                                          ("apikey" . ,api-key))))))
    (values (gethash "access_token" answer)
            (or (gethash "expires_in" answer) 3600))))

(defparameter *mint-token* #'mint-iam-token
  "How a key becomes a token. A test has no IBM account to ask, and rebinds this.")

(defparameter *watsonx-version* "2023-05-02"
  "The version every watsonx route takes, and the one IBM's own examples pass.
A date, because IBM changes what an endpoint does under a newer one and leaves
the older date answering as it did.")

(defclass watsonx (openai)
  ((name :initform "watsonx")
   ;; THE SITE, NOT THE ROUTE. Which region holds the instance is a person's to
   ;; say. Which path serves a chat is this file's, and a person who wrote the
   ;; whole URL down would have to write a second one to stream from it.
   (endpoint :initform "https://us-south.ml.cloud.ibm.com")
   (project :initarg :project :initform nil :reader watsonx-project)
   (space :initarg :space :initform nil :reader watsonx-space)
   (token :initform nil :accessor watsonx-token)
   (good-until :initform 0 :accessor watsonx-good-until)
   (lock :initform (bordeaux-threads:make-lock "viva.watsonx") :reader watsonx-lock)))

(defmethod request-url ((provider watsonx) &key stream)
  (format nil "~a/ml/v1/text/~:[chat~;chat_stream~]?version=~a"
          (string-right-trim "/" (provider-endpoint provider))
          stream *watsonx-version*))

(defun live-token (provider)
  "The access token, minted when the one held has expired or is about to.

A MINUTE OF MARGIN, because a token that expires between the header and the
answer is a refusal on work already begun. Under a lock, so two sessions
starting a turn together buy one token rather than two."
  (bordeaux-threads:with-lock-held ((watsonx-lock provider))
    (when (>= (get-universal-time) (watsonx-good-until provider))
      (multiple-value-bind (token seconds) (funcall *mint-token* (provider-api-key provider))
        (setf (watsonx-token provider) token
              (watsonx-good-until provider) (+ (get-universal-time) (max 60 (- seconds 60))))))
    (watsonx-token provider)))

(defmethod headers ((provider watsonx))
  (list '("Content-Type" . "application/json")
        (cons "Authorization" (format nil "Bearer ~a" (live-token provider)))))

(defmethod augment-payload ((provider watsonx) payload agent)
  (let ((payload (call-next-method)))
    (a:when-let ((model (gethash "model" payload)))
      (setf (gethash "model_id" payload) model)
      (remhash "model" payload))
    ;; WHO PAYS. IBM refuses a request that names neither a project nor a
    ;; deployment space, and a key says which account but not which of these.
    (a:when-let ((project (watsonx-project provider)))
      (setf (gethash "project_id" payload) project))
    (a:when-let ((space (watsonx-space provider)))
      (setf (gethash "space_id" payload) space))
    ;; `auto` is a word in one field here and a named tool in the other, where
    ;; OpenAI spells both with `tool_choice`.
    (let ((choice (gethash "tool_choice" payload)))
      (when (stringp choice)
        (setf (gethash "tool_choice_option" payload) choice)
        (remhash "tool_choice" payload)))
    ;; The route carries the streaming decision, and the schema has no room for
    ;; the rest. A field IBM does not list is a refusal, where an
    ;; OpenAI-compatible server would have ignored it.
    (dolist (unlisted '("stream" "stream_options" "parallel_tool_calls") payload)
      (remhash unlisted payload))))

(defun watsonx-provider (&key api-key project space
                              (endpoint "https://us-south.ml.cloud.ibm.com"))
  (make-instance 'watsonx :endpoint endpoint :api-key api-key
                          :project project :space space))
