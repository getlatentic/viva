;;;; Live smoke test against a running llama-server.
;;;;
;;;; Not part of the suite -- it needs a model on *ENDPOINT*. Run it after any
;;;; change to CLIENT.LISP, because the scripted tests deliberately bypass the
;;;; whole provider boundary and would not notice it breaking.
;;;;
;;;;   llama-server -m <model>.gguf --jinja --port 8099 -c 8192 -ngl 99
;;;;   sbcl --non-interactive --load tests/smoke.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :viva :silent t)

(defpackage #:viva.smoke
  (:use #:cl)
  (:local-nicknames (#:msg #:viva.message)
                    (#:tool #:viva.tool)
                    (#:agent #:viva.agent)
                    (#:client #:viva.client)
                    (#:provider #:viva.provider)
                    (#:loop* #:viva.loop)))

(in-package #:viva.smoke)

(defparameter *provider*
  (provider:llama-cpp-provider :endpoint "http://localhost:8099/v1/chat/completions"
                              :output-prefix provider:+harmony-output-prefix+))

(defvar *calls* '())

(tool:define-tool describe-symbol (args ctx)
  :description "Return the argument list of a Common Lisp function."
  :parameters (("name" :string "The function name, e.g. MAPCAR" :required-p t))
  (let ((name (gethash "name" args)))
    (push name *calls*)
    (format nil "~a takes ~a"
            name
            (or (ignore-errors
                 (princ-to-string
                  (sb-introspect:function-lambda-list (find-symbol (string-upcase name) :cl))))
                "unknown arguments"))))

(defclass loud-agent (agent:queued-agent) ())

(defmethod agent:emit ((agent loud-agent) event)
  (case (getf event :type)
    (:tool-start (format t "~&  → ~a ~a~%"
                         (msg:tool-call-name (getf event :call))
                         (com.inuoe.jzon:stringify
                          (msg:tool-call-arguments (getf event :call)))))
    (:tool-end (format t "~&  ← ~a~%" (tool:tool-result-output (getf event :result))))))

(defun user (text) (msg:make-user-message :content (list (msg:make-text text))))

(defun report (label messages)
  (format t "~&~%[~a] ~d messages~%" label (length messages))
  (let ((final (find-if #'msg:assistant-message-p (reverse messages))))
    (format t "  final: ~a~%" (msg:text-of final))))

(defun run-case (label prompt user-text &key tools)
  (let ((agent (make-instance 'loud-agent
                              :model "gpt-oss-20b"
                              :system-prompt prompt
                              :tools tools
                              :max-tokens 512)))
    (format t "~&~%=== ~a ===~%" label)
    (report label (loop*:run agent (list (user user-text))))
    agent))

(handler-case
    (progn
      (run-case "plain completion"
                "Answer in exactly one short sentence."
                "What is a Lisp image?")

      (setf *calls* '())
      (run-case "tool call"
                "You have a tool. Use it to answer. Do not guess."
                "What arguments does the Common Lisp function MAPCAR take?"
                :tools (list describe-symbol))
      (format t "~&  tool invoked with: ~a~%" (or *calls* "NOTHING -- tool calling did not fire"))

      ;; Determinism is the premise of every scored experiment, so check it here
      ;; rather than assuming a fixed seed is enough. The budget must clear the
      ;; model's reasoning or every reply is an empty :LENGTH stop.
      (let ((agent (make-instance 'loud-agent :model "gpt-oss-20b"
                                              :system-prompt "Reply with one word."
                                              :max-tokens 1024)))
        (format t "~&~%=== determinism: same seed, four calls ===~%")
        (let ((replies (loop repeat 4
                             collect (let ((m (client:complete agent (list (user "Name a colour.")))))
                                       (list (msg:text-of m)
                                             (msg:assistant-message-stop-reason m))))))
          (loop for (text reason) in replies for i from 1
                do (format t "  ~d. ~s (~a)~%" i text reason))
          (format t "  -> ~a~%"
                  (if (every (lambda (r) (equal r (first replies))) replies)
                      "IDENTICAL"
                      "DIVERGED -- slot cache state is an uncontrolled input")))))
  (error (condition)
    (format t "~&SMOKE FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
