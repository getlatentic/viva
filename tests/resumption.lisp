;;;; A turn the daemon died during carries on when the session comes back.
;;;;
;;;; Each test writes the transcript and the live marker a crash would leave
;;;; behind, brings the session back over them with a scripted agent, and reads
;;;; what happened: which calls ran again, what the transcript holds, which
;;;; events the restored stream carries, how many model requests were made.

(in-package #:viva.tests)

(defun turn-of (id n) (format nil "~a-t~d" id n))

(defun crashed-session (root build)
  "A transcript as a crash would leave it: BUILD writes it, given the session
and its id. Returns (values ID PATH)."
  (let* ((session (session:open-session :directory (session:session-directory root) :cwd root))
         (id (session:session-id session)))
    (funcall build session id)
    (session:close-session session)
    (values id (session:session-path session))))

(defun said (session text &key turn)
  (session:append-entry session :message
                        (msg:make-user-message :content (list (msg:make-text text)))
                        :turn turn))

(defun answered (session text &key turn calls)
  (session:append-entry session :message
                        (msg:make-assistant-message
                         :content (append (list (msg:make-text text)) calls)
                         :stop-reason (if calls :tool-calls :stop))
                        :turn turn))

(defun asked-call (id name &rest arguments)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on arguments by #'cddr do (setf (gethash key table) value))
    (msg:make-tool-call :id id :name name :arguments table)))

(defun crash-marker (root id &key running accepted (turns 1) requests)
  "The live marker a crash leaves: RUNNING and ACCEPTED as (TURN TEXT &key
REQUEST), REQUESTS as (REQUEST TURN) pairs. Read back through JSON, as a new
daemon reads it."
  (flet ((record (spec)
           (destructuring-bind (turn text &key request retain) spec
             (event::object "turn" turn "text" text "request" request "retain" retain))))
    (com.inuoe.jzon:parse
     (com.inuoe.jzon:stringify
      (event::object "id" id "cwd" root "label" "restored" "model" "none" "turns" turns
                     "running" (and running (record running))
                     "accepted" (coerce (mapcar #'record accepted) 'vector)
                     "requests" (coerce (mapcar (lambda (pair) (coerce pair 'vector)) requests)
                                        'vector))))))

(defun restored (environment path id marker &key (limit 1))
  "Bring the session at PATH back as a new daemon would, over a scripted agent
that answers `done` once it has made LIMIT requests."
  (let* ((agent (make-instance 'paced-agent :environment environment
                                            :resource-environment environment
                                            :pause 0.01 :limit limit :request-limit 50
                                            :session (session:reopen-session path))))
    (harness:resume agent path)
    (let ((cell (actor:spawn :label "restored" :agent agent :id id :restore marker)))
      (actor:resume-work cell)
      cell)))

(defun events-named (cell name)
  (remove-if-not (lambda (event) (equal name (event:event-name event))) (actor:since cell 0)))

(defun turn-ended-p (cell turn)
  (some (lambda (event)
          (and (member (event:event-name event) actor:+terminal-events+ :test #'string=)
               (equal turn (gethash "turn" (event:event-data event)))))
        (actor:since cell 0)))

(defun transcript-messages (path)
  (session:session-messages (session:load-session path)))

(defun user-texts (path)
  (loop for message in (transcript-messages path)
        when (msg:user-message-p message) collect (msg:text-of message)))

(defun result-for (path call-id)
  (find call-id (remove-if-not #'msg:tool-result-message-p (transcript-messages path))
        :key #'msg:tool-result-message-call-id :test #'equal))

(defmacro with-restored ((cell) form &body body)
  `(let ((,cell ,form))
     (unwind-protect (progn ,@body)
       (harness:cancel-agent (viva.actor::cell-agent ,cell))
       (actor:shutdown ,cell))))

(define-test "a turn cut off waiting for the model carries on when the session comes back"
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id)
                                  (said session "hello" :turn (turn-of id 1))))
        (let ((turn (turn-of id 1)))
          (with-restored (cell) (restored environment path id
                                          (crash-marker root id :running (list turn "hello" :request "r-1")
                                                                :requests (list (list "r-1" turn))))
            (true (daemon-wait (lambda () (turn-ended-p cell turn)) :timeout 30)
                  "the turn did not carry on")
            (let ((started (first (events-named cell "turn.started"))))
              (is equal turn (gethash "turn" (event:event-data started)) "it came back as another turn")
              (true (gethash "resumed" (event:event-data started)) "it was not marked resumed"))
            (is equal "done" (gethash "text" (event:event-data (first (events-named cell "turn.completed")))))
            ;; The prompt was already in the conversation: shown once, written once.
            (is = 0 (length (events-named cell "user.message")) "the prompt was announced again")
            (is equal '("hello") (user-texts path) "the prompt was written into the conversation twice")
            (false (gethash "running" (com.inuoe.jzon:parse (uiop:read-file-string (viva.actor::live-path id))))
                   "the marker still says the turn is running")
            ;; And the request it arrived with is still recognised.
            (multiple-value-bind (again duplicate) (actor:submit cell "hello" :request "r-1")
              (is equal turn again)
              (true duplicate))))))))

(define-test "a cut-off call runs again only when the record and the tool both say it is harmless"
  ;; Pi Durable's rule. ls is harmless and was recorded so: it runs again.
  ;; bash was recorded unsafe; the second ls was recorded unsafe by an older
  ;; build; grep has no record at all, so nothing says it is harmless. None of
  ;; those three runs again, and each is answered so the model can decide.
  (with-repository (environment)
    (let* ((root (env:env-cwd environment))
           (touched (format nil "~a/ran-again" root)))
      (multiple-value-bind (id path)
          (crashed-session
           root (lambda (session id)
                  (let ((turn (turn-of id 1)))
                    (said session "go" :turn turn)
                    (answered session "looking" :turn turn
                              :calls (list (asked-call "c1" "ls" "path" ".")
                                           (asked-call "c2" "bash" "command" (format nil "touch ~a" touched))
                                           (asked-call "c3" "ls" "path" ".")
                                           (asked-call "c4" "grep" "pattern" "x" "path" ".")))
                    (session:append-record session :intent "call" "c1" "tool" "ls" "replay" "safe")
                    (session:append-record session :intent "call" "c2" "tool" "bash" "replay" "unsafe")
                    (session:append-record session :intent "call" "c3" "tool" "ls" "replay" "unsafe"))))
        (let ((turn (turn-of id 1)))
          (with-restored (cell) (restored environment path id (crash-marker root id :running (list turn "go")))
            (true (daemon-wait (lambda () (turn-ended-p cell turn)) :timeout 30))
            (flet ((output (call) (msg:tool-result-message-output (result-for path call))))
              (true (result-for path "c1") "the harmless call has no result")
              (false (search "Interrupted" (output "c1")) "the harmless call did not run again")
              (dolist (call '("c2" "c3" "c4"))
                (true (search "Interrupted" (output call))
                      "~a ran again, or was left without an answer" call)))
            (false (probe-file touched) "the unsafe command ran a second time")
            (is = 1 (paced-requests (viva.actor::cell-agent cell))
                "the model was not asked again once the calls were settled")))))))

(define-test "a turn whose prompt never reached the conversation runs from its prompt"
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id)
                                  (said session "earlier" :turn (turn-of id 1))
                                  (answered session "ok" :turn (turn-of id 1))))
        (let ((turn (turn-of id 2)))
          (with-restored (cell) (restored environment path id
                                          (crash-marker root id :running (list turn "fresh") :turns 2))
            (true (daemon-wait (lambda () (turn-ended-p cell turn)) :timeout 30))
            (is equal '("earlier" "fresh") (user-texts path))
            (is = 1 (length (events-named cell "user.message"))
                "a prompt new to the conversation was not shown")))))))

(define-test "a turn that had answered and not ended is not asked again"
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id)
                                  (said session "question" :turn (turn-of id 1))
                                  (answered session "the answer" :turn (turn-of id 1))))
        (let ((turn (turn-of id 1)))
          (with-restored (cell) (restored environment path id (crash-marker root id :running (list turn "question")))
            (true (daemon-wait (lambda () (turn-ended-p cell turn)) :timeout 30))
            (is = 0 (paced-requests (viva.actor::cell-agent cell)) "the model was asked again")
            (is equal "the answer"
                (gethash "text" (event:event-data (first (events-named cell "turn.completed")))))))))))

(define-test "with no turn to carry on, an unanswered call is answered as interrupted"
  ;; No provider accepts a conversation ending in a call with no result, so a
  ;; session restored that way could never be asked anything again.
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id)
                                  (declare (ignore id))
                                  (said session "go")
                                  (answered session "running it" :calls (list (asked-call "c9" "ls" "path" ".")))))
        (with-restored (cell) (restored environment path id (crash-marker root id))
          (true (result-for path "c9") "the call was left without a result")
          (true (search "Interrupted" (msg:tool-result-message-output (result-for path "c9"))))
          (is = 0 (paced-requests (viva.actor::cell-agent cell)) "a model request was made unasked"))))))

(define-test "prompts accepted behind the turn run after it, in order, under their own ids"
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id) (said session "first" :turn (turn-of id 1))))
        (let ((first (turn-of id 1)) (second (turn-of id 2)) (third (turn-of id 3)))
          (with-restored (cell) (restored environment path id
                                          (crash-marker root id :running (list first "first")
                                                                :accepted (list (list second "second")
                                                                                (list third "third" :request "r-3"))
                                                                :turns 3
                                                                :requests (list (list "r-3" third))))
            (true (daemon-wait (lambda () (turn-ended-p cell third)) :timeout 30))
            (is equal (list first second third)
                (mapcar (lambda (event) (gethash "turn" (event:event-data event)))
                        (events-named cell "turn.completed")))
            (is equal '("first" "second" "third") (user-texts path))
            ;; The counter came back too: a new turn does not reuse an old id.
            (is equal (turn-of id 4) (actor:submit cell "fourth"))))))))

(define-test "a prompt is written down before it is answered, and a retry gets the same turn"
  (with-paced-cell (cell agent :pause 0.05 :limit 3)
    (multiple-value-bind (turn duplicate) (actor:submit cell "once" :request "only-once")
      (false duplicate)
      ;; Before anything else: the marker already holds it, running or waiting.
      (let ((marker (com.inuoe.jzon:parse (uiop:read-file-string (viva.actor::live-path (actor:cell-id cell))))))
        (true (find "only-once" (coerce (gethash "requests" marker) 'list)
                    :key (lambda (pair) (aref pair 0)) :test #'equal)
              "the request id was not written down before the answer"))
      (multiple-value-bind (again repeated) (actor:submit cell "once" :request "only-once")
        (is equal turn again)
        (true repeated))
      (true (daemon-wait (lambda () (turn-ended-p cell turn)) :timeout 30))
      (sleep 0.3)
      (is = 1 (count-if (lambda (event)
                          (and (equal "turn.started" (event:event-name event))
                               (equal turn (gethash "turn" (event:event-data event)))))
                        (actor:since cell 0))
          "a retried prompt ran twice"))))

(define-test "a turn's entries carry its id, on disk and back"
  (with-repository (environment)
    (let ((root (env:env-cwd environment)))
      (multiple-value-bind (id path)
          (crashed-session root (lambda (session id)
                                  (said session "tagged" :turn (turn-of id 7))
                                  (said session "untagged")))
        (declare (ignore id))
        (is equal '("s" nil)
            (mapcar (lambda (entry) (and (session:entry-turn entry) "s"))
                    (remove-if #'session:record-p
                               (session:entries-of (session:load-session path)))))))))

(define-test "a tool.json says whether its tool may run twice"
  (multiple-value-bind (entry reason)
      (viva.registry::parse-manifest
       "{\"name\":\"lookup\",\"description\":\"d\",\"exec\":[\"./run\"],\"replay\":\"safe\"}" "/tmp")
    (false reason)
    (is eq :safe (tool:tool-replay (viva.registry::entry-tool entry (lambda () "/tmp")))))
  (multiple-value-bind (entry reason)
      (viva.registry::parse-manifest
       "{\"name\":\"deploy\",\"description\":\"d\",\"exec\":[\"./run\"]}" "/tmp")
    (false reason)
    (is eq :unsafe (tool:tool-replay (viva.registry::entry-tool entry (lambda () "/tmp"))))
    "a tool that says nothing must not be run twice")
  (multiple-value-bind (entry reason)
      (viva.registry::parse-manifest
       "{\"name\":\"odd\",\"description\":\"d\",\"exec\":[\"./run\"],\"replay\":\"always\"}" "/tmp")
    (false entry)
    (true (search "replay" reason))))
