;;;; The view models, tested without a terminal.
;;;;
;;;; This is the reason WHAT to show is separated from WHERE to draw it. The
;;;; croatoan pane cannot be exercised here -- there is no tty -- but everything
;;;; that decides its contents is an ordinary function and is checked below.

(in-package #:viva.tests)

(defclass collecting () ((seen :initform '() :accessor seen)))
(defmethod cli:render ((r collecting) event) (push event (seen r)))

(define-test "a renderer implements only what it cares about"
  ;; The default method must swallow anything, or adding an event type breaks
  ;; every renderer that predates it.
  (let ((quiet (make-instance 'standard-object)))
    (is eq nil (cli:render quiet (list :type :tool-start)))
    (is eq nil (cli:render quiet (list :type :something-invented-later)))))

(define-test "broadcast reaches every renderer"
  (let ((a (make-instance 'collecting)) (b (make-instance 'collecting)))
    (cli:broadcast (list a b) (list :type :steer :text "stop"))
    (is = 1 (length (seen a)))
    (is = 1 (length (seen b)))))

(define-test "the trajectory shows assistant text and never the prompt going in"
  ;; INJECT emits :MESSAGE for messages travelling into the loop as well, and
  ;; echoing the operator's own prompt back at them is noise.
  (is eq nil (cli:trajectory-line
              (list :type :message
                    :message (msg:make-user-message
                              :content (list (msg:make-text "the prompt"))))))
  (is string= "the answer"
      (cli:trajectory-line
       (list :type :message
             :message (msg:make-assistant-message
                       :content (list (msg:make-text "the answer")) :stop-reason :stop)))))

(define-test "a failed tool call is marked differently from a successful one"
  (flet ((line (error-p)
           (cli:trajectory-line
            (list :type :tool-end
                  :result (tool:make-tool-result :output "out" :error-p error-p)))))
    (false (string= (line t) (line nil)))))

(define-test "the image pane is state, showing was and now per definition"
  (let ((backend (make-instance 'image:sbcl-image :package "VIVA.TESTS.RENDER")))
    (service:fresh-package "VIVA.TESTS.RENDER")
    (is equal '("nothing installed yet") (cli:ledger-lines backend))
    (image:install-definition backend "(defun f () 1)" :note "fixture")
    ;; Fixture installs are the task's own setup, not the agent's work.
    (is equal '("nothing installed yet") (cli:ledger-lines backend))
    (image:install-definition backend "(defun f () 2)" :note "the fix")
    (let ((lines (cli:ledger-lines backend)))
      (true (find-if (lambda (l) (search "was (defun f () 1)" l)) lines))
      (true (find-if (lambda (l) (search "now (defun f () 2)" l)) lines)))))

(define-test "the score pane distinguishes a crash from a zero"
  (is string= "not scored yet" (cli:score-line '()))
  (let ((line (cli:score-line '(("a" . 1.0) ("b" . 0.0) ("c" . nil)))))
    (true (search "a 1.00" line))
    (true (search "b 0.00" line))
    (true (search "c crash" line))))

(define-test "long output is clipped rather than allowed to wrap"
  (is string= "abc …" (cli:one-line "abcdefgh" 3))
  (is string= "one two" (cli:one-line (format nil "one~%two") 40)))