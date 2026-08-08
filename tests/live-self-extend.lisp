;;;; End to end: an agent gives itself a capability it did not start with.
;;;;
;;;; The agent begins with the image tools and REGISTER_TOOL. It has no way to
;;;; compute a shipping cost. To finish the task it must write a function,
;;;; install it into the running image, register it -- at which point its schema
;;;; is read off the live function, with no schema authored -- and then call it.
;;;;
;;;; The pass condition is that the tool appears in a later request's tool list
;;;; and is actually invoked. No restart happens at any point.
;;;;
;;;;   llama-server -m <model>.gguf --jinja --port 8099 -c 16384 -ngl 99
;;;;   sbcl --non-interactive --load tests/live-self-extend.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium/image :silent t)

(defpackage #:vivarium.extend
  (:use #:cl)
  (:local-nicknames (#:msg #:vivarium.message)
                    (#:tool #:vivarium.tool)
                    (#:agent #:vivarium.agent)
                    (#:client #:vivarium.client)
                    (#:provider #:vivarium.provider)
                    (#:image #:vivarium.image)
                    (#:image-tools #:vivarium.image-tools)
                    (#:self #:vivarium.self)
                    (#:loop* #:vivarium.loop)))

(in-package #:vivarium.extend)

(defparameter *provider*
  (provider:llama-cpp-provider :endpoint "http://localhost:8099/v1/chat/completions"
                              :output-prefix provider:+harmony-output-prefix+))

(defpackage #:depot (:use #:cl))

(defparameter *expected* 19 "7 kg at 2 per kg, plus a flat 5.")

(defclass extending-agent (agent:queued-agent)
  ((iterations :initform 0 :accessor iterations)
   (tool-lists :initform '() :accessor tool-lists)
   (invoked :initform '() :accessor invoked)
   (limit :initarg :limit :initform 10 :reader limit)))

(defmethod client:complete :before ((agent extending-agent) messages)
  (declare (ignore messages))
  (push (mapcar #'tool:tool-name (agent:tools agent)) (tool-lists agent)))

(defmethod agent:emit ((agent extending-agent) event)
  (case (getf event :type)
    (:tool-start
     (let ((name (msg:tool-call-name (getf event :call))))
       (push name (invoked agent))
       (format t "~&  → ~a~%" name)))
    (:tool-end
     (let ((output (tool:tool-result-output (getf event :result))))
       (format t "~&  ← ~a~a~%"
               (substitute #\Space #\Newline (subseq output 0 (min 150 (length output))))
               (if (> (length output) 150) "..." ""))))))

(defmethod agent:should-stop-after-turn ((agent extending-agent) message results context)
  (declare (ignore message results context))
  (> (incf (iterations agent)) (limit agent)))

(defun user (text) (msg:make-user-message :content (list (msg:make-text text))))

(defparameter *task*
  "You have no tool that can price a shipment, and you must not do the arithmetic
yourself.

Give yourself one. In the DEPOT package, write and install a function
SHIPPING-COST that takes a weight in kilograms and returns that weight times 2,
plus a flat 5. Give it a docstring. Then use register_tool on it, which will read
its arguments straight off the function, and call the tool you just made with a
weight of 7.

Report the number the tool returned.")

(handler-case
    (let* ((backend (make-instance 'image:sbcl-image :package "DEPOT"))
           (image-tools:*backend* backend)
           (agent (make-instance 'extending-agent :provider *provider*
                                 :model "gpt-oss-20b"
                                 :system-prompt
                                 (format nil "~a~%~%You can also extend yourself: once you install a
function, register_tool turns it into a tool you can call on your next step."
                                         image-tools:*system-prompt*)
                                 :tools (append (image-tools:tool-set) (self:tool-set))
                                 :reasoning-effort "low"
                                 :max-tokens 4096)))
      (format t "~&=== start ===~%  tools: ~{~a~^, ~}~%"
              (mapcar #'tool:tool-name (agent:tools agent)))

      (format t "~&~%=== run ===~%")
      (let ((messages (self:with-self-extension (agent)
                        (loop*:run agent (list (user *task*))))))
        (let ((final (find-if #'msg:assistant-message-p (reverse messages))))
          (format t "~&~%  agent says: ~a~%"
                  (string-trim '(#\Newline #\Space) (msg:text-of final)))

          (let* ((lists (reverse (tool-lists agent)))
                 (invoked (reverse (invoked agent)))
                 (grew (find-if (lambda (names) (member "shipping_cost" names :test #'string=))
                                lists))
                 (called (member "shipping_cost" invoked :test #'string=))
                 (live (ignore-errors (funcall (find-symbol "SHIPPING-COST" '#:depot) 7))))
            (format t "~&~%=== what happened ===~%")
            (format t "  requests:        ~d~%" (length lists))
            (format t "  tools at start:  ~d~%" (length (first lists)))
            (format t "  tools at end:    ~d~%" (length (car (last lists))))
            (format t "  tools invoked:   ~{~a~^, ~}~%" invoked)
            (format t "  function in image: ~a~%" (or live "absent"))

            (format t "~&~%=== verdict ===~%")
            (cond ((and grew called (eql live *expected*))
                   (format t "  EXTENDED -- the agent wrote a tool, registered it mid-run, and used it~%")
                   (sb-ext:exit :code 0))
                  ((and grew (eql live *expected*))
                   (format t "  PARTIAL -- tool registered and correct, but never invoked~%")
                   (sb-ext:exit :code 1))
                  (t
                   (format t "  NOT EXTENDED -- registered: ~a, invoked: ~a, value: ~a (wanted ~d)~%"
                           (and grew t) (and called t) (or live "absent") *expected*)
                   (sb-ext:exit :code 1)))))))
  (error (condition)
    (format t "~&RUN FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))
