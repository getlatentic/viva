;;;; An upgrade replaces the daemon's image in the same process.
;;;;
;;;; The exec itself is proved against a real daemon by tools/upgrade_check.py,
;;;; which is the only place a process can be replaced and still be watched.
;;;; These drive what the exec depends on, in this image: that a hold lets a
;;;; turn finish and starts nothing, that what a session, a job and the
;;;; evolver write down is enough to continue them, that a connection stops
;;;; only between lines, and that a program which cannot take over is refused
;;;; before anything is touched.

(in-package #:viva.tests)

(defmacro with-sessions-released (&body body)
  "Run BODY, and release the hold whatever happens: a suite left holding would
start no turn in any test after this one."
  `(unwind-protect (progn ,@body)
     (actor:release-sessions)))

(defun turn-names (cell)
  (remove-if-not (lambda (name) (member name '("turn.started" "turn.completed") :test #'string=))
                 (cell-event-names cell)))

(define-test "a hold lets the running turn finish and starts nothing after it"
  (with-paced-cell (cell agent :pause 0.05 :limit 8)
    (with-sessions-released
      (actor:submit cell "first")
      (true (daemon-wait (lambda () (actor:busy-p cell))))
      (actor:hold-sessions)
      (true (daemon-wait (lambda () (eq :draining (viva.actor::cell-state cell)))))
      (true (actor:unsettled-reason cell) "a draining session called itself at rest")
      ;; Behind the running turn, as a prompt waits behind any turn.
      (actor:submit cell "second")
      (true (daemon-wait (lambda () (actor:at-rest-p cell)) :timeout 30)
            "the running turn never finished")
      (is eq :held (viva.actor::cell-state cell))
      (is = 1 (length (viva.actor::cell-queued cell)) "the waiting prompt was not kept")
      (is equal '("turn.started" "turn.completed") (turn-names cell)
          "a turn started while held")
      (actor:release-sessions)
      (true (daemon-wait (lambda () (= 2 (terminal-count (cell-event-names cell)))) :timeout 30)
            "release did not start what the hold kept"))))

(define-test "a session carried across keeps its place, its journal and its queue"
  (with-paced-cell (cell agent :pause 0.01 :limit 2)
    (with-sessions-released
      (actor:submit cell "before")
      (true (daemon-wait (lambda () (= 1 (terminal-count (cell-event-names cell)))) :timeout 30))
      (actor:hold-sessions)
      (true (daemon-wait (lambda () (actor:at-rest-p cell))))
      (actor:submit cell "waited through the upgrade")
      (true (actor:settle cell))
      (true (actor:journal-sync))
      (let* ((before (actor:since cell 0))
             (record (com.inuoe.jzon:parse (com.inuoe.jzon:stringify (actor:cell-record cell)))))
        ;; The old image, gone: out of the registry, its coordinator ended.
        (bordeaux-threads:with-lock-held (viva.actor::*registry-lock*)
          (remhash (actor:cell-id cell) viva.actor::*cells*))
        (setf (viva.actor::cell-machine cell) '(:completed))
        (actor:tell cell :barrier :semaphore (bordeaux-threads:make-semaphore))
        (let ((carried (actor:adopt-cell record
                                         (make-instance 'paced-agent
                                                        :environment (harness:agent-environment agent)
                                                        :resource-environment (harness:agent-environment agent)
                                                        :pause 0.01 :limit 2 :request-limit 50))))
          (unwind-protect
               (progn
                 (is equal (actor:cell-id cell) (actor:cell-id carried))
                 (is equal (viva.actor::cell-journal-path cell) (viva.actor::cell-journal-path carried))
                 (is = (viva.actor::cell-sequence cell) (viva.actor::cell-sequence carried))
                 (is = 1 (length (viva.actor::cell-queued carried)))
                 (is equal (mapcar #'event:event-sequence before)
                     (mapcar #'event:event-sequence (actor:since carried 0))
                     "the recent events did not come back from the journal")
                 (actor:release-sessions)
                 (true (daemon-wait (lambda () (= 2 (terminal-count (cell-event-names carried))))
                                    :timeout 30)
                       "the waiting prompt did not run in the new image")
                 (let ((sequences (mapcar #'event:event-sequence (actor:since carried 0))))
                   (is equal (alexandria:iota (length sequences) :start 1) sequences
                       "the stream has a gap or a repeat across the handover")))
            (actor:shutdown carried)))))))

(define-test "a job carried across is read from the same pipe and reaped as a child"
  (let* ((name (format nil "carried-~36r" (random (expt 2 32) (make-random-state t))))
         (job (jobs:start "echo one; sleep 0.6; echo two; sleep 30" :name name)))
    (unwind-protect
         (progn
           (true (daemon-wait (lambda () (search "one" (jobs:output-of job))) :timeout 10))
           (true (jobs:pause-pumps))
           (let ((record (find name (jobs:handoff-records)
                               :key (lambda (each) (gethash "name" each)) :test #'equal)))
             (true (gethash "fd" record) "a running job wrote down no descriptor")
             ;; What the exec keeps: the descriptor, under a number of its own.
             (setf (gethash "fd" record) (sb-posix:dup (gethash "fd" record)))
             ;; What the exec takes: the process object SBCL tracks it by, and
             ;; the stream it was read through.
             (let ((process (viva.jobs::job-process job)))
               (sb-thread:with-recursive-lock (sb-impl::*active-processes-lock*)
                 (setf sb-impl::*active-processes*
                       (delete process sb-impl::*active-processes*)))
               (close (sb-ext:process-output process)))
             (bordeaux-threads:with-lock-held (viva.jobs::*lock*) (remhash name viva.jobs::*jobs*))
             (jobs:resume-pumps)
             (let ((carried (jobs:adopt (com.inuoe.jzon:parse (com.inuoe.jzon:stringify record)))))
               (true (jobs:alive-p carried))
               (true (daemon-wait (lambda () (search "two" (jobs:output-of carried))) :timeout 10)
                     "the carried job's later output never arrived")
               (true (search "one" (jobs:output-of carried)) "the log lost what came before")
               (jobs:stop carried)
               (false (jobs:alive-p carried))
               (is equal "exited 143" (jobs:status-of carried)
                   "the exit was not reaped from the child"))))
      (jobs:resume-pumps)
      (alexandria:when-let ((left (jobs:find-job name))) (ignore-errors (jobs:stop left))))))

(define-test "a handoff that cannot be read closes what it was handed"
  (multiple-value-bind (in out) (sb-posix:pipe)
    (let ((path (format nil "/tmp/viva-handoff-~36r.json" (random (expt 2 32) (make-random-state t)))))
      (with-open-file (file path :direction :output :if-exists :supersede)
        (write-string "{not json" file))
      (sb-posix:setenv "VIVA_HANDOFF" path 1)
      (sb-posix:setenv "VIVA_HANDOFF_DESCRIPTORS" (format nil "~d,~d" in out) 1)
      (false (viva.daemon::read-handoff))
      (flet ((open-p (fd)
               (handler-case (progn (sb-posix:fcntl fd sb-posix:f-getfd) t)
                 (sb-posix:syscall-error () nil))))
        (false (open-p in) "an inherited descriptor was left open")
        (false (open-p out) "an inherited descriptor was left open"))
      (false (sb-posix:getenv "VIVA_HANDOFF") "a child would believe it was handed over")
      (false (probe-file path))
      ;; And one that can be read comes back as it was written.
      (viva.daemon::write-handoff (viva.daemon::object "format" viva.daemon:+handoff-format+ "carried" 7)
                                  path)
      (is = #o600 (logand #o777 (sb-posix:stat-mode (sb-posix:stat path)))
          "the state holds conversation and was readable by others")
      (sb-posix:setenv "VIVA_HANDOFF" path 1)
      (is = 7 (gethash "carried" (viva.daemon::read-handoff))))))

(define-test "a connection stops between lines for an upgrade, and carries on after"
  (with-daemon (path)
    (let ((stream (daemon:connect path)))
      (unwind-protect
           (progn
             (read-line stream nil nil)
             (setf viva.daemon::*quiescing* t)
             (true (daemon-wait (lambda ()
                                  (and (not viva.daemon::*accepting*)
                                       (notany #'viva.daemon::client-reading
                                               (viva.daemon::live-clients))))
                                :timeout 5)
                   "a reader or the accept loop did not stop")
             (write-line "{\"type\":\"session.list\",\"id\":7}" stream)
             (force-output stream)
             (sleep 0.6)
             (false (listen stream) "a stopped reader answered a request")
             (setf viva.daemon::*quiescing* nil)
             (true (daemon-wait (lambda () (listen stream)) :timeout 5)
                   "the request was lost instead of waiting")
             (let ((reply (com.inuoe.jzon:parse (read-line stream))))
               (is = 7 (gethash "id" reply))))
        (setf viva.daemon::*quiescing* nil)
        (ignore-errors (close stream))))))

(define-test "an upgrade refuses a program that cannot take over"
  (let ((script (format nil "/tmp/viva-handoff-program-~36r" (random (expt 2 32) (make-random-state t)))))
    (flet ((program (text)
             (with-open-file (out script :direction :output :if-exists :supersede)
               (format out "#!/bin/sh~%~a~%" text))
             (sb-posix:chmod script #o700)
             script))
      (unwind-protect
           (progn
             (true (viva.daemon::preflight "/nonexistent/viva") "a missing program was accepted")
             (true (search "handoff format" (or (viva.daemon::preflight (program "echo '(99)'")) ""))
                   "a program reading another format was accepted")
             (true (search "exited 3" (or (viva.daemon::preflight (program "exit 3")) ""))
                   "a program that fails was accepted")
             (false (viva.daemon::preflight
                     (program (format nil "echo '(~d)'" viva.daemon:+handoff-format+)))
                    "a program that reads this format was refused"))
        (ignore-errors (delete-file script))))))

(define-test "a capability put in force is still in force, under the same version, after an upgrade"
  (with-own-store (root)
    (with-paced-cell (cell agent :pause 0.01 :limit 1)
      (with-capability-agent (agent)
        (let* ((created (run-capability-tool "create_capability"
                                             "name" "carried-shout"
                                             "source" "(lambda (input) (string-upcase input))"
                                             "note" "tried before the upgrade"))
               (version (created-version created)))
          (true (integerp version) "no version in ~s" (tool:tool-result-output created))
          (false (tool:tool-result-error-p
                  (run-capability-tool "activate_capability" "version" version)))
          (let ((identity (viva.actor::agent-capability-identity agent))
                (text (actor:evolution-record)))
            (true identity "a session that put a capability in force had no identity")
            (with-restarted-owner
              ;; WITH-RESTARTED-OWNER's owner is the ledger's alone; the carried
              ;; one replaces it, as it does before any session is adopted.
              (sb-concurrency:send-message (viva.actor::evolver-mailbox viva.actor::*evolver*)
                                           (list :shutdown))
              (setf viva.actor::*evolver* nil)
              (actor:adopt-evolution text)
              (let ((carried (make-instance 'paced-agent
                                            :environment (harness:agent-environment agent)
                                            :resource-environment (harness:agent-environment agent))))
                (viva.actor::adopt-capability-identity carried identity)
                (is equal (first identity) (viva.actor::agent-task carried)
                    "the session came back as a different task")
                (let ((kept (gethash version (viva.actor::evolver-sources viva.actor::*evolver*))))
                  (true kept "the candidate's source did not come back")
                  (is equal "tried before the upgrade" (and kept (viva.actor::kept-note kept))))
                (with-capability-agent (carried)
                  (let ((ran (run-capability-tool "call_capability" "name" "carried-shout" "input" "hello")))
                    (false (tool:tool-result-error-p ran)
                           "the carried session could not run what it had in force: ~a"
                           (tool:tool-result-output ran))
                    (true (search "HELLO" (tool:tool-result-output ran)))))))))))))
