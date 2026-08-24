;;;; Conversation data: content blocks and the three kinds of message.
;;;;
;;;; Structs rather than classes because these are values that get copied and
;;;; compared, never redefined at runtime. The things an agent mutates while it
;;;; runs -- its prompt, its tool set -- live in AGENT.LISP as CLOS objects.

(in-package #:viva.message)

(defstruct (text (:constructor make-text (value)))
  (value "" :type string))

(defstruct (thinking (:constructor make-thinking (value)))
  (value "" :type string))

(defstruct (tool-call (:conc-name tool-call-))
  (id "" :type string)
  (name "" :type string)
  ;; Arguments stay a hash table rather than a plist: they arrive as JSON and
  ;; are handed straight back to a tool that declared a JSON schema.
  (arguments nil))

(defstruct message
  (role :user :type keyword)
  (content '() :type list))

(defstruct (assistant-message (:include message (role :assistant))
                              (:conc-name assistant-message-))
  ;; :STOP, :LENGTH, :TOOL-CALLS, :ERROR or :ABORTED. :LENGTH is load-bearing --
  ;; it means the response was cut off mid-emission, so any tool call in it may
  ;; carry truncated arguments.
  (stop-reason :stop :type keyword)
  (usage nil))

(defstruct (user-message (:include message (role :user))
                         (:conc-name user-message-)))

(defstruct (tool-result-message (:include message (role :tool))
                                (:conc-name tool-result-message-))
  (call-id "" :type string)
  (output "" :type string)
  (error-p nil :type boolean))

(defun tool-calls-in (message)
  (remove-if-not #'tool-call-p (message-content message)))

(defun text-of (message)
  "The concatenated text blocks of MESSAGE, ignoring thinking and tool calls."
  (format nil "~{~a~^~%~}"
          (mapcar #'text-value (remove-if-not #'text-p (message-content message)))))
