;;;; Streaming against a real server, including abort in flight.
;;;;
;;;;   llama-server -m <model>.gguf --jinja --port 8099 -c 8192 -ngl 99
;;;;   sbcl --non-interactive --load tests/live-stream.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium :silent t)

(defpackage #:vivarium.livestream
  (:use #:cl)
  (:local-nicknames (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client)
                    (#:provider #:vivarium.provider)))

(in-package #:vivarium.livestream)

(defparameter *provider*
  (provider:llama-cpp-provider :endpoint "http://localhost:8099/v1/chat/completions"
                              :output-prefix provider:+harmony-output-prefix+))

(defclass watched-agent (agent:queued-agent)
  ((deltas :initform 0 :accessor deltas)
   (first-token-at :initform nil :accessor first-token-at)
   (started-at :initform 0 :accessor started-at)))

(defmethod agent:emit ((agent watched-agent) event)
  (when (eq :delta (getf event :type))
    (incf (deltas agent))
    (unless (first-token-at agent)
      (setf (first-token-at agent)
            (/ (- (get-internal-real-time) (started-at agent))
               (/ internal-time-units-per-second 1000.0))))))

(defun user (text) (msg:make-user-message :content (list (msg:make-text text))))

(tool:define-tool weather (args context)
  :description "Current conditions for a city."
  :parameters (("city" :string "City name" :required-p t))
  (format nil "~a: 14C, raining" (gethash "city" args)))

(defun timed (agent thunk)
  (setf (started-at agent) (get-internal-real-time)
        (deltas agent) 0
        (first-token-at agent) nil)
  (let* ((message (funcall thunk))
         (total (/ (- (get-internal-real-time) (started-at agent))
                   (/ internal-time-units-per-second 1000.0))))
    (values message total)))

(handler-case
    (progn
      (format t "~&=== streamed completion ===~%")
      (let ((agent (make-instance 'watched-agent :provider *provider* :model "gpt-oss-20b" :stream t
                                                 :reasoning-effort "low"
                                                 :system-prompt "Answer in one sentence."
                                                 :max-tokens 1024)))
        (multiple-value-bind (message total)
            (timed agent (lambda () (client:complete agent (list (user "What is a Lisp image?")))))
          (format t "  deltas: ~d, first token ~,0fms, total ~,0fms~%"
                  (deltas agent) (first-token-at agent) total)
          (format t "  stop: ~a~%  text: ~a~%"
                  (msg:assistant-message-stop-reason message)
                  (subseq (msg:text-of message) 0 (min 120 (length (msg:text-of message)))))))

      (format t "~&~%=== streamed tool call (reassembled from fragments) ===~%")
      (let ((agent (make-instance 'watched-agent :provider *provider* :model "gpt-oss-20b" :stream t
                                                 :reasoning-effort "low"
                                                 :system-prompt "Use your tools."
                                                 :tools (list weather)
                                                 :max-tokens 1024)))
        (multiple-value-bind (message total)
            (timed agent (lambda () (client:complete agent (list (user "Weather in Lagos?")))))
          (declare (ignore total))
          (let ((calls (msg:tool-calls-in message)))
            (format t "  deltas: ~d, calls: ~d~%" (deltas agent) (length calls))
            (dolist (call calls)
              (format t "  ~a ~a~%" (msg:tool-call-name call)
                      (com.inuoe.jzon:stringify (msg:tool-call-arguments call)))))))

      (format t "~&~%=== abort in flight ===~%")
      (let ((agent (make-instance 'watched-agent :provider *provider* :model "gpt-oss-20b" :stream t
                                                 :abort-on-steer t
                                                 :reasoning-effort "low"
                                                 :system-prompt "Write at length."
                                                 :max-tokens 2048)))
        ;; Queue the steer before the request, so the very first abort check sees
        ;; it. In a run this comes from another thread mid-generation.
        (agent:queue-steering agent (user "stop"))
        (multiple-value-bind (message total)
            (timed agent (lambda ()
                           (client:complete agent (list (user "Explain Lisp macros in 500 words.")))))
          (format t "  stop: ~a after ~,0fms and ~d deltas~%"
                  (msg:assistant-message-stop-reason message) total (deltas agent))))

      (format t "~&~%=== the same request, not aborted, for comparison ===~%")
      (let ((agent (make-instance 'watched-agent :provider *provider* :model "gpt-oss-20b" :stream t
                                                 :reasoning-effort "low"
                                                 :system-prompt "Write at length."
                                                 :max-tokens 2048)))
        (multiple-value-bind (message total)
            (timed agent (lambda ()
                           (client:complete agent (list (user "Explain Lisp macros in 500 words.")))))
          (format t "  stop: ~a after ~,0fms and ~d deltas~%"
                  (msg:assistant-message-stop-reason message) total (deltas agent)))))
  (error (condition)
    (format t "~&FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
