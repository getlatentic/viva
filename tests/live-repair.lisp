;;;; End to end: an agent repairs a broken definition in a running image.
;;;;
;;;; The pass condition is behavioural. The agent's closing summary is ignored
;;;; entirely; what counts is whether calling the function in this process now
;;;; returns the right number. An agent that says it fixed something and did not
;;;; must fail here.
;;;;
;;;;   llama-server -m <model>.gguf --jinja --port 8099 -c 16384 -ngl 99
;;;;   sbcl --non-interactive --load tests/live-repair.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium/image :silent t)

(defpackage #:vivarium.repair
  (:use #:cl)
  (:local-nicknames (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client)
                    (#:provider #:vivarium.provider)
                    (#:image #:vivarium.image)
                    (#:image-tools #:vivarium.image-tools)
                    (#:loop* #:vivarium.loop)))

(in-package #:vivarium.repair)

(defparameter *provider*
  (provider:llama-cpp-provider :endpoint "http://localhost:8099/v1/chat/completions"
                              :output-prefix provider:+harmony-output-prefix+))

(defpackage #:shop (:use #:cl))

(defparameter *lines*
  '((:qty 2 :price 10) (:qty 1 :price 15) (:qty 3 :price nil))
  "The third line is comped: its price is NIL, which is what breaks the total.")

(defparameter *expected* 35)

(defparameter *broken*
  "(defun order-total (lines)
  (reduce #'+ (mapcar (lambda (line) (* (getf line :qty) (getf line :price))) lines)))")

;;; An agent that reports what it does and cannot run away

(defclass repair-agent (agent:queued-agent)
  ((iterations :initform 0 :accessor iterations)
   (limit :initarg :limit :initform 8 :reader limit)))

(defmethod agent:emit ((agent repair-agent) event)
  (case (getf event :type)
    (:tool-start
     (let ((arguments (msg:tool-call-arguments (getf event :call))))
       (format t "~&  → ~a ~a~%"
               (msg:tool-call-name (getf event :call))
               (string-trim '(#\Newline)
                            (subseq (com.inuoe.jzon:stringify arguments)
                                    0 (min 160 (length (com.inuoe.jzon:stringify arguments))))))))
    (:tool-end
     (let ((output (tool:tool-result-output (getf event :result))))
       (format t "~&  ← ~a~a~%"
               (substitute #\Space #\Newline (subseq output 0 (min 160 (length output))))
               (if (> (length output) 160) "..." ""))))))

(defmethod agent:should-stop-after-turn ((agent repair-agent) message results context)
  (declare (ignore message results context))
  (> (incf (iterations agent)) (limit agent)))

(defun user (text) (msg:make-user-message :content (list (msg:make-text text))))

;;; The run

(defun current-total ()
  "Call the definition in this process. NIL means it still signals."
  (ignore-errors (funcall (find-symbol "ORDER-TOTAL" '#:shop) *lines*)))

(defun task-text ()
  (format nil "The function ~a in the running image is broken.

Calling it on an order whose lines are ~s signals a TYPE-ERROR, because a comped
line carries a price of NIL and the function multiplies straight through it.

Fix it so a comped line contributes zero. The correct total for that order is ~d.

Read the current definition first, install a replacement, then confirm the total
is right." "DEFUN SHOP::ORDER-TOTAL" *lines* *expected*))

(defun setup ()
  (let ((backend (make-instance 'image:sbcl-image :package "SHOP")))
    (let ((result (image:install-definition backend *broken* :note "starting state")))
      (when (image:installation-error result)
        (format t "~&setup failed: ~a~%" (image:installation-error result))
        (sb-ext:exit :code 1)))
    backend))

(defun verify (label)
  (let ((total (current-total)))
    (format t "~&~a (order-total *lines*) => ~a~%" label (or total "still signals"))
    total))

(handler-case
    (let* ((backend (setup))
           (image-tools:*backend* backend)
           (agent (make-instance 'repair-agent :provider *provider*
                                 :model "gpt-oss-20b"
                                 :system-prompt image-tools:*system-prompt*
                                 :tools (image-tools:tool-set)
                                 :reasoning-effort "low"
                                 :max-tokens 4096)))
      (format t "~&=== before ===~%")
      (verify "  ")

      (format t "~&~%=== agent run ===~%")
      (let ((messages (loop*:run agent (list (user (task-text))))))
        (format t "~&~%  requests: ~d, messages: ~d~%" (iterations agent) (length messages))
        (let ((final (find-if #'msg:assistant-message-p (reverse messages))))
          (format t "  agent says: ~a~%"
                  (string-trim '(#\Newline #\Space) (msg:text-of final)))))

      (format t "~&~%=== after ===~%")
      (let ((total (verify "  ")))
        (format t "~&~%=== verdict ===~%")
        (cond ((eql total *expected*)
               (format t "  REPAIRED -- the image returns ~d~%" total)
               (sb-ext:exit :code 0))
              (t
               (format t "  NOT REPAIRED -- expected ~d, got ~a~%" *expected* (or total "an error"))
               (format t "  installed versions: ~{~a~^, ~}~%"
                       (mapcar #'vivarium.ledger:entry-note
                               (vivarium.ledger:entries (image:image-ledger backend))))
               (sb-ext:exit :code 1)))))
  (error (condition)
    (format t "~&RUN FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))
