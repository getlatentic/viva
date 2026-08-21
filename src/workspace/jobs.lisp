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
  (directory "" :type string))

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

(defun start (command &key name directory)
  "Start COMMAND and return its JOB, without waiting for it."
  (let* ((name (mint-name name))
         (log (log-path name))
         (process (sb-ext:run-program
                   "/bin/sh" (list "-c" command)
                   :output log :error :output :if-output-exists :supersede
                   :directory directory :wait nil :search nil)))
    (let ((job (make-job :name name :command command :process process
                         :log log :directory (or directory ""))))
      (bt:with-lock-held (*lock*) (setf (gethash name *jobs*) job))
      job)))

(defun alive-p (job)
  (eq :running (sb-ext:process-status (job-process job))))

(defun status-of (job)
  (if (alive-p job)
      "running"
      (format nil "exited ~a" (or (sb-ext:process-exit-code (job-process job)) "?"))))

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
