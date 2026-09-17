;;;; Bringing the running daemon onto this build.
;;;;
;;;; Updating viva is running the installer again, and nothing after it: the
;;;; installer asks the running daemon to become the build it just installed.
;;;; A daemon new enough replaces its image in the same process and restarts
;;;; nothing (src/daemon/upgrade.lisp). One from before that existed cannot, so
;;;; it restarts once, by itself, at the first moment no turn is running.

(in-package #:viva.cli)

(defun command-daemon-upgrade (parsed)
  "Make the running daemon this build.

The answer comes from whichever image finishes the job: the new one, on this
same connection, when the upgrade succeeds, or the old one when it cannot."
  (unless (daemon:running-p)
    (format t "~&not running~%")
    (return-from command-daemon-upgrade 1))
  (let ((detach (string= "true" (flag parsed "detach" "false")))
        (cancel (string= "true" (flag parsed "cancel" "false"))))
    (daemon:with-connection (stream)
      (let ((from (ignore-errors (gethash "version" (jzon:parse (read-line stream nil ""))))))
        (when (and (string= "true" (flag parsed "if-changed" "false"))
                   (equal from (version)))
          (format t "~&the daemon already runs ~a~%" from)
          (return-from command-daemon-upgrade 0))
        (let ((request (make-hash-table :test #'equal)))
          (setf (gethash "type" request) "upgrade"
                (gethash "id" request) 1)
          (when cancel
            (setf (gethash "cancel" request) t))
          (write-line (jzon:stringify request) stream)
          (force-output stream))
        (loop for line = (read-line stream nil nil)
              for reply = (and line (ignore-errors (jzon:parse line)))
              do (cond ((null line)
                        (format t "~&the daemon closed the connection before answering~%")
                        (return 1))
                       ((not (hash-table-p reply)))
                       ((equal "upgrade" (gethash "type" reply))
                        (format t "~&  ~a~%" (gethash "detail" reply))
                        (finish-output)
                        ;; DETACHED, the caller does not wait on somebody's
                        ;; turn: the daemon finishes the upgrade on its own.
                        (when (and detach (a:starts-with-subseq "waiting" (gethash "detail" reply)))
                          (format t "~&the daemon becomes this build once that is done; ~
nothing restarts~%")
                          (return 0)))
                       ((equal "response" (gethash "type" reply))
                        (return (if (search "Unknown command upgrade" (or (gethash "error" reply) ""))
                                    (switch-old-daemon from detach)
                                    (report-upgrade reply from cancel))))))))))

(defun report-upgrade (reply from cancelling)
  (cond ((and cancelling (gethash "success" reply))
         (format t "~&cancelled; the daemon carries on as it was~%")
         0)
        ((gethash "success" reply)
         (format t "~&~a -> ~a in ~ds, pid ~a: ~d session~:p and ~d job~:p carried over, ~
nothing restarted~%"
                 (or (gethash "from" reply) from "?") (gethash "to" reply)
                 (gethash "seconds" reply) (gethash "pid" reply)
                 (gethash "sessions" reply) (gethash "jobs" reply))
         0)
        (t (format t "~&not upgraded: ~a~%" (gethash "error" reply))
           1)))

;;; A daemon from before upgrading in place

(defun switch-old-daemon (from detach)
  "Bring a daemon too old to upgrade in place onto this build: a restart, the
one it will ever need, at the first moment it runs no turn.

DETACHED FOR AN INSTALLER, which must not wait on somebody's turn and may be
gone -- its terminal with it -- before the turn ends."
  (format t "~&This daemon~@[ (~a)~] is from before upgrading in place, so it ~
restarts once, by itself, when no turn is running. Sessions come back; ~
background jobs it started stop. Every later update restarts nothing.~%" from)
  (finish-output)
  (cond (detach
         (uiop:launch-program (list "/bin/sh" "-c"
                                    "nohup \"$0\" daemon restart --when-idle >/dev/null 2>&1 &"
                                    (own-launcher))
                              :input nil :output nil :error-output nil)
         0)
        (t (restart-when-idle))))

(defun sessions-idle-p (sessions)
  "Do SESSIONS, as `session.list` describes them, run no turn and hold no
prompt? A stuck session counts: restarting is what resolves one."
  (every (lambda (session)
           (let ((state (gethash "state" session)))
             (or (equal "stuck" state)
                 (and (member state '("idle" "suspended") :test #'equal)
                      (null (gethash "turn" session))
                      (member (gethash "queued" session) '(nil 0))))))
         (coerce (or sessions #()) 'list)))

(defun daemon-idle-p ()
  "Is the running daemon idle? Asked through `session.list`, which every daemon
answers, however old. NIL when it cannot be asked."
  (handler-case
      (daemon:with-connection (stream)
        (read-line stream nil nil)
        (sessions-idle-p (gethash "sessions" (daemon:request stream "type" "session.list"))))
    (error () nil)))

(defun restart-when-idle (&key (poll 1))
  "Restart the daemon as this build at the first moment it is idle. Nothing to
do once no daemon runs: the next one starts on this build anyway."
  (loop
    (unless (daemon:running-p)
      (return-from restart-when-idle 0))
    (when (daemon-idle-p)
      (return))
    (sleep poll))
  (stop-daemon)
  (if (launch-daemon)
      (progn (format t "~&restarted as ~a~%" (version)) 0)
      (progn (format t "~&could not start a daemon~%") 1)))
