;;;; The organism's front door.
;;;;
;;;; These encode a bug that shipped and very nearly hid. `vivarium daemon
;;;; status` opened three connections for one answer, two of them dropped the
;;;; instant they were made, and four invocations killed the daemon outright.
;;;; The cause was one line: LOOP's iteration variable is a single binding
;;;; updated in place, so the closure handed to each client thread read whatever
;;;; the *next* accept had put there. Two threads then built streams from one
;;;; socket -- SBCL hands back the same stream -- and wrote interleaved JSON
;;;; onto one descriptor while the first to finish closed it under the other.
;;;;
;;;; That produced two symptoms which looked unrelated: a greeting the client
;;;; could not parse, and `Bad file descriptor`, which under `sbcl --script`
;;;; quits the whole process. A daemon whose entire premise is outliving its
;;;; clients was being killed by them.
;;;;
;;;; So these tests drive real sockets rather than mocks. The defect lived
;;;; precisely in the arrangement of threads and descriptors, and nothing that
;;;; stands in for those would have shown it.

(in-package #:vivarium.tests)

(defun daemon-test-path ()
  (format nil "/tmp/vivarium-daemond-~36r.sock" (random (expt 2 48) (make-random-state t))))

(defmacro with-daemon ((path) &body body)
  "A daemon of our own, on its own socket, stopped afterwards whatever happens."
  `(let ((,path (daemon-test-path)))
     (unwind-protect
          (progn (daemon:serve :path ,path :background t)
                 (loop repeat 100 until (daemon:running-p ,path) do (sleep 0.01))
                 ,@body)
       (daemon:stop))))

(defun daemon-greeting (path)
  "Connect, read the greeting, and return the pid in it -- or why there was none.

A symbol rather than a signalled error, so a thread can report what happened to
it instead of dying with the answer."
  (handler-case
      (let ((stream (daemon:connect path)))
        (unwind-protect
             (let ((line (read-line stream nil nil)))
               (cond ((null line) :no-greeting)
                     (t (handler-case (gethash "pid" (com.inuoe.jzon:parse line))
                          (error () :unparseable)))))
          (ignore-errors (close stream))))
    (error () :refused)))

(defun daemon-drop (path)
  "Connect and hang up at once: what a liveness probe does, and the exact
traffic that put two client threads on one descriptor."
  (handler-case (close (daemon:connect path)) (error () nil))
  t)

(defun daemon-ask (path &rest plist)
  (daemon:with-connection (stream path)
    (read-line stream nil nil)
    (apply #'daemon:request stream plist)))

(define-test "clients arriving and leaving at once each get their own connection"
  (with-daemon (path)
    (let ((greetings '())
          (lock (bt:make-lock "daemon-test")))
      (mapc #'bt:join-thread
            (loop for index below 24
                  collect (bt:make-thread
                           ;; INDEX is bound afresh here on purpose. Closing over
                           ;; the loop variable directly is the bug under test.
                           (let ((mine index))
                             (lambda ()
                               (if (oddp mine)
                                   (daemon-drop path)
                                   (let ((got (daemon-greeting path)))
                                     (bt:with-lock-held (lock) (push got greetings)))))))))
      (is = 12 (length greetings))
      (true (every #'integerp greetings)
            "every greeting parsed, got ~a" (remove-if #'integerp greetings))
      ;; And the listener is still there. Leaving the accept loop on one refused
      ;; connection unwinds into STOP, which leaves a process alive and
      ;; unreachable -- the worst of both.
      (true (integerp (daemon-greeting path))))))

(define-test "a client that hangs up mid-request does not take the daemon with it"
  (with-daemon (path)
    (dotimes (i 8)
      (handler-case
          (let ((stream (daemon:connect path)))
            (write-string "{\"id\":\"x\",\"type\":\"pi" stream)
            (force-output stream)
            (close stream))
        (error () nil)))
    (let ((reply (daemon-ask path "type" "ping")))
      (true (gethash "success" reply)))))

(define-test "unparseable input is answered rather than fatal"
  (with-daemon (path)
    (daemon:with-connection (stream path)
      (read-line stream nil nil)
      (write-line "not json at all" stream)
      (force-output stream)
      (let ((reply (com.inuoe.jzon:parse (read-line stream))))
        (false (gethash "success" reply))
        (true (gethash "error" reply))))
    (true (gethash "success" (daemon-ask path "type" "ping")))))

(define-test "a live daemon's socket survives being asked whether it is alive"
  (with-daemon (path)
    ;; RUNNING-P deleted the file whenever a connection failed for any reason,
    ;; on the theory that only a stale file can refuse. A busy one refuses too.
    (dotimes (i 20) (daemon:running-p path))
    (true (probe-file path))
    (true (daemon:running-p path))))

(define-test "stopping unlinks the socket it bound, not the default one"
  ;; STOP deleted (SOCKET-PATH) whatever it had actually been told to listen on,
  ;; so a daemon on a second socket deleted the first one's file on its way out
  ;; and left its own behind. VIVARIUM_SOCKET is what SOCKET-PATH reads, which
  ;; makes the wrong file nameable from here.
  (let ((decoy (daemon-test-path))
        (before (sb-posix:getenv "VIVARIUM_SOCKET")))
    (unwind-protect
         (progn
           (with-open-file (out decoy :direction :output :if-does-not-exist :create))
           (sb-posix:setenv "VIVARIUM_SOCKET" decoy 1)
           (with-daemon (path)
             (true (probe-file path))
             (daemon:stop)
             (false (probe-file path)))
           (true (probe-file decoy)))
      (if before
          (sb-posix:setenv "VIVARIUM_SOCKET" before 1)
          (sb-posix:unsetenv "VIVARIUM_SOCKET"))
      (ignore-errors (delete-file decoy)))))

;;; The control plane
;;;
;;; Steer, cancel and suspend all existed, were all delivered, and all of them
;;; meant `after the thing you wanted to interrupt has finished`: HARNESS:ASK
;;; ran on the session's own thread, so the mailbox could not be read again
;;; until the turn was over. The APIs were real and their semantics were not.
;;;
;;; So every test here sends its control message INTO a running turn and
;;; measures what the turn did afterwards. A test that checked only the state
;;; field would have passed against the broken version.

(defclass paced-agent (harness:workspace-agent)
  ((pause :initarg :pause :initform 0.05 :accessor paced-pause)
   (limit :initarg :limit :initform 6 :accessor paced-limit)
   (requests :initform 0 :accessor paced-requests)
   (saw-steer :initform '() :accessor paced-saw-steer)))

(defmethod client:complete ((agent paced-agent) messages)
  "One request, slow enough that a control message has somewhere to land."
  (sleep (paced-pause agent))
  (push (and (find-if (lambda (message)
                        (search "STEERED" (or (ignore-errors (msg:text-of message)) "")))
                      messages)
             t)
        (paced-saw-steer agent))
  (if (< (incf (paced-requests agent)) (paced-limit agent))
      (call-tool "ls")
      (say "done")))

(defun paced-cell (environment &key (pause 0.05) (limit 6))
  (actor:spawn :label "paced"
               :agent (make-instance 'paced-agent
                                     :environment environment
                                     :resource-environment environment
                                     :pause pause :limit limit
                                     :request-limit 500)))

(defun daemon-wait (predicate &key (timeout 15))
  (loop repeat (ceiling timeout 0.01)
        when (funcall predicate) return t
        do (sleep 0.01)))

(defun cell-event-names (cell)
  (mapcar #'event:event-name (actor:since cell 0)))

(defun terminal-count (names)
  "How many terminal turn events are in NAMES. The invariant is: one per turn."
  (count-if (lambda (name) (member name actor:+terminal-events+ :test #'string=)) names))

(defmacro with-paced-cell ((cell agent &rest options) &body body)
  `(with-repository (environment)
     (let* ((,cell (paced-cell environment ,@options))
            (,agent (actor:cell-agent ,cell)))
       (declare (ignorable ,agent))
       (unwind-protect (progn ,@body)
         (harness:cancel-agent ,agent)
         (actor:shutdown ,cell)))))

(define-test "the coordinator keeps receiving while a turn is running"
  (with-paced-cell (cell agent :pause 0.05 :limit 20)
    (actor:tell cell :user-message "go")
    (true (daemon-wait (lambda () (actor:busy-p cell))))
    ;; If the session's own thread were inside HARNESS:ASK, this message would
    ;; sit in the mailbox until the turn it was meant to interrupt had ended.
    (actor:tell cell :suspend)
    (true (daemon-wait (lambda () (eq :suspended (actor:cell-state cell)))))
    (true (actor:busy-p cell) "the turn ended instead of being held")
    (actor:tell cell :resume)
    (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 30))))

(define-test "suspend holds the work, not merely the state field"
  (with-paced-cell (cell agent :pause 0.02 :limit 500)
    (actor:tell cell :user-message "go")
    (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
    (actor:tell cell :suspend)
    (true (daemon-wait (lambda () (eq :suspended (actor:cell-state cell)))))
    (let ((at-suspend (paced-requests agent)))
      (sleep 0.5)
      ;; At most one more. SUSPEND can land mid-step and the step it lands in
      ;; finishes -- asserting an instantaneous freeze is a race, and one I
      ;; have already written once and had to unwrite.
      (true (<= (- (paced-requests agent) at-suspend) 1)
            "advanced ~d requests while suspended" (- (paced-requests agent) at-suspend))
      (actor:tell cell :resume)
      (true (daemon-wait (lambda () (> (paced-requests agent) (+ at-suspend 1))))
            "did not continue after resume"))))

(define-test "cancel stops the turn it was sent into"
  (with-paced-cell (cell agent :pause 0.02 :limit 500)
    (actor:tell cell :user-message "go")
    (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
    (actor:tell cell :cancel)
    (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 15)
          "the turn ran on after being cancelled")
    (true (< (paced-requests agent) 100) "made ~d requests" (paced-requests agent))
    (let ((names (cell-event-names cell)))
      (is = 1 (count "turn.cancelled" names :test #'string=))
      ;; And nothing else. A turn reporting cancelled AND completed leaves a
      ;; client no way to say what became of the work -- which is what this
      ;; test asserted as correct until the invariant was written down.
      (is = 1 (terminal-count names))
      (is = 0 (count "turn.completed" names :test #'string=)))))

(define-test "a steer reaches the turn it was sent into"
  (with-paced-cell (cell agent :pause 0.05 :limit 14)
    (actor:tell cell :user-message "go")
    (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
    (actor:tell cell :steer "STEERED")
    (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 30))
    (let ((seen (reverse (paced-saw-steer agent))))
      (true (find t seen) "no request in the turn ever saw the steer: ~a" seen)
      ;; And it was not merely the last thing to happen, which is exactly what
      ;; `steer the next turn` looked like from outside.
      (true (< (position t seen) (1- (length seen)))
            "the steer reached only the final request: ~a" seen))))

(define-test "a prompt arriving mid-turn waits rather than running beside it"
  (with-paced-cell (cell agent :pause 0.03 :limit 6)
    (actor:tell cell :user-message "first")
    (true (daemon-wait (lambda () (actor:busy-p cell))))
    (actor:tell cell :user-message "second")
    (true (daemon-wait (lambda () (= 1 (length (actor:cell-queued cell))))))
    (true (daemon-wait (lambda () (= 2 (count "turn.started" (cell-event-names cell)
                                              :test #'string=)))
                       :timeout 30)
          "the queued prompt never ran")
    (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 30))))

(defclass abortable-agent (paced-agent) ()
  (:documentation "A request that notices the abort while it is in flight.

Which is what the streaming client does: SHOULD-ABORT-P is checked between
streamed events, so a cancellation lands inside the request and comes back as
an :ABORTED stop reason. That path ends the run without ever reaching a
checkpoint."))

(defmethod client:complete ((agent abortable-agent) messages)
  (declare (ignore messages))
  (loop repeat 100 until (agent:should-abort-p agent) do (sleep 0.01))
  (cond ((agent:should-abort-p agent)
         (msg:make-assistant-message :content (list (msg:make-text "")) :stop-reason :aborted))
        ((< (incf (paced-requests agent)) (paced-limit agent)) (call-tool "ls"))
        (t (say "done"))))

(define-test "a cancellation that lands mid-request is still reported as one"
  ;; TURN.CANCELLED was emitted where the checkpoint's condition was caught, so
  ;; it fired only when the cancel happened to arrive between steps. Cancelling
  ;; during a request -- which is the usual case, because that is where the time
  ;; goes -- ended the run through the :ABORTED stop reason and reported a
  ;; perfectly ordinary completion. The event existed and never fired.
  (with-repository (environment)
    (let* ((cell (actor:spawn :label "abortable"
                              :agent (make-instance 'abortable-agent
                                                    :environment environment
                                                    :resource-environment environment
                                                    :limit 500 :request-limit 500)))
           (agent (actor:cell-agent cell)))
      (unwind-protect
           (progn
             (actor:tell cell :user-message "go")
             (true (daemon-wait (lambda () (actor:busy-p cell))))
             (actor:tell cell :cancel)
             (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 15))
             (let ((names (cell-event-names cell)))
               (is = 1 (count "turn.cancelled" names :test #'string=))
               (is = 1 (terminal-count names))))
        (harness:cancel-agent agent)
        (actor:shutdown cell)))))

;;; Lifecycle invariants, attacked
;;;
;;; Two claims the event stream makes, stated so they can be violated on
;;; purpose:
;;;
;;;   A TURN HAS EXACTLY ONE TERMINAL OUTCOME
;;;   SESSION.COMPLETED => NOTHING THE SESSION OWNS CAN STILL CHANGE THE WORLD
;;;
;;; The second matters more than it looks. Once a session's own work can
;;; install code, a lifecycle model that says `finished` while a worker is
;;; still unwinding is not imprecise, it is false.

(defclass exploding-agent (paced-agent) ())

(defmethod client:complete ((agent exploding-agent) messages)
  (declare (ignore messages))
  (sleep (paced-pause agent))
  (error "the provider fell over"))

(define-test "every ending of a turn produces exactly one terminal event"
  (dolist (case '(:completed :cancelled :failed))
    (with-repository (environment)
      (let* ((cell (actor:spawn
                    :label "terminal"
                    :agent (if (eq case :failed)
                               (make-instance 'exploding-agent
                                              :environment environment
                                              :resource-environment environment
                                              :pause 0.01 :request-limit 500)
                               (make-instance 'paced-agent
                                              :environment environment
                                              :resource-environment environment
                                              :pause 0.02
                                              :limit (if (eq case :cancelled) 500 3)
                                              :request-limit 500))))
             (agent (actor:cell-agent cell)))
        (unwind-protect
             (progn
               (actor:tell cell :user-message "go")
               (when (eq case :cancelled)
                 (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
                 (actor:tell cell :cancel))
               (true (daemon-wait (lambda () (plusp (terminal-count (cell-event-names cell))))
                                  :timeout 20)
                     "~a: no terminal event at all" case)
               (sleep 0.2)
               (let ((names (cell-event-names cell)))
                 (is = 1 (terminal-count names) "~a produced ~a" case
                     (remove-if-not (lambda (n) (member n actor:+terminal-events+ :test #'string=))
                                    names))
                 (is = 1 (count "turn.started" names :test #'string=))))
          (harness:cancel-agent agent)
          (actor:shutdown cell))))))

(define-test "session.completed is not published while the session is still working"
  (with-repository (environment)
    (let* ((cell (paced-cell environment :pause 0.02 :limit 500))
           (working-at-completion :never-published))
      ;; Subscribers run inside PUBLISH, so this samples the world at the exact
      ;; instant the claim is made rather than shortly afterwards.
      (actor:subscribe cell (gensym "WATCH")
                       (lambda (event)
                         (when (string= "session.completed" (event:event-name event))
                           (setf working-at-completion (actor:busy-p cell)))))
      (actor:tell cell :user-message "go")
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      ;; Shut down mid-turn: the case where the two could disagree.
      (actor:shutdown cell)
      (true (daemon-wait (lambda () (not (eq working-at-completion :never-published)))
                         :timeout 30)
            "session.completed was never published")
      (false working-at-completion
             "session.completed was published while a worker was still running"))))

(define-test "a session is findable until its work has stopped"
  (with-repository (environment)
    (let* ((cell (paced-cell environment :pause 0.02 :limit 500))
           (id (actor:cell-id cell)))
      (actor:tell cell :user-message "go")
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      (actor:shutdown cell)
      ;; Deregistering on the POST left a session unreachable and still
      ;; working, which is worse than either state on its own.
      (true (daemon-wait (lambda () (null (actor:find-cell id))) :timeout 30)
            "the session never deregistered")
      (false (actor:busy-p cell)
             "deregistered while its worker was still running"))))
