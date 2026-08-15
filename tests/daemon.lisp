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
    (actor:submit cell "go")
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
    (actor:submit cell "go")
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
    (actor:submit cell "go")
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
    (actor:submit cell "go")
    (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
    (actor:tell cell :steer :text "STEERED")
    (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 30))
    (let ((seen (reverse (paced-saw-steer agent))))
      (true (find t seen) "no request in the turn ever saw the steer: ~a" seen)
      ;; And it was not merely the last thing to happen, which is exactly what
      ;; `steer the next turn` looked like from outside.
      (true (< (position t seen) (1- (length seen)))
            "the steer reached only the final request: ~a" seen))))

(define-test "a prompt arriving mid-turn waits rather than running beside it"
  (with-paced-cell (cell agent :pause 0.03 :limit 6)
    (actor:submit cell "first")
    (true (daemon-wait (lambda () (actor:busy-p cell))))
    (actor:submit cell "second")
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
             (actor:submit cell "go")
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
               (actor:submit cell "go")
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
      (actor:submit cell "go")
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
      (actor:submit cell "go")
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      (actor:shutdown cell)
      ;; Deregistering on the POST left a session unreachable and still
      ;; working, which is worse than either state on its own.
      (true (daemon-wait (lambda () (null (actor:find-cell id))) :timeout 30)
            "the session never deregistered")
      (false (actor:busy-p cell)
             "deregistered while its worker was still running"))))

;;; Identity, ownership, linearization
;;;
;;; These close races that only exist because the architecture is genuinely
;;; concurrent, and each one gets much harder to reason about once a task can
;;; spawn other tasks. The shared cause is identity being underspecified: an
;;; asynchronous message that does not say what it is about gets applied to
;;; whatever happens to be current when it lands.

(define-test "a completion for a turn that has ended cannot end the turn running now"
  ;; BUSY-P used to ask THREAD-ALIVE-P. A worker that had posted its completion
  ;; and exited left `not busy`, a new prompt could start turn 2, and turn 1's
  ;; completion -- still sitting in the mailbox -- then cleared turn 2's
  ;; identity and published a terminal event for work that was still running.
  (with-paced-cell (cell agent :pause 0.05 :limit 12)
    (let ((turn (actor:submit cell "go")))
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      (actor:tell cell :finished :turn "s0-t999" :outcome :completed)
      (sleep 0.2)
      (true (actor:busy-p cell) "a stale completion ended the running turn")
      (is equal turn (actor:cell-turn cell))
      (is = 0 (terminal-count (cell-event-names cell)))
      ;; Ignored, but not silently: an unexplained message is a symptom.
      (is = 1 (count "session.error" (cell-event-names cell) :test #'string=))
      (actor:tell cell :cancel)
      (true (daemon-wait (lambda () (not (actor:busy-p cell))) :timeout 15)))))

(define-test "control aimed at a finished turn does not hit its successor"
  (with-paced-cell (cell agent :pause 0.02 :limit 4)
    (let ((first (actor:submit cell "one")))
      (is string= "turn.completed" (actor:await-turn cell first :timeout 20))
      ;; FIRST is over. This cancel names it, and must not touch what follows.
      (actor:tell cell :cancel :turn first)
      (let ((second (actor:submit cell "two")))
        (is string= "turn.completed" (actor:await-turn cell second :timeout 20)
            "a cancel for the previous turn cancelled this one")))))

(define-test "waiting for a turn waits for that turn, not the next one to end"
  ;; AWAIT used to wake on any turn.completed, so a caller whose prompt was
  ;; queued behind running work returned before its own turn had begun.
  (with-paced-cell (cell agent :pause 0.03 :limit 4)
    (actor:submit cell "first")
    (true (daemon-wait (lambda () (actor:busy-p cell))))
    (let* ((second (actor:submit cell "second"))
           (outcome (actor:await-turn cell second :timeout 30))
           (names (cell-event-names cell)))
      (is string= "turn.completed" outcome)
      ;; Both turns are over, which they would not be if this had returned on
      ;; the first turn's completion.
      (is = 2 (terminal-count names))
      (is = 2 (count "turn.started" names :test #'string=)))))

(define-test "shutting down mid-turn reports that turn before completing the session"
  ;; :SHUTDOWN used to leave the mailbox loop at once, so the worker's
  ;; completion arrived at nobody: session.completed was published with the
  ;; last turn having no terminal event at all.
  (with-repository (environment)
    (let ((cell (paced-cell environment :pause 0.02 :limit 500)))
      (actor:submit cell "go")
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      (true (actor:await-shutdown cell :timeout 30) "the session never ended")
      (let ((names (cell-event-names cell)))
        (is = 1 (terminal-count names) "the last turn reported ~a terminal events"
            (terminal-count names))
        (is = 1 (count "session.completed" names :test #'string=))
        ;; Order matters as much as presence: completed must come last.
        (true (< (position-if (lambda (n) (member n actor:+terminal-events+ :test #'string=))
                              names)
                 (position "session.completed" names :test #'string=))
              "session.completed preceded its own turn's outcome")))))

(define-test "attaching loses no event and repeats none"
  ;; Replay-then-subscribe drops whatever is published in between;
  ;; subscribe-then-replay delivers it twice.
  (with-repository (environment)
    (let* ((cell (paced-cell environment :pause 0.01 :limit 1))
           (seen '())
           (lock (bt:make-lock "attach-test"))
           ;; Paced on purpose. Publishing 300 events as fast as possible
           ;; finished before the subscription was attempted, so the gap this
           ;; test exists for was never open and the test passed against the
           ;; implementation it was written to catch.
           (publisher (bt:make-thread
                       (lambda ()
                         (dotimes (i 300)
                           (vivarium.actor::publish cell "model.delta" nil)
                           (sleep 0.001))))))
      (unwind-protect
           (progn
             (sleep 0.05)
             (actor:subscribe-since cell (gensym "A") 0
                                    (lambda (event)
                                      ;; Slow on purpose. A real subscriber
                                      ;; writes each event to a socket, so
                                      ;; catching up takes time -- and the gap
                                      ;; between replaying and subscribing is
                                      ;; only as wide as the replay is slow.
                                      ;; With an instant handler the window was
                                      ;; sub-millisecond and the test could not
                                      ;; see the bug it was written for.
                                      (sleep 0.0005)
                                      (bt:with-lock-held (lock)
                                        (push (event:event-sequence event) seen))))
             (bt:join-thread publisher)
             (sleep 0.3)
             (let* ((numbers (sort (copy-list seen) #'<))
                    (highest (reduce #'max numbers :initial-value 0)))
               (is = highest (length numbers) "~d events for ~d sequences: ~a"
                   (length numbers) highest
                   (if (> (length numbers) highest) "duplicated" "dropped"))
               (is = (length numbers) (length (remove-duplicates numbers)))))
        (actor:shutdown cell)))))

(define-test "one process serves once"
  ;; The OS lock is owned by the process, so it says nothing about this process
  ;; asking twice, and a second SERVE would overwrite the listener it replaced.
  (with-daemon (path)
    (true (daemon:running-p path))
    (fail (daemon:serve :path (daemon-test-path) :background t) 'daemon:daemon-error)))

;;; Recovery
;;;
;;; The boundary says what can coherently be done; policy says what to do. Two
;;; real cases rather than a hierarchy: a provider that failed is retried, and
;;; a tool that signalled can be retried by a policy that knows better, with
;;; the failure-as-result that was always the behaviour kept as the default.

(defclass flaky-agent (paced-agent)
  ((failures :initarg :failures :initform 2 :accessor flaky-failures)
   (calls :initform 0 :accessor flaky-calls)))

(defmethod client:complete ((agent flaky-agent) messages)
  (declare (ignore messages))
  (if (<= (incf (flaky-calls agent)) (flaky-failures agent))
      (error "connection reset by peer")
      (say "recovered")))

(define-test "a provider that fails transiently does not lose the turn"
  (with-repository (environment)
    (let* ((cell (actor:spawn :label "flaky"
                              :agent (make-instance 'flaky-agent
                                                    :environment environment
                                                    :resource-environment environment
                                                    :failures 2 :request-limit 500)))
           (agent (actor:cell-agent cell)))
      (unwind-protect
           (let ((turn (actor:submit cell "go")))
             ;; The conversation was intact the whole time. Ending the run
             ;; because a socket closed threw away work that was fine.
             (is string= "turn.completed" (actor:await-turn cell turn :timeout 30))
             (is = 3 (flaky-calls agent) "took ~d requests" (flaky-calls agent)))
        (actor:shutdown cell)))))

(define-test "a provider that never works fails the turn instead of retrying forever"
  ;; Falling back whenever the count is high enough looks the same as falling
  ;; back once and is not: switching models makes the previous one the
  ;; fallback, so two dead providers hand the run back and forth without end.
  (with-repository (environment)
    (let* ((cell (actor:spawn :label "dead"
                              :agent (make-instance 'flaky-agent
                                                    :environment environment
                                                    :resource-environment environment
                                                    :failures 1000 :request-limit 500)))
           (agent (actor:cell-agent cell)))
      (unwind-protect
           (let ((turn (actor:submit cell "go")))
             (is string= "turn.failed" (actor:await-turn cell turn :timeout 60))
             (true (< (flaky-calls agent) 10)
                   "made ~d attempts before giving up" (flaky-calls agent)))
        (actor:shutdown cell)))))

(defclass retrying-tools-agent (harness:workspace-agent)
  ((script :initarg :script :accessor rt-script)
   (retried :initform 0 :accessor rt-retried)))

(defmethod client:complete ((agent retrying-tools-agent) messages)
  (declare (ignore messages))
  (or (pop (rt-script agent)) (say "done")))

(defmethod agent:recover ((agent retrying-tools-agent) (condition fault:tool-unusable))
  "A policy that knows this failure is worth one more go."
  (when (zerop (rt-retried agent))
    (incf (rt-retried agent))
    (fault:retry condition)))

(define-test "a policy can retry a tool the harness would have given up on"
  ;; The default -- the failure becomes the tool's result -- was the only
  ;; possibility, decided inside TOOL:EXECUTE where nothing is known about
  ;; whether trying again is worth it.
  (with-repository (environment)
    (let ((agent (make-instance 'retrying-tools-agent
                                :environment environment
                                :resource-environment environment
                                :extra-tools (list exploding-tool)
                                :script (list (call-tool "exploding_tool")))))
      (harness:ask agent "go")
      (is = 1 (rt-retried agent) "the tool boundary offered no retry"))))

(define-test "with no policy, a tool that signals still becomes its own result"
  (with-repository (environment)
    (let ((agent (make-instance 'replaying-agent
                                :environment environment
                                :resource-environment environment
                                :extra-tools (list exploding-tool)
                                :script (list (call-tool "exploding_tool")))))
      (multiple-value-bind (reply messages) (harness:ask agent "go")
        (declare (ignore reply))
        (let ((result (find-if #'msg:tool-result-message-p messages)))
          (true result "no tool result reached the conversation")
          (true (msg:tool-result-message-error-p result))
          (true (mentions "boom" (msg:tool-result-message-output result))))))))

(defclass stalling-agent (paced-agent)
  ((stalls :initarg :stalls :initform 1 :accessor stalling-stalls)
   (calls :initform 0 :accessor stalling-calls)))

(defmethod client:complete ((agent stalling-agent) messages)
  (declare (ignore messages))
  (if (<= (incf (stalling-calls agent)) (stalling-stalls agent))
      (progn (sleep 30) (say "far too late"))
      (say "answered")))

(define-test "a request that stalls is bounded and recovered, not waited on forever"
  ;; The HTTP client's read timeout bounds each individual read, which a
  ;; connection trickling a byte every few minutes never trips. A deadline
  ;; bounds the exchange, and a deadline that fires is just another
  ;; unreachable provider as far as policy is concerned.
  ;; SETF, not LET. The turn runs on a worker thread, and SBCL threads do not
  ;; inherit dynamic bindings -- a LET here is invisible inside the worker,
  ;; which read the global 900 and stalled for the full thirty seconds. Law 9,
  ;; demonstrated by breaking it. Anything genuinely task-local must be
  ;; captured and rebound in the worker; a global backstop is set globally.
  (let ((previous loop*:*request-deadline*))
    (unwind-protect
         (progn
           (setf loop*:*request-deadline* 0.4)
           (with-repository (environment)
             (let* ((cell (actor:spawn :label "stalling"
                                       :agent (make-instance 'stalling-agent
                                                             :environment environment
                                                             :resource-environment environment
                                                             :stalls 1 :request-limit 500)))
                    (agent (actor:cell-agent cell)))
               (unwind-protect
                    (let ((turn (actor:submit cell "go")))
                      (is string= "turn.completed" (actor:await-turn cell turn :timeout 25))
                      (is = 2 (stalling-calls agent)
                          "took ~d requests" (stalling-calls agent)))
                 (actor:shutdown cell)))))
      (setf loop*:*request-deadline* previous))))

;;; Isolation of frontend I/O, absolute deadlines, and startup ownership

(define-test "a client that stops reading does not stall whoever is publishing"
  ;; SAY used to write and FORCE-OUTPUT on the calling thread -- a session's own
  ;; worker, publishing model deltas. A peer that stopped reading filled the
  ;; socket buffer and stopped the turn. Frontend I/O must never take part in
  ;; execution latency.
  (with-daemon (path)
    (with-repository (environment)
      (let ((cell (paced-cell environment :pause 0.01 :limit 1))
            (deaf nil))
        (unwind-protect
             (progn
               (setf deaf (daemon:connect path))
               (read-line deaf nil nil)
               ;; Attach, then never read another byte.
               (daemon:request deaf "type" "session.attach" "session" (actor:cell-id cell))
               (let ((start (get-internal-real-time))
                     (payload (make-string 4000 :initial-element #\x)))
                 ;; Far more than any socket buffer will hold.
                 (dotimes (i 400)
                   (vivarium.actor::publish cell "model.delta"
                                            (vivarium.event::object "text" payload)))
                 (let ((seconds (/ (- (get-internal-real-time) start)
                                   internal-time-units-per-second)))
                   (true (< seconds 10) "publishing took ~,1fs behind a deaf client" seconds)
                   (is = 400 (count "model.delta" (cell-event-names cell) :test #'string=)))))
          (ignore-errors (close deaf))
          (actor:shutdown cell))))))

(defclass wedged-agent (harness:workspace-agent) ())

(defmethod client:complete ((agent wedged-agent) messages)
  (declare (ignore messages))
  ;; Ignores cancellation entirely: the worker that will not come back.
  (sleep 60)
  (say "much too late"))

(define-test "a stopping session gives up on time however busy its mailbox is"
  ;; The grace period was passed to each RECEIVE-MESSAGE, so every arriving
  ;; message bought another full period. Any traffic at all -- and with child
  ;; tasks there will be plenty -- held a broken worker in :STOPPING forever.
  (let ((previous vivarium.actor::+stopping-grace+))
    (unwind-protect
         (progn
           (setf vivarium.actor::+stopping-grace+ 2)
           (with-repository (environment)
             (let ((cell (actor:spawn :label "wedged"
                                      :agent (make-instance 'wedged-agent
                                                            :environment environment
                                                            :resource-environment environment
                                                            :request-limit 500))))
               (actor:submit cell "go")
               (true (daemon-wait (lambda () (actor:busy-p cell))))
               (actor:shutdown cell)
               ;; Traffic throughout the whole grace period.
               (let ((chatter (bt:make-thread
                               (lambda () (dotimes (i 30)
                                            (actor:tell cell :resume)
                                            (sleep 0.2))))))
                 (true (daemon-wait (lambda () (eq :stuck (actor:cell-state cell))) :timeout 8)
                       "still ~a after the grace period" (actor:cell-state cell))
                 (ignore-errors (bt:join-thread chatter :timeout 10)))
               ;; And it did not claim to have completed.
               (let ((names (cell-event-names cell)))
                 (is = 0 (count "session.completed" names :test #'string=))
                 (true (member "session.error" names :test #'string=))))))
      (setf vivarium.actor::+stopping-grace+ previous))))

(define-test "two threads in one process cannot both start serving"
  ;; The OS lock is held by the process and grants itself the same lock twice,
  ;; so it cannot see this race at all. Reading *SOCKET* and then acquiring is
  ;; the check-then-act it was meant to remove, one level down.
  (let ((first (daemon-test-path))
        (second (daemon-test-path)))
    (unwind-protect
         (let ((outcomes
                 (mapcar #'bt:join-thread
                         (mapcar (lambda (path)
                                   (let ((mine path))
                                     (bt:make-thread
                                      (lambda ()
                                        (handler-case
                                            (progn (daemon:serve :path mine :background t) :served)
                                          (error () :refused))))))
                                 (list first second)))))
           (is = 1 (count :served outcomes) "outcomes were ~a" outcomes))
      (daemon:stop)
      (ignore-errors (delete-file first))
      (ignore-errors (delete-file second)))))

(defclass falling-back-agent (harness:workspace-agent)
  ((calls :initform 0 :accessor fb-calls)))

(defmethod client:complete ((agent falling-back-agent) messages)
  (declare (ignore messages))
  (incf (fb-calls agent))
  (if (equal "fast" (agent:agent-model agent))
      (say "answered by the fallback")
      (progn (sleep 30) (say "never"))))

(defmethod agent:recover ((agent falling-back-agent) (condition fault:model-unavailable))
  (fault:use-model "fast" condition))

(define-test "the model chosen after a deadline runs under a fresh one"
  ;; If WITH-DEADLINE sat outside the RESTART-CASE, the fallback would inherit
  ;; the deadline that had just expired and die instantly -- a recovery that
  ;; exists and can never succeed.
  (let ((previous loop*:*request-deadline*))
    (unwind-protect
         (progn
           (setf loop*:*request-deadline* 0.4)
           (with-repository (environment)
             (let* ((cell (actor:spawn :label "fallback"
                                       :agent (make-instance 'falling-back-agent
                                                             :environment environment
                                                             :resource-environment environment
                                                             :request-limit 500)))
                    (agent (actor:cell-agent cell)))
               (unwind-protect
                    (let ((turn (actor:submit cell "go")))
                      (is string= "turn.completed" (actor:await-turn cell turn :timeout 25))
                      (is = 2 (fb-calls agent) "took ~d requests" (fb-calls agent))
                      (is string= "fast" (agent:agent-model agent)))
                 (actor:shutdown cell)))))
      (setf loop*:*request-deadline* previous))))

(define-test "a stopped daemon's accept loop does not tear down its successor"
  ;; The accept loop unwinds into a teardown that cleared *SOCKET*,
  ;; *SOCKET-FILE* and the instance lock unconditionally. By the time a stopped
  ;; daemon's loop noticed, those globals could already describe the NEXT
  ;; daemon -- so it closed that one's socket and deleted its file. It showed up
  ;; as a daemon that had just reported itself listening being found not to be,
  ;; in about one suite run in ten.
  (let ((paths '()))
    (unwind-protect
         (dotimes (i 60)
           (let ((old (daemon-test-path))
                 (new (daemon-test-path)))
             (push old paths)
             (push new paths)
             (daemon:serve :path old :background t)
             (loop repeat 200 until (daemon:running-p old) do (sleep 0.005))
             (daemon:stop)
             ;; Started while the previous accept loop is unwinding.
             (daemon:serve :path new :background t)
             (loop repeat 200 until (daemon:running-p new) do (sleep 0.005))
             (sleep 0.05)
             (true (daemon:running-p new) "cycle ~d: the successor was stopped" i)
             (true (probe-file new) "cycle ~d: the successor's socket was deleted" i)
             (daemon:stop)))
      (daemon:stop)
      (dolist (path paths) (ignore-errors (delete-file path))))))

(define-test "retiring a listener that is no longer current does nothing"
  ;; The deterministic half of the test above. The race is what made the bug
  ;; rare; this is the guard that makes it impossible, checked directly.
  (with-daemon (path)
    (let ((stranger (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (vivarium.daemon::retire stranger)
      (true (daemon:running-p path) "retiring a stranger's socket stopped the daemon")
      (true (probe-file path) "retiring a stranger's socket deleted the daemon's file")
      (true (gethash "success" (daemon-ask path "type" "ping"))))))
