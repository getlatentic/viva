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

;; Before any cell spawns: the journal must never write into the real home.
;; Test runs left 462 files and 26MB in ~/.vivarium/journal before this.
(setf actor:*journal-root*
      (format nil "/tmp/vivarium-test-journal-~36r/"
              (random (expt 2 40) (make-random-state t))))

(defvar *suite-watchdog* nil)
(defvar *suite-beat* 0)

(defun ensure-suite-watchdog ()
  "One full-suite deadlock has been OBSERVED -- nine threads on one mutex,
holder unidentified, never reproduced across an instrumented 8-round hunt. If
it ever recurs, this produces the diagnosis: on a stall far past any honest
suite duration, every thread prints its Lisp backtrace and the run exits 99.

Armed by the FIRST daemon test rather than at suite startup: the daemon tests
are where the hang lived, they run after every fork-based trial test, and a
watchdog thread alive during those forks broke all of them -- SBCL refuses to
fork a multithreaded image."
  (setf *suite-beat* (get-universal-time))
  (unless *suite-watchdog*
    (setf *suite-watchdog*
          (bt:make-thread
           (lambda ()
             ;; A STALL detector, not a timer: the first version fired 1200
             ;; seconds after arming regardless of progress, which would have
             ;; killed any slow-but-healthy run with a false stall dump. The
             ;; beat is refreshed by every daemon-test fixture; only silence
             ;; past the window fires it.
             (loop (sleep 60)
                   (when (> (- (get-universal-time) *suite-beat*) 900)
                     (return)))
             (format t "~&======= SUITE STALLED: all-thread backtraces =======~%")
             (dolist (thread (bt:all-threads))
               (format t "~&----- ~a -----~%" (bt:thread-name thread))
               (ignore-errors
                (sb-thread:interrupt-thread
                 thread (lambda () (sb-debug:print-backtrace :count 14))))
               (sleep 0.3))
             (finish-output)
             (uiop:quit 99))
           :name "suite-watchdog"))))

(defun daemon-test-path ()
  (format nil "/tmp/vivarium-daemond-~36r.sock" (random (expt 2 48) (make-random-state t))))

(defmacro with-daemon ((path) &body body)
  "A daemon of our own, on its own socket, stopped afterwards whatever happens."
  `(let ((,path (daemon-test-path)))
     (ensure-suite-watchdog)
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
     (ensure-suite-watchdog)
     (let* ((,cell (paced-cell environment ,@options))
            (,agent (vivarium.actor::cell-agent ,cell)))
       (declare (ignorable ,agent))
       (unwind-protect (progn ,@body)
         (harness:cancel-agent ,agent)
         (actor:shutdown ,cell)))))

(define-test "the coordinator keeps receiving while a turn is running"
  (with-paced-cell (cell agent :pause 0.05 :limit 20)
    (actor:submit cell "go")
    (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
    ;; If the session's own thread were inside HARNESS:ASK, this message would
    ;; sit in the mailbox until the turn it was meant to interrupt had ended.
    (actor:tell cell :suspend)
    (true (daemon-wait (lambda () (eq :suspended (vivarium.actor::cell-state cell)))))
    (true (vivarium.actor::busy-p cell) "the turn ended instead of being held")
    (actor:tell cell :resume)
    (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 30))))

(define-test "suspend holds the work, not merely the state field"
  (with-paced-cell (cell agent :pause 0.02 :limit 500)
    (actor:submit cell "go")
    (true (daemon-wait (lambda () (> (paced-requests agent) 1))))
    (actor:tell cell :suspend)
    (true (daemon-wait (lambda () (eq :suspended (vivarium.actor::cell-state cell)))))
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
    (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 15)
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
    (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 30))
    (let ((seen (reverse (paced-saw-steer agent))))
      (true (find t seen) "no request in the turn ever saw the steer: ~a" seen)
      ;; And it was not merely the last thing to happen, which is exactly what
      ;; `steer the next turn` looked like from outside.
      (true (< (position t seen) (1- (length seen)))
            "the steer reached only the final request: ~a" seen))))

(define-test "a prompt arriving mid-turn waits rather than running beside it"
  (with-paced-cell (cell agent :pause 0.03 :limit 6)
    (actor:submit cell "first")
    (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
    (actor:submit cell "second")
    (true (daemon-wait (lambda () (= 1 (length (vivarium.actor::cell-queued cell))))))
    (true (daemon-wait (lambda () (= 2 (count "turn.started" (cell-event-names cell)
                                              :test #'string=)))
                       :timeout 30)
          "the queued prompt never ran")
    (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 30))))

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
           (agent (vivarium.actor::cell-agent cell)))
      (unwind-protect
           (progn
             (actor:submit cell "go")
             (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
             (actor:tell cell :cancel)
             (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 15))
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
             (agent (vivarium.actor::cell-agent cell)))
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
    (let ((cell (paced-cell environment :pause 0.02 :limit 500)))
      (actor:submit cell "go")
      (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
      ;; Shut down mid-turn: the case where the two could disagree.
      (actor:shutdown cell)
      (true (daemon-wait (lambda () (member "session.completed" (cell-event-names cell)
                                            :test #'string=))
                         :timeout 30)
            "session.completed was never published")
      ;; Asserted on the journal rather than by sampling at publish time. A
      ;; sampled check is one-sided: a worker that finished in the moment
      ;; between the claim and the sample reads as compliant either way. The
      ;; journal states the property outright -- completion is last, and the
      ;; turn reported before it.
      (let ((names (cell-event-names cell)))
        (is string= "session.completed" (car (last names)))
        (is = 1 (terminal-count names))
        (true (< (position-if (lambda (n) (member n actor:+terminal-events+ :test #'string=))
                              names)
                 (position "session.completed" names :test #'string=))))
      (false (vivarium.actor::busy-p cell)))))

(define-test "a session is findable until its work has stopped"
  (with-repository (environment)
    (let* ((cell (paced-cell environment :pause 0.02 :limit 500))
           (id (actor:cell-id cell)))
      (actor:submit cell "go")
      (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
      (actor:shutdown cell)
      ;; Deregistering on the POST left a session unreachable and still
      ;; working, which is worse than either state on its own.
      (true (daemon-wait (lambda () (null (actor:find-cell id))) :timeout 30)
            "the session never deregistered")
      (false (vivarium.actor::busy-p cell)
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
      (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
      (actor:tell cell :finished :turn "s0-t999" :outcome :completed)
      (sleep 0.2)
      (true (vivarium.actor::busy-p cell) "a stale completion ended the running turn")
      (is equal turn (vivarium.actor::cell-turn cell))
      (is = 0 (terminal-count (cell-event-names cell)))
      ;; Ignored, but not silently: an unexplained message is a symptom.
      (is = 1 (count "session.error" (cell-event-names cell) :test #'string=))
      (actor:tell cell :cancel)
      (true (daemon-wait (lambda () (not (vivarium.actor::busy-p cell))) :timeout 15)))))

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
    (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
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
      (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
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

(define-test "attaching loses no event, repeats none, and reorders none"
  ;; Replay-then-subscribe drops whatever is published in between;
  ;; subscribe-then-replay delivers it twice. Now that a subscriber is a
  ;; mailbox rather than a callback, both halves are handed over inside the
  ;; section that assigns the sequence -- so ordering is assertable too, which
  ;; it was not when the replay ran on the subscribing thread.
  (with-repository (environment)
    (let* ((cell (paced-cell environment :pause 0.01 :limit 1))
           (mailbox (sb-concurrency:make-mailbox))
           ;; Paced on purpose. Publishing as fast as possible finished before
           ;; the subscription was attempted, so the gap this test exists for
           ;; was never open and it passed against the implementation it was
           ;; written to catch.
           (publisher (bt:make-thread
                       (lambda ()
                         (dotimes (i 300)
                           (vivarium.actor::publish cell "model.delta" nil)
                           (sleep 0.001))))))
      (unwind-protect
           (progn
             (sleep 0.05)
             (actor:subscribe-since cell (gensym "A") 0 mailbox)
             (bt:join-thread publisher)
             (sleep 0.3)
             (let ((seen '()))
               (loop for event = (sb-concurrency:receive-message mailbox :timeout 1)
                     while event
                     do (push (event:event-sequence event) seen))
               (let ((numbers (nreverse seen)))
                 (true numbers "nothing was delivered at all")
                 (is = (reduce #'max numbers :initial-value 0) (length numbers)
                     "~d delivered for ~d sequences" (length numbers)
                     (reduce #'max numbers :initial-value 0))
                 (is = (length numbers) (length (remove-duplicates numbers)))
                 (is equal numbers (sort (copy-list numbers) #'<)
                     "delivered out of sequence order"))))
        (actor:shutdown cell)))))

(define-test "retiring a listener that is no longer current does nothing"
  ;; The deterministic half of the test above. The race is what made the bug
  ;; rare; this is the guard that makes it impossible, checked directly.
  (with-daemon (path)
    ;; A generation that was never current: retiring it must change nothing.
    (let ((stranger (vivarium.daemon::make-daemon-instance
                     :socket nil :path "/tmp/nowhere.sock" :fd nil)))
      (vivarium.daemon::retire stranger)
      (true (daemon:running-p path) "retiring a stranger's generation stopped the daemon")
      (true (probe-file path) "retiring a stranger's generation deleted the file")
      (true (gethash "success" (daemon-ask path "type" "ping"))))))

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
           (agent (vivarium.actor::cell-agent cell)))
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
           (agent (vivarium.actor::cell-agent cell)))
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
                    (agent (vivarium.actor::cell-agent cell)))
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
               (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
               (actor:shutdown cell)
               ;; Traffic throughout the whole grace period.
               (let ((chatter (bt:make-thread
                               (lambda () (dotimes (i 30)
                                            (actor:tell cell :resume)
                                            (sleep 0.2))))))
                 (true (daemon-wait (lambda () (eq :stuck (vivarium.actor::cell-state cell))) :timeout 8)
                       "still ~a after the grace period" (vivarium.actor::cell-state cell))
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
                    (agent (vivarium.actor::cell-agent cell)))
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


;;; The primary public path, exercised with sessions PRESENT
;;;
;;; CELL-JSON read the live agent out of a snapshot field that no longer
;;; existed, so every RPC that rendered a session signalled -- including the
;;; greeting, whenever any session existed at connect time. The suite stayed
;;; green for days because almost every daemon test connects with zero
;;; sessions: the flake blamed on timing was a deterministic defect on an
;;; untested path.

(define-test "the greeting and session RPCs survive sessions existing"
  (with-daemon (path)
    (with-repository (environment)
      (let ((cell (paced-cell environment :pause 0.01 :limit 1)))
        (unwind-protect
             (daemon:with-connection (stream path)
               (let ((greeting (com.inuoe.jzon:parse (read-line stream))))
                 (is string= "ready" (gethash "type" greeting))
                 ;; MY session, not the only session: cells from earlier tests
                 ;; deregister asynchronously and may linger a moment.
                 (let ((rendered (find (actor:cell-id cell)
                                       (coerce (gethash "sessions" greeting) 'list)
                                       :key (lambda (each) (gethash "id" each))
                                       :test #'string=)))
                   (true rendered "my session was not in the greeting")
                   (true (stringp (gethash "cwd" rendered)) "cwd missing or not a string")
                   (true (stringp (gethash "model" rendered)) "model missing")
                   (true (stringp (gethash "state" rendered)))))
               (let ((listed (daemon:request stream "type" "session.list")))
                 (true (gethash "success" listed))
                 (true (plusp (length (gethash "sessions" listed)))))
               (let ((attached (daemon:request stream "type" "session.attach"
                                               "session" (actor:cell-id cell))))
                 (true (gethash "success" attached))
                 (is string= (env:env-cwd environment)
                     (gethash "cwd" (gethash "session" attached)))))
          (actor:shutdown cell))))))

(define-test "ask-now returns the turn it asked for, not its successor's state"
  ;; FINISH-TURN may start the next queued turn before a waiter wakes, so
  ;; reading the live agent after the terminal event reads turn N+1's world.
  ;; The reply travels in turn N's own terminal event instead.
  (with-paced-cell (cell agent :pause 0.03 :limit 2)
    (actor:submit cell "first")
    ;; Queued behind the first; its answer must still be its own.
    (is string= "done" (actor:ask-now cell "second" :timeout 30))))

;;; The journal, attacked as a durability claim

(define-test "events evicted from memory are still replayable, and in order"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    ;; Push far past the ring: everything early must come back from disk.
    (dotimes (i (+ vivarium.actor::+tail-limit+ 500))
      (vivarium.actor::publish cell "model.delta" nil))
    ;; Wait for the journal to commit the lot.
    (true (daemon-wait (lambda ()
                         (>= (vivarium.actor::cell-committed cell)
                             (+ vivarium.actor::+tail-limit+ 500 1)))
                       :timeout 30)
          "journal never committed: at ~d"
          (vivarium.actor::cell-committed cell))
    ;; The invariant is CONTIGUITY, not an exact count: session.started is
    ;; sequence 1, and if the burst genuinely outran the disk for a moment the
    ;; session announced the risk with a session.error -- one more event, and
    ;; the machinery working rather than failing. What must never happen is a
    ;; sequence with a hole in it.
    (let* ((events (actor:since cell 0))
           (numbers (mapcar #'event:event-sequence events)))
      (true (>= (length numbers) (+ vivarium.actor::+tail-limit+ 500 1))
            "replay lost events: ~d of at least ~d"
            (length numbers) (+ vivarium.actor::+tail-limit+ 500 1))
      (is equal numbers (alexandria:iota (length numbers) :start 1)
          "the replayed sequence has holes or disorder"))))

(define-test "a journal that cannot write says so instead of pretending"
  (with-repository (environment)
    (let ((cell (paced-cell environment :pause 0.01 :limit 1)))
      (unwind-protect
           (progn
             ;; Break the journal under it: an unwritable path.
             (setf (vivarium.actor::cell-journal-path cell) "/nonexistent/nowhere/x.jsonl")
             (vivarium.actor::publish cell "model.delta" nil)
             (true (daemon-wait
                    (lambda ()
                      (find-if (lambda (event)
                                 (and (string= "session.error" (event:event-name event))
                                      (search "journal write failed"
                                              (gethash "detail" (event:event-data event)))))
                               (owning-events cell)))
                    :timeout 15)
                   "no session.error announced the failure"))
        (actor:shutdown cell)))))

(defun owning-events (cell)
  (vivarium.actor::remembered-since
   cell 0))

(define-test "thread count returns to baseline after session and client churn"
  ;; The organism is meant to run for months. Every lifecycle bug so far has
  ;; been a thread or descriptor outliving its owner -- sweepers surviving
  ;; their daemon, writers surviving their connection -- and each showed up
  ;; first as slow accumulation. This measures the accumulation directly.
  (with-daemon (path)
    (flet ((churn ()
             (with-repository (environment)
               (let ((cell (paced-cell environment :pause 0.005 :limit 2)))
                 (actor:await-turn cell (actor:submit cell "go") :timeout 20)
                 ;; A client that attaches, reads a little, and leaves.
                 (handler-case
                     (daemon:with-connection (stream path)
                       (read-line stream nil nil)
                       (daemon:request stream "type" "session.attach"
                                       "session" (actor:cell-id cell)))
                   (error () nil))
                 (true (actor:await-shutdown cell :timeout 20))))))
      ;; Warm up: lazily-started owners (the journal) come up once and stay.
      (churn)
      (sleep 0.5)
      (let ((baseline (length (bt:all-threads))))
        (dotimes (i 12) (churn))
        ;; Detached cleanup (writer joins, journal closes) may trail briefly.
        (true (daemon-wait (lambda () (<= (length (bt:all-threads)) (+ baseline 2)))
                           :timeout 20)
              "threads grew from ~d to ~d over 12 cycles"
              baseline (length (bt:all-threads)))
        ;; And every one of those disconnects was CLEAN. A writer that never
        ;; confirms leaves a leaked descriptor behind each connection, noted as
        ;; a `close` failure -- thread counts alone missed exactly that, since
        ;; the stuck reader threads drain away on their own timeout.
        (multiple-value-bind (kept total) (daemon:diagnostics)
          (declare (ignore total))
          (let ((leaks (count "close" kept
                              :key (lambda (each) (gethash "where" each))
                              :test #'string=)))
            (is = 0 leaks "~d connections leaked their descriptor" leaks)))))))

;;; The closure gate: four defects, frozen as a list, each attacked
;;;
;;; After these, a newly imagined race is backlog unless it has a concrete
;;; reproduction, violates a frozen invariant by direct analysis, appears in
;;; operation, or Phase 1.5 depends on the unsafe path.

(define-test "replay under concurrent publication delivers every event exactly once"
  ;; The old composition froze the disk boundary, read the file, then read the
  ;; ring -- and whatever crossed from ring to disk DURING the read was in
  ;; neither half. With a small ring and a publisher running flat out, that
  ;; gap opens on nearly every subscription.
  (let ((previous vivarium.actor::+tail-limit+))
    (unwind-protect
         (progn
           (setf vivarium.actor::+tail-limit+ 64)
           (with-repository (environment)
             (let* ((cell (paced-cell environment :pause 0.01 :limit 1))
                    (stop nil)
                    ;; Fast enough that events cross the ring/disk boundary
                    ;; during every replay, paced enough that the journal keeps
                    ;; up overall -- a publisher that outruns the disk for the
                    ;; whole test genuinely loses data past a 64-slot ring, and
                    ;; that is the declared-degradation case, not this one.
                    (publisher (bt:make-thread
                                (lambda ()
                                  (loop until stop
                                        do (dotimes (i 20)
                                             (vivarium.actor::publish cell "model.delta" nil))
                                           (sleep 0.001))))))
               (unwind-protect
                    (progn
                      ;; A journal file big enough that reading it takes real
                      ;; time: the gap under attack only opens when more than
                      ;; a ring's worth of events commit DURING the read, so a
                      ;; small file closes the window and proves nothing --
                      ;; the first version of this test passed against the
                      ;; broken composition for exactly that reason.
                      (true (daemon-wait (lambda ()
                                           (> (vivarium.actor::cell-sequence cell) 20000))
                                         :timeout 60))
                      (dotimes (round 3)
                        (let* ((mailbox (sb-concurrency:make-mailbox))
                               (key (gensym "GATE")))
                          (multiple-value-bind (key barrier)
                              (actor:subscribe-since cell key 0 mailbox)
                            (let ((seen '()))
                              (loop for event = (sb-concurrency:receive-message mailbox :timeout 10)
                                    while event
                                    do (push (event:event-sequence event) seen)
                                    until (>= (event:event-sequence event) barrier))
                              (actor:unsubscribe cell key)
                              (let* ((numbers (nreverse seen))
                                     (through (remove-if (lambda (n) (> n barrier)) numbers)))
                                (true (plusp barrier))
                                (is equal through (alexandria:iota barrier :start 1)
                                    "round ~d: gap or disorder in ~d events through barrier ~d"
                                    round (length through) barrier)))))))
                 (setf stop t)
                 (ignore-errors (bt:join-thread publisher :timeout 10))
                 ;; Fully gone BEFORE the limit is restored: the coordinator's
                 ;; own flush still indexes this cell's 64-slot ring, and a
                 ;; restored 4096 limit would send it off the end of the
                 ;; vector.
                 (actor:await-shutdown cell :timeout 30)))))
      (setf vivarium.actor::+tail-limit+ previous))))

(define-test "a dead journal owner is restarted as a new generation, and heals"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (dotimes (i 50) (vivarium.actor::publish cell "model.delta" nil))
    (let ((before (vivarium.actor::journal-id vivarium.actor::*journal-service*)))
      ;; A message the owner's ECASE cannot answer: the thread dies, and the
      ;; exit boundary -- not any caller's THREAD-ALIVE-P -- must notice.
      (sb-concurrency:send-message
       (vivarium.actor::journal-mailbox vivarium.actor::*journal-service*)
       (list :no-such-verb nil))
      (true (daemon-wait (lambda ()
                           (alexandria:when-let ((service vivarium.actor::*journal-service*))
                             (> (vivarium.actor::journal-id service) before)))
                         :timeout 15)
            "no successor generation appeared")
      ;; Publishing keeps working, and the successor commits what the corpse
      ;; left uncommitted: the watermark catches all the way up.
      (dotimes (i 50) (vivarium.actor::publish cell "model.delta" nil))
      (true (daemon-wait (lambda ()
                           (owning-committed-p cell))
                         :timeout 20)
            "committed ~d of ~d after restart"
            (vivarium.actor::cell-committed cell)
            (vivarium.actor::cell-sequence cell)))))

(defun owning-committed-p (cell)
  (vivarium.actor::owning (cell)
    (>= (vivarium.actor::cell-committed cell)
        (vivarium.actor::cell-sequence cell))))

(define-test "a session stays inspectable until its journal confirms the close"
  ;; Deregistering first meant AWAIT-SHUTDOWN reported success while the
  ;; terminal record was unresolved -- externally complete, durably unknown,
  ;; inspectable by nobody, with the truth on stderr.
  (let ((grace vivarium.actor::*flush-grace*)
        (service vivarium.actor::*journal-service*))
    (unwind-protect
         (with-repository (environment)
           (setf vivarium.actor::*flush-grace* 1)
           (let* ((cell (paced-cell environment :pause 0.01 :limit 1))
                  (id (actor:cell-id cell)))
             (actor:await-turn cell (actor:submit cell "go") :timeout 20)
             ;; The journal refuses everything: unavailable, not merely slow.
             (setf (vivarium.actor::journal-state vivarium.actor::*journal-service*) :failed)
             (false (actor:await-shutdown cell :timeout 5)
                    "shutdown claimed success with the close unconfirmed")
             (true (actor:find-cell id) "the session left the registry anyway")
             (true (find "session.error" (vivarium.actor::remembered-since cell 0)
                         :key #'event:event-name :test #'string=)
                   "the retention was never announced")
             ;; Heal, and the shutdown completes late rather than never.
             (setf (vivarium.actor::journal-state vivarium.actor::*journal-service*) :available)
             (true (daemon-wait (lambda () (null (actor:find-cell id))) :timeout 20)
                   "the healed journal did not release the session")))
      (setf vivarium.actor::*flush-grace* grace)
      (alexandria:when-let ((current vivarium.actor::*journal-service*))
        (when (eq current service)
          (setf (vivarium.actor::journal-state current) :available))))))

(defun daemon-descriptors ()
  (ignore-errors
   (1- (count #\Newline
              (uiop:run-program (list "lsof" "-p" (format nil "~d" (sb-posix:getpid)))
                                :output :string :error-output nil)))))

(define-test "a startup that fails to bind leaks nothing and blocks nothing"
  ;; The OS lock is held by the process, so the same process CAN reacquire it
  ;; -- which is why `the next startup succeeds` alone proves nothing. The
  ;; descriptor count is what a leaked lock fd cannot hide from.
  ;; The socket path IS a directory: the lock fd (path.lock, a sibling file)
  ;; is acquired first, DELETE-FILE cannot remove a directory, and BIND then
  ;; signals -- failure exactly in the window where a leak would live. The
  ;; first two triggers tried did not trigger: a nonexistent parent directory
  ;; is politely created by SERVE itself, and an over-long path is silently
  ;; truncated by the kernel and binds.
  (let* ((impossible (format nil "/tmp/vivarium-bind-blocker-~36r/sock"
                             (random (expt 2 40) (make-random-state t))))
         (baseline (daemon-descriptors)))
    (ensure-directories-exist (format nil "~a/" impossible))
    (dotimes (i 10)
      (fail (daemon:serve :path impossible :background t) 'error))
    (alexandria:when-let ((now (daemon-descriptors)))
      (true (<= now (+ baseline 2))
            "descriptors grew ~d -> ~d over ten failed startups" baseline now))
    ;; And the failed startups left the process able to serve.
    (with-daemon (path)
      (true (daemon:running-p path)))
    (ignore-errors
     (uiop:delete-directory-tree
      (uiop:parse-native-namestring
       (format nil "~a/" (directory-namestring impossible))) :validate t))))

(define-test "an announce callback that signals does not un-start the daemon"
  (let ((path (daemon-test-path)))
    (unwind-protect
         (progn
           (daemon:serve :path path :background t
                         :announce (lambda (p) (declare (ignore p)) (error "boom")))
           (loop repeat 100 until (daemon:running-p path) do (sleep 0.01))
           (true (daemon:running-p path)
                 "a signalling announce turned a started daemon into a failure")
           (true (gethash "success" (daemon-ask path "type" "ping"))))
      (daemon:stop)
      (ignore-errors (delete-file path)))))

;;; The kernel: one checked table, and the coordinator merely performs it

(define-test "the kernel self-test replays its incident traces"
  (true (vivarium.kernel:run-self-test)))

(define-test "a lifecycle hole is a published diagnostic, not a silence or a death"
  ;; :FLUSH-CONFIRMED in :IDLE is a state/message pair the table does not
  ;; know. The kernel signals, the coordinator's policy answers, the session
  ;; stays alive with its state intact.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (actor:tell cell :flush-confirmed)
    (true (daemon-wait (lambda ()
                         (find-if (lambda (event)
                                    (and (string= "session.error" (event:event-name event))
                                         (search "unhandled"
                                                 (gethash "detail" (event:event-data event)))))
                                  (vivarium.actor::remembered-since cell 0)))
                       :timeout 10)
          "the hole was silent")
    (let ((turn (actor:submit cell "still alive?")))
      (is string= "turn.completed" (actor:await-turn cell turn :timeout 20)))))

(define-test "a prompt past the queue limit is refused with its turn named"
  (with-paced-cell (cell agent :pause 0.2 :limit 500)
    (actor:submit cell "running")
    (true (daemon-wait (lambda () (vivarium.actor::busy-p cell))))
    (dotimes (i vivarium.kernel:+queue-limit+)
      (actor:tell cell :user-message :text "queued" :turn (format nil "q~d" i)))
    (let ((refused (actor:submit cell "one too many")))
      (true (daemon-wait
             (lambda ()
               (find-if (lambda (event)
                          (and (string= "session.error" (event:event-name event))
                               (equal refused (gethash "turn" (event:event-data event)))))
                        (vivarium.actor::remembered-since cell 0)))
             :timeout 10)
            "the overflow was absorbed rather than refused"))
    (actor:tell cell :cancel)))

(define-test "a subscriber that stops draining is dropped and the drop announced"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (let ((deaf (sb-concurrency:make-mailbox))
          (key (gensym "DEAF")))
      (actor:subscribe cell key deaf)
      (dotimes (i (+ vivarium.kernel:+subscriber-capacity+ 50))
        (vivarium.actor::publish cell "model.delta" nil))
      (true (daemon-wait
             (lambda ()
               (find-if (lambda (event)
                          (and (string= "session.error" (event:event-name event))
                               (search "dropped" (gethash "detail" (event:event-data event)))))
                        (vivarium.actor::remembered-since cell 0)))
             :timeout 10)
            "the overload was never announced")
      ;; And the mailbox stopped growing: the drop is the bound.
      (true (<= (sb-concurrency:mailbox-count deaf)
                (+ vivarium.kernel:+subscriber-capacity+ 2))
            "~d messages accumulated past capacity"
            (sb-concurrency:mailbox-count deaf)))))

;;; The task tree: the first feature born inside the proof
;;;
;;; TASKTREE-TRANSITION was verified by TLC before the coordinator learned
;;; these verbs (spec/TaskTree.tla: five invariants and terminal-is-forever
;;; over the full space, liveness over the complete smaller one, and two
;;; witness configs whose violations demonstrate detached survival). These
;;; tests drive the WIRING: real sub-agent workers, real mailboxes, the
;;; supervisor performing what the checked table decides.

(defclass enduring-agent (paced-agent) ()
  (:documentation "Workers that run until cancelled: sub-agents share the
class, and the class overrides the pacing initforms."))

(defmethod initialize-instance :after ((agent enduring-agent) &key)
  (setf (paced-pause agent) 0.08
        (paced-limit agent) 1000))

(defun enduring-cell (environment)
  (actor:spawn :label "tasks"
               :agent (make-instance 'enduring-agent
                                     :environment environment
                                     :resource-environment environment
                                     :request-limit 2000)))

(defun task-state-now (id)
  (getf (find id (actor:task-tree-snapshot) :key (lambda (task) (getf task :id)))
        :state))

(define-test "the tasktree self-test replays its invariant traces"
  (true (vivarium.tasktree:run-tasktree-self-test)))

(define-test "a root task runs a real worker to completion on the session stream"
  (with-paced-cell (cell agent :pause 0.01 :limit 2)
    (let ((id (actor:spawn-task cell "count the files")))
      (true (daemon-wait (lambda () (eq :completed (task-state-now id))) :timeout 30)
            "task ~a is ~a" id (task-state-now id))
      (let ((names (cell-event-names cell)))
        (true (member "task.started" names :test #'string=))
        (true (member "task.completed" names :test #'string=)))
      ;; Late completion for a finished task is a diagnostic, not a rewrite.
      (vivarium.actor::task-tell :task-finished id :failed)
      (true (daemon-wait
             (lambda ()
               (find-if (lambda (event)
                          (and (string= "task.error" (event:event-name event))
                               (search "late-task-completion"
                                       (gethash "detail" (event:event-data event)))))
                        (vivarium.actor::remembered-since cell 0)))
             :timeout 10))
      (is eq :completed (task-state-now id)))))

(define-test "cancellation crosses scoped edges only, and the detached child survives"
  (with-repository (environment)
    (let ((cell (enduring-cell environment)))
      (unwind-protect
           (let* ((root (actor:spawn-task cell "root work"))
                  (scoped (actor:spawn-task cell "scoped help" :parent root :scoped t))
                  (detached (actor:spawn-task cell "independent discovery"
                                              :parent root :scoped nil)))
             (true (daemon-wait (lambda () (and (eq :running (task-state-now root))
                                                (eq :running (task-state-now scoped))
                                                (eq :running (task-state-now detached))))
                                :timeout 15))
             (actor:cancel-task root)
             (true (daemon-wait (lambda () (eq :cancelled (task-state-now root))) :timeout 30)
                   "root is ~a" (task-state-now root))
             (true (daemon-wait (lambda () (eq :cancelled (task-state-now scoped))) :timeout 30)
                   "scoped child is ~a" (task-state-now scoped))
             ;; The witness, live: past its parent's terminal state, the
             ;; detached child is running and was never told to stop.
             (is eq :running (task-state-now detached))
             (let ((task (vivarium.tasktree:task
                          (vivarium.actor::supervisor-tree (actor:ensure-supervisor))
                          detached)))
               (false (getf task :cancelled) "the cancel leaked across a detached edge"))
             (actor:cancel-task detached)
             (true (daemon-wait (lambda () (eq :cancelled (task-state-now detached)))
                                :timeout 30)))
        (actor:shutdown cell)))))

(define-test "a parent's outcome parks in draining until its last scoped child lands"
  (with-repository (environment)
    (let ((cell (enduring-cell environment)))
      (unwind-protect
           (let* ((root (actor:spawn-task cell "root work"))
                  (scoped (actor:spawn-task cell "scoped help" :parent root :scoped t)))
             (true (daemon-wait (lambda () (and (eq :running (task-state-now root))
                                                (eq :running (task-state-now scoped))))
                                :timeout 15))
             ;; The parent's own outcome arrives while the child is live: the
             ;; tree must PARK it, and say so.
             (vivarium.actor::task-tell :task-finished root :completed)
             (true (daemon-wait (lambda () (eq :draining (task-state-now root))) :timeout 10)
                   "root is ~a, not draining" (task-state-now root))
             (true (daemon-wait
                    (lambda () (find "task.draining" (vivarium.actor::remembered-since cell 0)
                                     :key #'event:event-name :test #'string=))
                    :timeout 10))
             (vivarium.actor::task-tell :task-finished scoped :completed)
             (true (daemon-wait (lambda () (eq :completed (task-state-now root))) :timeout 10)
                   "the parked outcome never landed: root is ~a" (task-state-now root))
             (is eq :completed (task-state-now scoped)))
        ;; The real workers are still out there; their late reports are
        ;; consumed as diagnostics. Stop them.
        (dolist (task (actor:task-tree-snapshot))
          (alexandria:when-let ((rig (vivarium.actor::rig (actor:ensure-supervisor)
                                                          (getf task :id))))
            (harness:cancel-agent (getf rig :agent))))
        (actor:shutdown cell)))))

(define-test "fan-out past the child limit is refused with the parent named"
  (with-repository (environment)
    (let ((cell (enduring-cell environment)))
      (unwind-protect
           (let ((root (actor:spawn-task cell "root work")))
             (true (daemon-wait (lambda () (eq :running (task-state-now root))) :timeout 15))
             (dotimes (i vivarium.tasktree:+child-limit+)
               (actor:spawn-task cell "child" :parent root :scoped t))
             (true (daemon-wait
                    (lambda ()
                      (= vivarium.tasktree:+child-limit+
                         (length (vivarium.tasktree:live-scoped-children
                                  (vivarium.actor::supervisor-tree (actor:ensure-supervisor))
                                  root))))
                    :timeout 20))
             (false (actor:spawn-task cell "one too many" :parent root :scoped t)
                    "the refused spawn returned an identity")
             (true (daemon-wait
                    (lambda ()
                      (find-if (lambda (event)
                                 (and (string= "task.error" (event:event-name event))
                                      (search "spawn-refused"
                                              (gethash "detail" (event:event-data event)))))
                               (vivarium.actor::remembered-since cell 0)))
                    :timeout 10)
                   "the overflow was never refused")
             (actor:cancel-task root)
             (true (daemon-wait (lambda () (eq :cancelled (task-state-now root))) :timeout 60)))
        (actor:shutdown cell)))))

(define-test "the task tree speaks RPC through the session that owns it"
  (with-daemon (path)
    (with-repository (environment)
      (let ((cell (paced-cell environment :pause 0.01 :limit 2)))
        (unwind-protect
             (daemon:with-connection (stream path)
               (read-line stream nil nil)
               (let ((spawned (daemon:request stream "type" "task.spawn"
                                              "session" (actor:cell-id cell)
                                              "text" "over the wire")))
                 (true (gethash "success" spawned))
                 (let ((id (gethash "task" spawned)))
                   (true (integerp id))
                   (true (daemon-wait (lambda () (eq :completed (task-state-now id)))
                                      :timeout 30))
                   (let ((listed (daemon:request stream "type" "task.list")))
                     (true (gethash "success" listed))
                     (true (find-if (lambda (task)
                                      (and (eql id (gethash "id" task))
                                           (equal "completed" (gethash "state" task))))
                                    (coerce (gethash "tasks" listed) 'list)))))))
          (actor:shutdown cell))))))

(define-test "the evolution self-test replays the lifecycle laws as traces"
  ;; Phase 2's door: the lifecycle of self-modification entered the proof --
  ;; spec/Evolution.tla, safety over the complete space, liveness, and a
  ;; witness whose violation demonstrates the isolation law is violable --
  ;; before any wiring exists. DEACTIVATED ends one task's pin with its
  ;; lifetime; REVERTED moves the promoted lineage back for everyone; an
  ;; unpromoted candidate reaches a task only through that task's own pin.
  (true (vivarium.evolution:run-evolution-self-test)))

;;; Evolution wired: the registry's laws driving real boxes, ledgers, tasks

(define-test "the evolution lifecycle runs end to end through the one door"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (multiple-value-bind (baseline condition)
        (actor:create-candidate "greet" '(lambda (name) (format nil "hello, ~a" name))
                                :cell cell)
      (true (null condition))
      (true (integerp baseline))
      (actor:promote-candidate baseline :cell cell)
      ;; Outside any task: the promoted default resolves.
      (is string= "hello, world" (actor:call-component "greet" "world"))
      ;; A task pins a candidate; visibility is FROM THE NEXT RESOLUTION,
      ;; through the box -- the semantics, held by a test.
      (multiple-value-bind (candidate c2)
          (actor:create-candidate "greet" '(lambda (name) (format nil "HELLO, ~a" name)))
        (true (null c2))
        (let ((box (vivarium.actor::task-context-box "test-task" cell)))
          (let ((vivarium.actor:*activation-box* box))
            (is string= "hello, world" (actor:call-component "greet" "world"))
            (actor:activate-candidate "test-task" candidate :cell cell)
            (is string= "HELLO, world" (actor:call-component "greet" "world"))))
        ;; Another context never sees the pin: isolation at the surface.
        (is string= "hello, world" (actor:call-component "greet" "world"))
        ;; Discard refused while pinned; after the task ends, it proceeds.
        (true (member :refused (alexandria:ensure-list
                                (actor:discard-candidate candidate))))
        (vivarium.actor::evolution-tell :task-ended "test-task")
        (true (daemon-wait
               (lambda () (eql candidate (actor:discard-candidate candidate)))
               :timeout 10)
              "the discard never proceeded after the pin died")
        ;; The story is on the session stream.
        (let ((names (cell-event-names cell)))
          (dolist (expected '("improvement.created" "improvement.activated"
                              "improvement.deactivated"))
            (true (member expected names :test #'string=)
                  "~a never published" expected)))))))

(define-test "a child's first resolution already sees its parent's pins"
  ;; The ordering obligation as behaviour: the supervisor posts :task-spawned
  ;; and WAITS before the child's worker exists, so there is no window where
  ;; the child resolves without its inheritance.
  (with-repository (environment)
    (let ((cell (enduring-cell environment)))
      (unwind-protect
           (let ((root (actor:spawn-task cell "root work")))
             (true (daemon-wait (lambda () (eq :running (task-state-now root))) :timeout 15))
             (multiple-value-bind (candidate condition)
                 (actor:create-candidate "search" '(lambda () :v2) :cell cell)
               (declare (ignore condition))
               (actor:activate-candidate root candidate :cell cell)
               ;; Twenty spawns, each read immediately: fire-and-forget
               ;; ordering wins this race sometimes, which is exactly why one
               ;; spawn proved nothing when this attack first ran. Each child
               ;; LANDS before the next spawns -- cancellation is asynchronous
               ;; and a cancelling child is still live, so twenty rapid spawns
               ;; piled into the fan-out bound and the tree correctly refused
               ;; the ninth: the first version of this hammer failed against
               ;; the law it was not testing.
               (dotimes (round 20)
                 ;; The evolver must be BUSY for the unordered interleaving to
                 ;; exist at all: idle, it processes a fire-and-forget spawn in
                 ;; microseconds and wins every race, which let the ordering
                 ;; attack escape twice. Fifty queued messages of headroom turn
                 ;; `the reply implies the inheritance ran` from luck into the
                 ;; property under test.
                 (dotimes (i 50)
                   (vivarium.actor::evolution-tell
                    :task-ended (format nil "noise-~d-~d" round i)))
                 (let ((child (actor:spawn-task cell "scoped help" :parent root :scoped t)))
                   (true (integerp child) "round ~d: spawn refused" round)
                   (when (integerp child)
                     (let ((box (vivarium.actor::task-context-box child nil)))
                       (true (assoc "search" (car box) :test #'equal)
                             "round ~d: the child's box is empty" round))
                     (actor:cancel-task child)
                     (true (daemon-wait (lambda () (eq :cancelled (task-state-now child)))
                                        :timeout 20)
                           "round ~d: the child never landed" round))))
               (let ((child (actor:spawn-task cell "scoped help" :parent root :scoped t)))
                 (true (integerp child))
                 ;; And the registry can see through the spawn: the parent
                 ;; dies, the child's inherited pin still blocks the discard.
                 (actor:cancel-task root)
                 (true (daemon-wait (lambda () (eq :cancelled (task-state-now root)))
                                    :timeout 30)))))
        (actor:shutdown cell)))))

(define-test "setf of symbol-function is not a door"
  ;; The enforcement point of the entire guarantee: call sites reach
  ;; components only through the activation context. A setf of a symbol's
  ;; function cell is promotion through the back door -- and here, it is a
  ;; setf of something nothing resolves through.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (multiple-value-bind (baseline condition)
        (actor:create-candidate "bypass-probe" '(lambda () :honest) :cell cell)
      (declare (ignore condition))
      (actor:promote-candidate baseline)
      (setf (symbol-function 'bypass-probe-decoy) (lambda () :bypassed))
      (is eq :honest (actor:call-component "bypass-probe"))
      ;; Even a symbol named like the component changes nothing: components
      ;; are keys in the owner's table, not fbound names.
      (setf (symbol-function (intern "BYPASS-PROBE")) (lambda () :bypassed))
      (is eq :honest (actor:call-component "bypass-probe")))))

(define-test "a candidate that will not compile is the caller's rejection"
  (multiple-value-bind (id condition)
      (actor:create-candidate "broken" '(lambda (x) (no-such-function-anywhere x)))
    ;; Undefined functions warn rather than error at compile time; a
    ;; malformed lambda errors. Use the malformed case for determinism.
    (declare (ignore id condition)))
  (multiple-value-bind (id condition)
      (actor:create-candidate "broken" '(lambda (x)))
    (declare (ignore id condition)))
  (multiple-value-bind (id condition)
      (actor:create-candidate "broken" '(lambda "not a lambda list" x))
    (false id "a malformed candidate was accepted")
    (true condition "the rejection carried no condition"))
  ;; And the owner survived its caller's mistake.
  (multiple-value-bind (id condition)
      (actor:create-candidate "broken" '(lambda () :fine))
    (true (null condition))
    (true (integerp id))))

(define-test "the lineage is reconstructible from the ledger after a restart"
  ;; Promotions and reversions are durable facts about the organism; the
  ;; registry is image state and the image is mortal.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (multiple-value-bind (v1 c1) (actor:create-candidate "durable" '(lambda () 1))
      (declare (ignore c1))
      (multiple-value-bind (v2 c2) (actor:create-candidate "durable" '(lambda () 2))
        (declare (ignore c2))
        (actor:promote-candidate v1)
        (actor:promote-candidate v2)
        (actor:revert-component "durable")
        (true (vivarium.actor::journal-sync) "the ledger never confirmed")
        (let ((lineages (actor:reconstruct-lineage)))
          (is eql v1 (first (cdr (assoc "durable" lineages :test #'equal)))
              "reconstruction disagrees with the registry: ~s" lineages)
          (is eql v1 (vivarium.evolution:current-promoted
                      (actor:evolution-registry) "durable")))))))

(define-test "a predecessor's late death restarts nothing, by the table"
  ;; Hardening item one, retired: the journal supervisor's decisions now go
  ;; through KERNEL:JOURNAL-TRANSITION, whose stale-generation clause is the
  ;; identity law. A dead generation reporting twice -- or reporting after its
  ;; successor is up -- is diagnosed, not restarted over the living.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (vivarium.actor::ensure-journal)
    (let ((corpse vivarium.actor::*journal-service*))
      (sb-concurrency:send-message (vivarium.actor::journal-mailbox corpse)
                                   (list :no-such-verb nil))
      (true (daemon-wait (lambda ()
                           (alexandria:when-let ((service vivarium.actor::*journal-service*))
                             (> (vivarium.actor::journal-id service)
                                (vivarium.actor::journal-id corpse))))
                         :timeout 15))
      (let ((survivor vivarium.actor::*journal-service*))
        ;; The corpse reports its death AGAIN: the stale clause absorbs it.
        ;; Identity, not arithmetic: the bypass attack spawned a fresh service
        ;; carrying the SAME generation number, and a number comparison
        ;; blessed it. The service OBJECT must be untouched.
        (vivarium.actor::journal-owner-exited corpse)
        (sleep 0.5)
        (true (eq survivor vivarium.actor::*journal-service*)
              "a stale exit replaced the living generation")
        (dotimes (i 5) (vivarium.actor::publish cell "model.delta" nil))
        (true (daemon-wait (lambda () (owning-committed-p cell)) :timeout 15)
              "the surviving generation stopped committing")))))

;;; ---------------------------------------------------------------------------
;;; KC6: the door, and the ledger's account of USE
;;;
;;; Arm B of the protocol is this organism with the two verbs that change what
;;; it runs refused, so the refusal is a guard beside the other guards and
;;; spec/Evolution.tla's ClosedDoorIsInert is its law. These tests are the
;;; mirror's evidence.
;;; ---------------------------------------------------------------------------

(defun ledger-event-names (&optional (path (vivarium.actor::evolution-ledger-path)))
  "Event names from the durable ledger, in the order they were committed. The
ORDER is load-bearing: KC6 joins an activation to the resolutions that follow
it, and a resolution recorded before its activation would score as a use of
something not yet activated."
  (when (probe-file path)
    (with-open-file (in path :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            for table = (ignore-errors (com.inuoe.jzon:parse line))
            when table collect (gethash "event" table)))))

(defmacro with-door ((door) &body body)
  "Run BODY against an owner born into DOOR, then put the suite's own owner
back. The displaced owner is RESTORED rather than discarded: its registry is
every candidate the rest of the suite created."
  `(let ((displaced vivarium.actor::*evolver*)
         (previous vivarium.actor::*default-door*))
     (unwind-protect
          (progn
            (setf vivarium.actor::*evolver* nil
                  vivarium.actor::*default-door* ,door)
            (vivarium.actor::ensure-evolver)
            ,@body)
       (alexandria:when-let ((mine vivarium.actor::*evolver*))
         (unless (eq mine displaced)
           (sb-concurrency:send-message (vivarium.actor::evolver-mailbox mine)
                                        (list :shutdown))))
       (setf vivarium.actor::*evolver* displaced
             vivarium.actor::*default-door* previous))))

(define-test "the door decides the arm, and the open arm proves this can lose"
  ;; ONE body, both arms, opposite expectations. Written this way on purpose:
  ;; a closed-door test that only asserts refusals passes just as well against
  ;; an owner that refuses everything, or one whose activate never worked at
  ;; all -- which would quietly turn arm B into "the broken arm" and hand KC6
  ;; a result about a bug. The open pass is the control on the instrument.
  (dolist (arm '((:open t) (:closed nil)))
    (destructuring-bind (door expect-effect) arm
      (with-door (door)
        (with-paced-cell (cell agent :pause 0.01 :limit 1)
          (let ((task (format nil "kc6-~(~a~)" door))
                (component (format nil "kc6-door-~(~a~)" door)))
            (multiple-value-bind (id condition)
                (actor:create-candidate component '(lambda () :evolved) :cell cell)
              ;; CREATE is open in both arms by pre-registration: arm B pays
              ;; the same cost for the same attempt and gets no effect, which
              ;; is the overhead the arm exists to price.
              (false condition "~(~a~): create was refused" door)
              (true (integerp id) "~(~a~): no version was minted" door)
              (let ((answer (actor:activate-candidate task id :cell cell)))
                (if expect-effect
                    (is eql id answer "open: activation did not take")
                    (is equal '(:refused :door) answer
                        "closed: activation was not refused by the door")))
              ;; ClosedDoorIsInert, in Lisp: with the door shut nothing this
              ;; run produced resolves for anybody, through either channel.
              (let ((box (vivarium.actor::task-context-box task nil)))
                (let ((vivarium.actor::*activation-box* box)
                      (vivarium.actor::*resolution-task* task)
                      (vivarium.actor::*resolutions-seen* (make-hash-table :test #'equal)))
                  (if expect-effect
                      (is eq :evolved (actor:call-component component))
                      (false (actor:resolve-component component)
                             "closed: a pin exists that the door refused"))))
              (let ((answer (actor:promote-candidate id :cell cell)))
                (if expect-effect
                    (is eql id answer "open: promotion did not take")
                    (is equal '(:refused :door) answer
                        "closed: promotion was not refused by the door")))
              (if expect-effect
                  (is eql id (vivarium.evolution:current-promoted
                              (actor:evolution-registry) component))
                  (false (vivarium.evolution:current-promoted
                          (actor:evolution-registry) component)
                         "closed: a promoted default appeared"))
              ;; The refusal is DATA. An analysis counting what arm B tried to
              ;; do reads this; a line on *error-output* would be unreadable.
              (let ((names (cell-event-names cell)))
                (if expect-effect
                    (false (member "improvement.door-refused" names :test #'string=)
                           "open: the door refused something")
                    (is = 2 (count "improvement.door-refused" names :test #'string=)
                        "closed: the two refusals were not both published"))))))))))

(define-test "the ledger records use, once per task and version, after the activation"
  ;; KC6's instrumentality pre-check joins improvement.activated to the
  ;; resolutions that follow it. Before this the ledger held every decision
  ;; the organism made and nothing about whether any of it was ever RUN, so
  ;; the pre-check that exists to catch a placebo result was itself unable to
  ;; fail. Bounded to first use per pair: a per-call event would put the
  ;; journal on the hot path.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (let ((task "kc6-use") (component "kc6-instrument"))
      (multiple-value-bind (id condition)
          (actor:create-candidate component '(lambda () :used) :cell cell)
        (false condition)
        (actor:activate-candidate task id :cell cell)
        ;; Rigged with the CELL and resolved in ANOTHER THREAD, because that is
        ;; what the supervisor does: a first version of this test rigged the
        ;; task with NIL, sent the event to the ledger alone, and reported a
        ;; broken instrument as a broken product.
        (let ((box (vivarium.actor::task-context-box task cell))
              (results '()))
          (bt:join-thread
           (bt:make-thread
            (lambda ()
              (let ((vivarium.actor::*activation-box* box)
                    (vivarium.actor::*resolution-task* task)
                    (vivarium.actor::*resolutions-seen* (make-hash-table :test #'equal)))
                (dotimes (i 25) (push (actor:call-component component) results))))
            :name "kc6-resolution-worker"))
          (is = 25 (count :used results) "the worker did not resolve the pin"))
        (true (daemon-wait
               (lambda () (member "improvement.resolved" (cell-event-names cell)
                                  :test #'string=))
               :timeout 15)
              "twenty-five uses and the ledger heard about none of them")
        (is = 1 (count "improvement.resolved" (cell-event-names cell) :test #'string=)
            "use is reported per call rather than per version")
        (true (vivarium.actor::journal-sync) "the ledger never confirmed")
        ;; THE ORDERING CLAIM, at the ledger the analysis will actually read.
        ;; A worker journalling its own use would race the owner's activation
        ;; publish -- the reply is sent before it -- and the join would see a
        ;; resolution of something not yet activated.
        (let* ((names (ledger-event-names))
               (activated (position "improvement.activated" names :test #'string=
                                                                  :from-end t))
               (resolved (position "improvement.resolved" names :test #'string=
                                                                :from-end t)))
          (true (and activated resolved) "the ledger is missing one of the pair")
          (when (and activated resolved)
            (true (< activated resolved)
                  "use was recorded before the activation that caused it")))))))

(define-test "telemetry is not a transition"
  ;; :RESOLVED is handled ahead of the table because an action that leaves
  ;; every variable unchanged is what stuttering already permits, and a clause
  ;; for it would put a non-decision where the decisions live. That argument
  ;; is only honest if the message provably cannot move the registry.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (let ((before (actor:evolution-registry)))
      (dotimes (i 10)
        (vivarium.actor::evolution-tell :resolved "ghost-task" "ghost" 999))
      (sleep 0.3)
      (is eq before (actor:evolution-registry)
          "a telemetry message rewrote the registry")
      ;; And a task nobody rigged reaches no session's stream: telemetry for
      ;; an unknown task is a ledger fact, never another session's event.
      (false (member "improvement.resolved" (cell-event-names cell) :test #'string=)
             "a ghost task's telemetry leaked into an unrelated session"))))

(define-test "an activation is visible to the task that asked for it"
  ;; The reply used to be sent INSIDE the publish effect, so :ACTIVATE
  ;; answered before :REBIND-TASK-CONTEXT wrote the task's box: a worker could
  ;; activate a candidate and then fail to resolve it, having missed its own
  ;; activation. The suite never lost that race; KC6's preflight lost it on its
  ;; second run, which is the whole argument for building the end-to-end thing
  ;; before trusting the unit tests around it.
  ;;
  ;; A regression GUARD, not the evidence. Fifty unwidened rounds pass against
  ;; the broken ordering too -- the owner reaches the box write before a caller
  ;; can start a thread -- so this test cannot lose and must not be quoted as
  ;; though it caught anything. The evidence is
  ;; experiments/kc6/visibility-window.lisp, which widens the window by one line
  ;; and separates completely: 200 of 200 invisible before the fix, 0 of 200
  ;; after. Three attacks in this project were already believed on a green they
  ;; had not earned.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (let ((missed 0))
      (dotimes (round 50)
        (let ((task (format nil "kc6-visible-~d" round))
              (component (format nil "kc6-visible-~d" round)))
          (multiple-value-bind (id condition)
              (actor:create-candidate component '(lambda () :seen) :cell cell)
            (false condition "round ~d: create refused" round)
            (actor:activate-candidate task id :cell cell)
            ;; No sleep, no wait: the answer to ACTIVATE is the only thing
            ;; standing between here and the resolution, which is precisely
            ;; the claim under test.
            (let ((box (vivarium.actor::task-context-box task cell))
                  (seen nil))
              (bt:join-thread
               (bt:make-thread
                (lambda ()
                  (let ((vivarium.actor::*activation-box* box)
                        (vivarium.actor::*resolution-task* task)
                        (vivarium.actor::*resolutions-seen*
                          (make-hash-table :test #'equal)))
                    (setf seen (ignore-errors (actor:call-component component)))))
                :name "kc6-visibility-worker"))
              (unless (eq :seen seen) (incf missed))))))
      (is = 0 missed "~d of 50 activations were invisible to their own task" missed))))

;;; ---------------------------------------------------------------------------
;;; The model-facing door
;;;
;;; Driven through TOOL:EXECUTE with a string-keyed argument table -- the shape
;;; the agent loop hands a tool after parsing the model's JSON -- and never by
;;; calling the tool body directly. A tool that works when called from Lisp and
;;; fails from the wire is the exact bug that cost B14 an entire experiment.
;;; ---------------------------------------------------------------------------

(defun tool-named (name)
  (find name (actor:capability-tools) :key #'tool:tool-name :test #'string=))

(defun run-capability-tool (name &rest arguments)
  "Execute as the loop does: one hash table of string keys, one context."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on arguments by #'cddr do (setf (gethash key table) value))
    (tool:execute (tool-named name) table nil)))

(defun created-version (result)
  "The version id out of CREATE_CAPABILITY's prose. Scans for the first run of
digits rather than counting spaces: the note the model supplies lands in the
middle of that sentence, and the first version of this test parsed the word
`version` and asked the tool to activate NIL."
  (let ((output (tool:tool-result-output result)))
    (let ((start (position-if #'digit-char-p output)))
      (and start (parse-integer output :start start :junk-allowed t)))))

(defmacro with-capability-agent ((agent) &body body)
  "A tool reaches its caller through HARNESS:*AGENT*, so a test that does not
bind it is testing nothing the agent loop does."
  `(let ((vivarium.harness:*agent* ,agent)) ,@body))

(define-test "an agent mints a capability, puts it in force, and runs it"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (with-capability-agent (agent)
      (let ((created (run-capability-tool
                      "create_capability"
                      "name" "kc6-shout"
                      "source" "(lambda (input) (string-upcase input))"
                      "note" "the friction this family repeats")))
        (false (tool:tool-result-error-p created)
               "create refused: ~a" (tool:tool-result-output created))
        (let ((version (created-version created)))
          (true (integerp version) "no version in ~s" (tool:tool-result-output created))
          ;; Before activation the capability resolves to nothing: creating is
          ;; not using, which is the whole distinction the ledger records.
          (let ((early (run-capability-tool "call_capability" "name" "kc6-shout" "input" "x")))
            (true (tool:tool-result-error-p early)
                  "an unactivated version was callable"))
          (let ((activated (run-capability-tool "activate_capability" "version" version)))
            (false (tool:tool-result-error-p activated)
                   "activate refused: ~a" (tool:tool-result-output activated)))
          (let ((called (run-capability-tool "call_capability"
                                             "name" "kc6-shout" "input" "quiet")))
            (false (tool:tool-result-error-p called)
                   "call failed: ~a" (tool:tool-result-output called))
            (is string= "QUIET" (tool:tool-result-output called)))
          ;; And the ledger heard about the use, which is what pre-check three
          ;; will read.
          (true (daemon-wait
                 (lambda () (member "improvement.resolved" (cell-event-names cell)
                                    :test #'string=))
                 :timeout 15)
                "the agent ran its own capability and the ledger recorded no use"))))))

(define-test "the closed door refuses the model, and says so in words it can act on"
  ;; Arm B, through the tools rather than through the Lisp API: the agent may
  ;; still create -- it pays the same cost for the same attempt, which is the
  ;; overhead the arm exists to price -- and may never put anything in force.
  (with-door (:closed)
    (with-paced-cell (cell agent :pause 0.01 :limit 1)
      (with-capability-agent (agent)
        (let ((created (run-capability-tool
                        "create_capability" "name" "kc6-frozen"
                        "source" "(lambda (input) (string-downcase input))")))
          (false (tool:tool-result-error-p created)
                 "arm B refused CREATE, which it is pre-registered to allow")
          (let* ((version (created-version created))
                 (activated (run-capability-tool "activate_capability" "version" version)))
            (true (tool:tool-result-error-p activated) "the closed door let one through")
            (true (search "disabled in this configuration"
                          (tool:tool-result-output activated))
                  "the refusal does not say the door is shut: ~s"
                  (tool:tool-result-output activated))
            (true (search "do not retry" (tool:tool-result-output activated))
                  "a refusal that invites retries charges thrash to the machinery")
            ;; ClosedDoorIsInert, reached the way a model would reach it.
            (let ((called (run-capability-tool "call_capability"
                                               "name" "kc6-frozen" "input" "X")))
              (true (tool:tool-result-error-p called)
                    "a closed run resolved something it created"))
            (let ((promoted (run-capability-tool "promote_capability" "version" version)))
              (true (tool:tool-result-error-p promoted) "promotion survived a closed door"))))))))

(define-test "the model's mistakes come back as results, never as the run's death"
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (with-capability-agent (agent)
      ;; Will not read.
      (let ((result (run-capability-tool "create_capability" "name" "kc6-bad"
                                                             "source" "(lambda (input")))
        (true (tool:tool-result-error-p result) "unreadable source was accepted"))
      ;; Reads, but is not a lambda.
      (let ((result (run-capability-tool "create_capability" "name" "kc6-bad"
                                                             "source" "42")))
        (true (tool:tool-result-error-p result) "a non-lambda was accepted"))
      ;; Reads as a lambda and will not compile: COMPILE does not signal on a
      ;; malformed lambda list, it returns a callable that fails later.
      (let ((result (run-capability-tool "create_capability" "name" "kc6-bad"
                                                             "source" "(lambda \"nope\" x)")))
        (true (tool:tool-result-error-p result) "a malformed lambda was accepted"))
      ;; Compiles, then fails at run time. The agent sees the error and the
      ;; process lives -- this is the one place authored code executes.
      (let* ((created (run-capability-tool
                       "create_capability" "name" "kc6-explodes"
                       "source" "(lambda (input) (error \"boom: ~a\" input))"))
             (version (created-version created)))
        (false (tool:tool-result-error-p created))
        (run-capability-tool "activate_capability" "version" version)
        (let ((called (run-capability-tool "call_capability"
                                           "name" "kc6-explodes" "input" "now")))
          (true (tool:tool-result-error-p called) "an exploding capability reported success")
          (true (search "boom: now" (tool:tool-result-output called))
                "the agent was not told what went wrong: ~s"
                (tool:tool-result-output called)))))))

(define-test "a worker inherits its parent's capability tools"
  ;; The evolution table copies a parent's pins into its child at spawn, by
  ;; proven law. That is worth nothing if the child has no tool able to resolve
  ;; them -- and SUB-AGENT copied environment, session, model, skills,
  ;; templates, listener and active-tools while silently dropping extra-tools.
  ;; A parent could self-modify and its workers could not.
  (with-paced-cell (cell agent :pause 0.01 :limit 1)
    (setf (vivarium.harness::agent-extra-tools agent) (actor:capability-tools))
    (let* ((child (harness:sub-agent agent "kc6-inherit-lane"))
           (names (mapcar #'tool:tool-name (vivarium.agent:tools child))))
      (dolist (verb '("create_capability" "activate_capability" "call_capability"))
        (true (member verb names :test #'string=)
              "a worker cannot ~a; its parent can" verb)))))
