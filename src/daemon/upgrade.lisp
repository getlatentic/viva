;;;; `viva daemon upgrade`: the daemon becomes a new build, and nothing a person
;;;; can see restarts.
;;;;
;;;; The sessions are held, so running turns finish and nothing new starts.
;;;; Traffic stops at safe points: readers between lines, writers between
;;;; messages, job pumps between reads, the accept loop before its next
;;;; connection. What memory holds is written down, and the process execs the
;;;; program it was started as -- which on disk is now the new build. The new
;;;; image takes over what was written (handoff.lisp) in the same process, with
;;;; the same connections. A step that cannot complete gives everything back.

(in-package #:viva.daemon)

(defstruct (upgrade (:conc-name upgrade-))
  (client nil)
  (request nil)
  (started (get-universal-time))
  (waiting nil)
  (cancelled nil))

(defvar *upgrade* nil "The upgrade in progress, or NIL. Owned by *UPGRADE-LOCK*.")
(defvar *upgrade-lock* (bt:make-lock "viva.upgrade"))

(defparameter +stop-grace+ 15
  "Seconds a connection, a job's pump or a session gets to reach a safe point
once everything is at rest. A client that sent part of a line and stopped is
the usual reason to run out.")

(defparameter +preflight-limit+ 600
  "Seconds the new program gets to say which state it reads. A source checkout
compiles what changed before it can answer, which on a cold cache is minutes.")

(defun upgrade-program ()
  "The program this image was started as, and the argument vector to start it
with again. A saved image is its own runtime; a source run came through
bin/viva, which execs SBCL -- so the pid survives either way."
  (let ((arguments (rest sb-ext:*posix-argv*)))
    (if (equal sb-ext:*runtime-pathname* sb-ext:*core-pathname*)
        (let ((program (namestring sb-ext:*runtime-pathname*)))
          (values program (cons program arguments)))
        (let ((root (sb-posix:getenv "VIVA_ROOT")))
          (unless (and root (plusp (length root)))
            (error 'daemon-error :detail "This daemon cannot find the checkout it runs from."))
          (let ((program (namestring (merge-pathnames "bin/viva"
                                                      (uiop:ensure-directory-pathname root)))))
            (values program (cons program arguments)))))))

(defun preflight (program)
  "NIL when PROGRAM can take this image's state over, or why it cannot.

Asked of the program itself, before anything is held: a build that does not
start, or reads another shape of state, is refused while every session still
runs."
  (handler-case
      (let* ((process (sb-ext:run-program program '("daemon" "handoff")
                                          :output :stream :error nil :input nil
                                          :wait nil :search nil))
             (deadline (+ (get-internal-real-time)
                          (* +preflight-limit+ internal-time-units-per-second))))
        (loop while (and (eq :running (sb-ext:process-status process))
                         (< (get-internal-real-time) deadline))
              do (sleep 0.1))
        (if (eq :running (sb-ext:process-status process))
            (progn (sb-ext:process-kill process sb-unix:sigkill)
                   (sb-ext:process-wait process)
                   (format nil "~a did not answer within ~d seconds" program +preflight-limit+))
            (let ((formats (ignore-errors
                            (with-standard-io-syntax
                              (let ((*read-eval* nil))
                                (read (sb-ext:process-output process) nil nil))))))
              (sb-ext:process-close process)
              (cond ((not (eql 0 (sb-ext:process-exit-code process)))
                     (format nil "~a daemon handoff exited ~a: that build cannot take over a running daemon"
                             program (sb-ext:process-exit-code process)))
                    ((not (and (listp formats) (member +handoff-format+ formats)))
                     (format nil "~a reads handoff format~:p ~{~a~^, ~}, and this daemon writes ~a"
                             program (if (listp formats) formats (list formats)) +handoff-format+))
                    (t nil)))))
    (error (condition) (format nil "~a" condition))))

;;; What is still running

(defun waiting-for ()
  "What the upgrade is still waiting on, in words, or NIL when nothing."
  (or (some #'actor:unsettled-reason (actor:all-cells))
      (and (actor:tasks-running-p) "a task is still running")
      (and (some (lambda (operation)
                   (member (operation:operation-state operation) '(:pending :running :suspended)))
                 (operation:all-operations))
           "a delegated worker is still running")
      (and (plusp (car *shells*)) "a shell command is still running")
      (and (plusp (bt:with-lock-held (*deleting-lock*) (hash-table-count *deleting*)))
           "a session is being deleted")))

(defun live-clients ()
  "The connections that can be carried: registered, with a writer still there."
  (remove-if (lambda (client) (plusp (sb-thread:semaphore-count (client-finished client))))
             (bt:with-lock-held (*clients-lock*) (copy-list *clients*))))

(defun wait-until (predicate &key (timeout +stop-grace+))
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))

;;; The procedure

(define-condition upgrade-abandoned (error)
  ((reason :initarg :reason :reader upgrade-abandoned-reason))
  (:report (lambda (condition stream)
             (write-string (upgrade-abandoned-reason condition) stream))))

(defun abandon (reason &rest arguments)
  (error 'upgrade-abandoned :reason (apply #'format nil reason arguments)))

(defun wait-for-rest (upgrade instance)
  "Hold every session and wait until nothing runs, telling the client that
asked what it is waiting on whenever that changes."
  (let ((told nil) (last-hold 0))
    (loop for reason = (waiting-for)
          while reason
          do (when (upgrade-cancelled upgrade) (abandon "cancelled"))
             (unless (current-p instance) (abandon "the daemon is stopping"))
             (unless (equal reason told)
               (setf told reason
                     (upgrade-waiting upgrade) reason)
               (say (upgrade-client upgrade)
                    (object "type" "upgrade" "detail" (format nil "waiting: ~a" reason))))
             ;; Asserted again, for a session resumed mid-turn after the first.
             (when (> (- (get-internal-real-time) last-hold) internal-time-units-per-second)
               (setf last-hold (get-internal-real-time))
               (actor:hold-sessions))
             (sleep 0.1))
    (setf (upgrade-waiting upgrade) nil)))

(defun stop-traffic (upgrade instance)
  "Stop the accept loop and every reader at a safe point, then make sure nothing
started in the moment before they stopped. Loops back to waiting if it did."
  (loop
    (wait-for-rest upgrade instance)
    (setf *quiescing* t)
    (unless (wait-until (lambda ()
                          (and (not *accepting*)
                               (notany #'client-reading (live-clients)))))
      (abandon "a client did not finish its request within ~d seconds" +stop-grace+))
    ;; A request answered just before its reader stopped may have posted work.
    ;; Every session handles what it was sent, and then the question is asked
    ;; again with nothing left that could post more.
    (dolist (cell (actor:all-cells))
      (unless (actor:settle cell)
        (abandon "~a did not settle" (actor:cell-id cell))))
    (if (waiting-for)
        (setf *quiescing* nil)
        (return))))

(defun hand-over (upgrade instance program arguments)
  "Everything after the traffic has stopped, up to the exec. Returns only by
signalling."
  (unless (jobs:pause-pumps :timeout +stop-grace+)
    (abandon "a background job's output did not pause within ~d seconds" +stop-grace+))
  (let ((clients (live-clients)))
    (dolist (client clients)
      (mailbox:send-message (client-outbound client) :pause))
    (unless (wait-until (lambda () (notany #'client-writing clients)))
      (abandon "a client did not take what it was sent within ~d seconds" +stop-grace+))
    (unless (actor:journal-settled)
      (abandon "the journal did not confirm its writes"))
    (let* ((state (handoff-state instance clients (upgrade-client upgrade)
                                 (object "id" (upgrade-request upgrade))
                                 (upgrade-started upgrade)))
           (path (write-handoff state (handoff-path)))
           (kept (handoff-descriptors state)))
      (handler-bind ((error (lambda (condition)
                              (declare (ignore condition))
                              (ignore-errors (delete-file path))
                              (sb-posix:unsetenv +handoff-variable+)
                              (sb-posix:unsetenv +handoff-descriptors-variable+))))
        ;; Anything this image printed and did not flush would go with it.
        (finish-output *standard-output*)
        (finish-output *error-output*)
        (keep-only-descriptors kept)
        (sb-posix:setenv +handoff-variable+ path 1)
        (sb-posix:setenv +handoff-descriptors-variable+ (format nil "~{~a~^,~}" kept) 1)
        (replace-image program arguments)))))

(defun run-upgrade (upgrade)
  (let ((client (upgrade-client upgrade))
        (instance (bt:with-lock-held (*lock*) *current*)))
    (flet ((refuse (reason)
             (say client (object "id" (or (upgrade-request upgrade) :omit)
                                 "type" "response" "command" "upgrade"
                                 "success" nil "error" reason))))
      (handler-case
          (multiple-value-bind (program arguments) (upgrade-program)
            (say client (object "type" "upgrade" "detail" (format nil "checking ~a" program)))
            (a:when-let ((reason (preflight program)))
              (abandon "~a" reason))
            (unwind-protect
                 (progn
                   (actor:hold-sessions)
                   (stop-traffic upgrade instance)
                   (hand-over upgrade instance program arguments))
              ;; Reached only when the exec did not happen.
              (jobs:resume-pumps)
              (setf *quiescing* nil)
              (actor:release-sessions)))
        (upgrade-abandoned (condition)
          (refuse (format nil "~a; nothing was changed" condition)))
        (error (condition)
          (note-failure "upgrade" condition)
          (refuse (format nil "~a; nothing was changed" condition))))
      (bt:with-lock-held (*upgrade-lock*)
        (when (eq *upgrade* upgrade) (setf *upgrade* nil))))))

(defun request-upgrade (client id)
  "Begin an upgrade for CLIENT, which is answered when it is over -- by the new
image, on this same connection, when it succeeds. NIL when one is already
under way."
  (let ((upgrade (bt:with-lock-held (*upgrade-lock*)
                   (unless *upgrade*
                     (setf *upgrade* (make-upgrade :client client :request id))))))
    (when upgrade
      (bt:make-thread (lambda () (run-upgrade upgrade)) :name "viva-upgrade")
      t)))

(defun cancel-upgrade ()
  "Abandon the upgrade under way while it still waits. T when there was one."
  (bt:with-lock-held (*upgrade-lock*)
    (when *upgrade*
      (setf (upgrade-cancelled *upgrade*) t))))

(defun upgrade-under-way ()
  "What an upgrade under way is waiting on, or NIL when there is none."
  (bt:with-lock-held (*upgrade-lock*)
    (and *upgrade* (or (upgrade-waiting *upgrade*) "starting"))))
