;;;; Processes that are supposed to keep running.
;;;;
;;;; `bash` runs a command to completion with a timeout, which is right for a
;;;; build and wrong for a dev server. Asked to start one, an agent ran
;;;; `npm run dev`, waited out the whole 120 seconds, got a timeout marked as
;;;; an error, RAN IT AGAIN, waited another 120, and then explained to the
;;;; person that it could not. Four minutes, two identical commands, no server.
;;;;
;;;; The model had no mechanism and no way to know it lacked one. Both halves
;;;; matter: a background option nobody is told about is a background option
;;;; nobody uses.
;;;;
;;;; OUTPUT GOES TO A FILE, not a pipe. A pipe nobody drains fills and stops
;;;; the process it was meant to be watching -- a dev server wedged by its own
;;;; logs would be a fine bug to ship on top of the one this fixes.

(in-package #:vivarium.jobs)

(defstruct (job (:conc-name job-))
  (name "" :type string)
  (command "" :type string)
  (process nil)
  (log "" :type string)
  (directory "" :type string)
  ;; :starting :running :exited :stopping. A STATE the job owns, not a question
  ;; asked of the OS at each call -- PROCESS-STATUS can change between the check
  ;; and the act, which is how `stop it` raced `it already exited` and left a
  ;; SIGKILL aimed at a pid the kernel had recycled.
  (state :starting :type keyword)
  ;; Held for the whole of a state change, so two clients stopping the same job
  ;; serialise instead of both deciding it is theirs to kill.
  (lock (bt:make-lock "vivarium.job") :read-only t))

(defvar *jobs* (make-hash-table :test #'equal)
  "Running jobs by name. The daemon is long-lived, so these outlive the turn
that started them -- which is the entire point.")

(defvar *lock* (bt:make-lock "vivarium.jobs"))

(defun log-path (name)
  (env:join-path (uiop:native-namestring (uiop:temporary-directory))
                 (format nil "vivarium-job-~a.log" name)))

(defun mint-name (wanted)
  (bt:with-lock-held (*lock*)
    (if (and wanted (plusp (length wanted)) (not (gethash wanted *jobs*)))
        wanted
        (loop for index from 1
              for candidate = (format nil "~a~d" (or wanted "job") index)
              unless (gethash candidate *jobs*) return candidate))))

(defun pump (job on-output)
  "Read the job's output, writing it to its log and handing it onward.

TWO CONSUMERS, one pipe. The log is what `jobs output` reads afterwards; the
callback is what reaches whoever is watching now. A reader thread rather than
:OUTPUT to a file, because a file cannot be followed without polling it, and
polling is what made a running server invisible until somebody asked.

The thread is the drain as well: an unread pipe fills and stops the process
producing it, which is exactly the dev-server-wedged-by-its-own-logs failure
writing to a file avoided."
  (bt:make-thread
   (lambda ()
     (ignore-errors
      (with-open-file (log (job-log job) :direction :output
                                         :if-exists :supersede :if-does-not-exist :create)
        (let ((from (sb-ext:process-output (job-process job))))
          (loop for character = (read-char from nil nil)
                while character
                do (write-char character log)
                   (force-output log)
                   (when on-output
                     (ignore-errors (funcall on-output (string character)))))))))
   :name (format nil "vivarium-job-~a" (job-name job))))

(defun start (command &key name directory on-output)
  "Start COMMAND and return its JOB, without waiting for it.

ON-OUTPUT, when given, receives the output as it arrives -- so a background
process can be watched rather than polled."
  (let* ((name (mint-name name))
         (log (log-path name))
         (process (sb-ext:run-program
                   "/bin/sh" (list "-c" command)
                   :output :stream :error :output
                   :directory directory :wait nil :search nil)))
    (let ((job (make-job :name name :command command :process process
                         :log log :directory (or directory ""))))
      (pump job on-output)
      (bt:with-lock-held (*lock*) (setf (gethash name *jobs*) job))
      job)))

(defun observe (job)
  "Bring the job's own state up to date with the OS, under its lock.

One place asks PROCESS-STATUS and one place writes the answer down. Everything
else reads the job's state, so a decision and the act that follows it cannot
straddle a change."
  (bt:with-lock-held ((job-lock job))
    (let ((running (eq :running (sb-ext:process-status (job-process job)))))
      (case (job-state job)
        (:stopping (unless running (setf (job-state job) :exited)))
        (:exited)
        (t (setf (job-state job) (if running :running :exited)))))
    (job-state job)))

(defun alive-p (job)
  (member (observe job) '(:starting :running :stopping)))

(defun status-of (job)
  (case (observe job)
    (:running "running")
    (:starting "starting")
    (:stopping "stopping")
    (t (format nil "exited ~a" (or (sb-ext:process-exit-code (job-process job)) "?")))))

(defun all-jobs ()
  (bt:with-lock-held (*lock*)
    (sort (loop for job being the hash-values of *jobs* collect job)
          #'string< :key #'job-name)))

(defun find-job (name)
  (bt:with-lock-held (*lock*) (gethash name *jobs*)))

(defun output-of (job &key (lines 40))
  "The tail of what JOB has printed. Bounded, because a server that has been
up for an hour has an hour of logs and the model has a context window."
  (let ((text (or (ignore-errors (uiop:read-file-string (job-log job))) "")))
    (if (zerop (length text))
        "(nothing yet)"
        (let ((all (uiop:split-string (string-right-trim '(#\Newline) text)
                                      :separator '(#\Newline))))
          (format nil "~{~a~^~%~}"
                  (if (> (length all) lines) (last all lines) all))))))

(defun stop (job)
  "Kill JOB and everything it started.

The process group, not the process. `sh -c \"npm run dev\"` is a shell whose
child is the server, and killing only the shell leaves the server holding the
port -- which looks exactly like the stop having failed."
  ;; Claim the stop, once. Whichever client gets here first moves the job to
  ;; :STOPPING and does the work; a second one finds it already stopping and
  ;; does not send a second signal at a pid that may by then be somebody else's.
  (let ((mine (bt:with-lock-held ((job-lock job))
                (when (member (job-state job) '(:starting :running))
                  (setf (job-state job) :stopping)
                  t))))
    (declare (ignorable mine)))
  (when (alive-p job)
    (let ((pid (sb-ext:process-pid (job-process job))))
      (ignore-errors (sb-posix:killpg pid sb-unix:sigterm))
      (ignore-errors (sb-ext:process-kill (job-process job) sb-unix:sigterm)))
    (loop repeat 30 while (alive-p job) do (sleep 0.1))
    (when (alive-p job)
      (ignore-errors (sb-ext:process-kill (job-process job) sb-unix:sigkill))))
  (sb-ext:process-wait (job-process job) t)
  (bt:with-lock-held (*lock*) (remhash (job-name job) *jobs*))
  t)

(defun stop-all ()
  "Stop every job. Called when the process that started them is going away.

Without this a `daemon restart` -- the command a person is now told to run
when their code is stale -- leaves every dev server it ever started alive,
holding ports, with the only record of them in a process that no longer
exists. Pi tracks detached child pids for exactly this reason and kills the
tree on SIGHUP/SIGTERM; the same problem arrives here through a longer-lived
process, so it matters more rather than less."
  (let ((stopped 0))
    (dolist (job (all-jobs) stopped)
      (when (ignore-errors (stop job)) (incf stopped)))))

;;; Services: a process the germline declares
;;;
;;; The retention router's fourth shape. Tiers 1-3 are a note, a code-carrying
;;; skill, and a registered tool -- knowledge, a transformation, and a callable.
;;; A service is none of those: it is something that should be RUNNING while
;;; work happens here. The organism already notices it starts the same dev
;;; server every session; until now the most it could do about that was write a
;;; note saying so.
;;;
;;; One file per service, holding the command line. Not JSON, not KEY=VALUE:
;;; there is exactly one field, and a format with one field is a filename and
;;; its contents. `cat .viva/services/dev` tells you everything.

(defun services-directory (cwd)
  (env:project-path cwd "services"))

(defun declared (environment cwd)
  "Every service this project declares, as (NAME . COMMAND)."
  (loop for info in (or (ignore-errors
                         (env:list-directory environment (services-directory cwd)))
                        '())
        when (eq :file (env:info-kind info))
          collect (cons (env:info-name info)
                        (string-trim '(#\Space #\Newline #\Tab)
                                     (or (ignore-errors
                                          (env:read-text environment (env:info-path info)))
                                         "")))
            into found
        finally (return (remove-if (lambda (pair) (zerop (length (cdr pair)))) found))))

(defun start-declared (environment cwd &key on-output)
  "Start any declared service not already running. Returns what it started.

NOT AUTOMATIC ON ARRIVAL, and that is deliberate: running a project's own
commands is the same decision as running its tools, and the caller is the one
that has to have asked. Nothing here consults trust because nothing here starts
anything on its own."
  (loop for (name . command) in (declared environment cwd)
        unless (a:when-let ((existing (find-job name))) (alive-p existing))
          collect (progn (start command :name name :directory cwd :on-output on-output)
                         (cons name command))))
