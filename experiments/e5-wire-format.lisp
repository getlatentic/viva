;;;; E5, groundwork: can a model emit s-expressions as reliably as JSON calls?
;;;;
;;;; The JSON arm is the model's trained path and llama.cpp compiles its schema
;;;; into a grammar automatically, so a malformed call is impossible. The Lisp
;;;; arm is off that path, which is why it brings its own GBNF -- otherwise the
;;;; comparison is between a constrained format and an unconstrained one and
;;;; tells you about grammars rather than about formats.
;;;;
;;;; Also measures the escaping tax: today INSTALL carries a definition as a JSON
;;;; string, so every quote and newline is escaped. As a form it is not.
;;;;
;;;;   llama-server -m <model>.gguf --jinja --port 8099 -c 8192 -ngl 99
;;;;   sbcl --non-interactive --load experiments/e5-wire-format.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium :silent t)

(defpackage #:vivarium.e5
  (:use #:cl)
  (:local-nicknames (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client)
                    (#:provider #:vivarium.provider)
                    (#:sexp #:vivarium.sexp)))

(in-package #:vivarium.e5)

(defparameter *provider*
  (provider:llama-cpp-provider :endpoint "http://localhost:8099/v1/chat/completions"
                              :output-prefix provider:+harmony-output-prefix+))

(defparameter *parameters*
  '(("source" nil "One top level definition" :required-p t)
    ("note" :string "What this changes" :required-p t)))

(tool:define-tool install-tool (args context)
  :description "Compile one top level definition into the running image."
  :parameters (("source" :string "One top level form" :required-p t)
               ("note" :string "What this changes" :required-p t))
  "installed")

(defparameter *task*
  "Write a function ORDER-TOTAL that takes a list of plists with :qty and :price
and returns the sum of qty times price, treating a NIL price as zero. Install it
with a one line note.")

(defun user (text) (msg:make-user-message :content (list (msg:make-text text))))

(defun ask (agent text)
  (client:complete agent (list (user text))))

;;; The escaping tax

(defparameter *definition*
  "(defun order-total (lines)
  \"Total an order, treating a comped line as zero.\"
  (reduce #'+ (mapcar (lambda (line)
                        (* (or (getf line :qty) 0) (or (getf line :price) 0)))
                      lines)))")

(defun escaping-tax ()
  (let* ((as-json (com.inuoe.jzon:stringify *definition*))
         (raw (length *definition*))
         (escaped (length as-json)))
    (format t "~&=== the escaping tax on one definition ===~%")
    (format t "  as a form:        ~d characters~%" raw)
    (format t "  as a JSON string: ~d characters (+~,1f%)~%"
            escaped (* 100 (/ (- escaped raw) raw)))
    (format t "  escapes the model must place: ~d~%"
            (count-if (lambda (c) (char= c #\\)) as-json))))

;;; The two arms

(defun json-arm ()
  (format t "~&~%=== JSON arm: native function calling ===~%")
  (let* ((agent (make-instance 'agent:queued-agent :provider *provider*
                               :model "gpt-oss-20b" :reasoning-effort "low"
                               :system-prompt "Use your tools." :tools (list install-tool)
                               :max-tokens 2048))
         (message (ask agent *task*))
         (calls (msg:tool-calls-in message)))
    (if (null calls)
        (format t "  no tool call: ~a~%" (msg:assistant-message-stop-reason message))
        (let* ((source (gethash "source" (msg:tool-call-arguments (first calls))))
               (parsed (handler-case (progn (sexp:read-form source) :readable)
                         (error (c) (princ-to-string c)))))
          (format t "  call:      ~a~%" (msg:tool-call-name (first calls)))
          (format t "  source is: ~a~%" parsed)
          (format t "  ~a~%" (substitute #\Space #\Newline
                                         (subseq source 0 (min 150 (length source)))))))))

(defun sexp-arm ()
  (format t "~&~%=== Lisp arm: one GBNF-constrained s-expression ===~%")
  (let* ((grammar (sexp:grammar-for "install" *parameters* :prefix provider:+harmony-output-prefix+))
         (agent (make-instance 'agent:queued-agent :provider *provider*
                               :model "gpt-oss-20b" :reasoning-effort "low"
                               :grammar grammar
                               :system-prompt
                               (format nil "Reply with exactly one form and nothing else:
  (install :source <the definition> :note \"...\")
The definition is written as a form, not as a string.")
                               :max-tokens 2048))
         (message (ask agent *task*))
         (text (string-trim '(#\Newline #\Space) (msg:text-of message))))
    (format t "  raw: ~a~%" (substitute #\Space #\Newline
                                        (subseq text 0 (min 200 (length text)))))
    (handler-case
        (multiple-value-bind (name arguments) (sexp:call-arguments (sexp:read-form text))
          (format t "  parsed:    ~a~%" name)
          (format t "  note:      ~s~%" (gethash "note" arguments))
          (let ((source (gethash "source" arguments)))
            (format t "  source is: ~a~%"
                    (if (consp source) "a form, read directly" "not a form"))
            (when (consp source)
              (format t "  ~a~%" (let ((*package* (find-package :vivarium.sexp.sandbox)))
                                   (write-to-string source :length 12 :level 4))))))
      (error (condition) (format t "  UNPARSEABLE: ~a~%" condition)))))

(handler-case
    (progn (escaping-tax) (json-arm) (sexp-arm)
           (format t "~&~%Read this as: whether the Lisp arm is even viable before~%")
           (format t "asking whether one tool beats five.~%"))
  (error (condition)
    (format t "~&FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
