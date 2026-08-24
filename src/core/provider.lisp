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
