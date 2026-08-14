;;;; Reading a field off an OpenAI-compatible response.
;;;;
;;;; "OpenAI-compatible" is a family resemblance, not a specification, and the
;;;; two places it frays are both here. Servers disagree about how a field that
;;;; has no value is spelled -- absent, JSON null, or a null the parser hands
;;;; back as a symbol -- and they disagree about which key carries chain of
;;;; thought. Both the blocking parser and the streaming accumulator read the
;;;; same wire, so neither owns this vocabulary and it lives on its own.

(in-package #:vivarium.wire)

(defun present (value)
  "NIL for a missing key or a JSON null, however the parser spells it.

Not defensiveness for its own sake. llama.cpp's final usage chunk carries
`choices: null`; OpenRouter sends `content: null` on any message that is
entirely tool calls; a streaming delta has null wherever a field is simply
absent this tick. jzon renders JSON null as a symbol, which is *true* and has
no length, so reading one as a value fails somewhere far from the cause -- the
observed failure is `The value NULL is not of type SEQUENCE`, which names
neither the field nor the server."
  (cond ((null value) nil)
        ((eq value :null) nil)
        ((and (symbolp value) (string= "NULL" (symbol-name value))) nil)
        (t value)))

(defun field (table key)
  (and (hash-table-p table) (present (gethash key table))))

(defun text-field (table key)
  (let ((value (field table key)))
    (and (stringp value) (plusp (length value)) value)))

(defparameter +reasoning-keys+ '("reasoning_content" "reasoning")
  "Where a server puts chain of thought, in the order to look.

llama.cpp and DeepSeek use the first, OpenRouter the second. A model that
reasons before answering leaves `content` empty until it is done, so reading
only one spelling makes a working run against the other server look silent.")

(defun reasoning-field (table)
  (some (lambda (key) (text-field table key)) +reasoning-keys+))
