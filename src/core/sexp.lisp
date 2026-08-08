;;;; S-expressions as the wire format for structured model output.
;;;;
;;;; The JSON path works and stays: it is what the model was trained on, and
;;;; llama.cpp compiles a tool's JSON Schema into a GBNF grammar so a malformed
;;;; call is structurally impossible. This file is the Lisp-native alternative,
;;;; built so the same comparison can be made on equal terms.
;;;;
;;;; Two things make it worth measuring rather than assuming:
;;;;
;;;;   - the payload is already Lisp. INSTALL's argument today is a JSON string
;;;;     containing a definition, so the model must emit correctly escaped JSON
;;;;     wrapping correct Lisp -- two layers, two ways to be wrong. As a form it
;;;;     is one layer and no escaping;
;;;;   - the schema is the lambda list. Keyword arguments are named parameters,
;;;;     so a tool's signature is its schema with nothing to keep in sync.
;;;;
;;;; And one reason it may lose: models have seen far more JSON tool calls than
;;;; Lisp ones. Going off the trained path is a real cost, which is why GRAMMAR
;;;; exists -- constraining the sampler is what buys back the guarantee.
;;;;
;;;; Reading model output is the dangerous part. *READ-EVAL* is off and the
;;;; reader runs in a package of its own, so a form can name a symbol without
;;;; that naming reaching any package the image cares about.

(in-package #:vivarium.sexp)

(defpackage #:vivarium.sexp.sandbox
  (:use)
  ;; T and NIL must be the real ones. A package that inherits nothing reads the
  ;; model's `nil` as a fresh symbol named "NIL", which is not the empty list and
  ;; is emphatically true -- so `:express nil` would arrive as a truthy value and
  ;; every boolean argument would silently mean its opposite.
  (:import-from #:common-lisp #:t #:nil)
  (:documentation "Where symbols in model-emitted forms are interned, so naming
something in a form cannot touch a package the image uses."))

(define-condition unreadable (error)
  ((detail :initarg :detail :reader unreadable-detail))
  (:report (lambda (condition stream)
             (write-string (unreadable-detail condition) stream))))

(defvar *limit* 20000
  "Longest form text accepted. An unbounded read from a model is a way to spend
the heap on a mistake.")

(defun read-form (text &key (package "VIVARIUM.SEXP.SANDBOX"))
  "Read exactly one form from TEXT with evaluation disabled.

Interning happens in a sandbox package so an unknown symbol in model output does
not land in one that matters. A tool that needs real symbols resolves them
itself, deliberately."
  (when (> (length text) *limit*)
    (error 'unreadable :detail (format nil "Form is longer than ~d characters." *limit*)))
  (let ((home (or (find-package package)
                  (error 'unreadable :detail (format nil "No such package: ~a" package)))))
    (handler-case
        (let ((*package* home)
              (*read-eval* nil))
          (multiple-value-bind (form position) (read-from-string text)
            (unless (eq :eof (read-from-string text nil :eof :start position))
              (error 'unreadable :detail "Expected exactly one form, found more."))
            form))
      (unreadable (condition) (error condition))
      (error (condition)
        (error 'unreadable :detail (format nil "Could not read the form: ~a" condition))))))

;;; A call as a form
;;;
;;; (shipping-cost :weight 7) rather than {"name": ..., "arguments": {...}}.
;;; Converted into the same arguments table the JSON path produces, so tools,
;;; schemas and validation are shared and only the wire format differs.

(defun keyword-name (symbol)
  (string-downcase (substitute #\- #\_ (symbol-name symbol))))

(defun call-arguments (form)
  "Turn (NAME :key value ...) into (values tool-name arguments-table)."
  (unless (and (consp form) (symbolp (first form)))
    (error 'unreadable :detail "Expected a call of the form (tool-name :key value ...)."))
  (let ((table (make-hash-table :test #'equal))
        (rest (rest form)))
    (loop while rest
          do (let ((key (pop rest)))
               (unless (keywordp key)
                 (error 'unreadable
                        :detail (format nil "Expected a keyword argument, got ~s." key)))
               (when (null rest)
                 (error 'unreadable
                        :detail (format nil "~s has no value." key)))
               (setf (gethash (keyword-name key) table) (pop rest))))
    (values (substitute #\_ #\- (string-downcase (symbol-name (first form)))) table)))

;;; GBNF
;;;
;;; llama.cpp compiles a JSON Schema into a grammar automatically. Nothing does
;;; that for s-expressions, so a fair comparison has to build one -- otherwise
;;; the Lisp arm is measured without the structural guarantee the JSON arm gets
;;; for free, and any difference is about grammars rather than about formats.

(defun terminal (type)
  (cond ((null type) "value")
        ((and (consp type) (eq :array (first type))) "list")
        (t (case type
             (:string "string")
             (:integer "integer")
             (:number "number")
             (:boolean "boolean")
             (:object "list")
             (t "value")))))

(defun parameter-rule (spec)
  (destructuring-bind (name type description &key required-p enum default) spec
    (declare (ignore description default))
    (let ((slot (format nil "\" :~a \" ~a" name
                        (if enum
                            (format nil "(~{\"~a\"~^ | ~})" enum)
                            (terminal type)))))
      (if required-p slot (format nil "(~a)?" slot)))))

(defun tool-rule (tool-name parameters)
  (format nil "\"(~a\" ~{~a ~}\")\"" tool-name
          (mapcar #'parameter-rule parameters)))

(defparameter *preamble*
  "ws ::= [ \\t\\n]*
integer ::= \"-\"? [0-9]+
number ::= \"-\"? [0-9]+ (\".\" [0-9]+)?
boolean ::= (\"t\" | \"nil\")
string ::= \"\\\"\" ([^\"\\\\] | \"\\\\\" .)* \"\\\"\"
atom ::= integer | number | string | boolean | [a-zA-Z*+/<>=-][a-zA-Z0-9*+/<>=-]*
list ::= \"(\" ws (value (ws value)*)? ws \")\"
value ::= atom | list"
  "Shared terminals. Kept separate so a grammar is a preamble plus one root.")

(defvar *channel-prefix* nil
  "Literal the model's own output protocol requires before free text.

A grammar constrains the WHOLE completion, including whatever framing the chat
template expects. Sending a bare s-expression grammar to a harmony model
(gpt-oss) makes llama.cpp reject its own model's output with \"does not match the
expected peg-native format\" -- the grammar forbade the channel markers the
server then tried to parse. llama.cpp's generated tool grammars carry those
markers for the same reason.

For harmony: \"<|channel|>final<|message|>\". NIL for a raw completion endpoint
or a model with no channel protocol.")

(defun with-prefix (root)
  (if *channel-prefix* (format nil "~s ~a" *channel-prefix* root) root))

(defun grammar-for (name parameters &key (prefix *channel-prefix*))
  "A GBNF that admits exactly one well-formed call to this tool."
  (let ((*channel-prefix* prefix))
    (format nil "root ::= ~a~%~a" (with-prefix (tool-rule name parameters)) *preamble*)))

(defun grammar-for-tools (named-parameters &key (prefix *channel-prefix*))
  "A GBNF admitting a call to any one of NAMED-PARAMETERS, ((name . params) ...)."
  (let* ((*channel-prefix* prefix)
         (rules (loop for (name . parameters) in named-parameters
                     for index from 0
                     collect (cons (format nil "call~d" index)
                                   (tool-rule name parameters)))))
    (format nil "root ::= ~a~%~{~a~%~}~a"
            (with-prefix (format nil "(~{~a~^ | ~})" (mapcar #'car rules)))
            (mapcar (lambda (rule) (format nil "~a ::= ~a" (car rule) (cdr rule))) rules)
            *preamble*)))

(defun form-grammar (&key (prefix *channel-prefix*))
  "For a tool whose argument is arbitrary Lisp -- an EVAL tool, or INSTALL taking
a definition as a form rather than as an escaped string."
  (let ((*channel-prefix* prefix))
    (format nil "root ::= ~a~%~a" (with-prefix "list") *preamble*)))

(defun grammar-prefix-for (provider)
  "The prefix this server's output protocol requires, if any.

Kept as a question asked of the provider rather than a constant here: which
literal a grammar must open with is a property of the model's template, not of
s-expressions."
  (and provider (funcall (find-symbol "CONSTRAINED-OUTPUT-PREFIX" "VIVARIUM.PROVIDER")
                         provider)))
