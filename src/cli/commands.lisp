;;;; The subcommands.

(in-package #:viva.cli)

;;; check -- the rot guard
;;;
;;; experiments/e5-wire-format.lisp died at READ time during a refactor and
;;; nothing noticed for an unknown number of sessions, because nothing ever
;;; loaded it. COMPILE-FILE is the right instrument: it catches the reader and
;;; package errors that killed that file, and undefined callees, without
;;; executing the experiment or touching the network.

(defun experiment-files ()
  (sort (directory (merge-pathnames "experiments/*.lisp" (repository-root))) #'string< :key #'namestring))

(defun repository-root ()
  (or (a:when-let ((override (env "VIVA_ROOT"))) (truename override))
      (asdf:system-source-directory "viva")))

(defun check-fasl-for (file)
  (merge-pathnames (format nil "viva-check-~a.fasl" (pathname-name file))
                   (uiop:temporary-directory)))

(defun compile-quietly (file)
  "Returns (values ok-p complaints). Style warnings are reported but do not fail
the check -- an undefined callee in an experiment is usually a genuine tool that
only exists once a model server is up."
  (let ((complaints '()))
    (handler-bind ((warning (lambda (warning)
                              (push (princ-to-string warning) complaints)
                              (a:when-let ((restart (find-restart 'muffle-warning warning)))
                                (invoke-restart restart)))))
      (multiple-value-bind (fasl warnings-p failure-p)
          ;; The fasl goes to the system temp directory and nowhere near
          ;; experiments/. An earlier version used UIOP:TMPIZE-PATHNAME, which
          ;; COPIES the source beside the original -- so each check copied every
          ;; experiment, and the next check globbed the copies and copied those.
          (handler-case (compile-file file :verbose nil :print nil
                                           :output-file (check-fasl-for file))
            (error (condition)
              (return-from compile-quietly
                (values nil (list (princ-to-string condition))))))
        (declare (ignore warnings-p))
        (when fasl (ignore-errors (delete-file fasl)))
        (values (not failure-p) (nreverse complaints))))))

(defun suite-files ()
  "The test files ASDF actually loads.

Not every .lisp under tests/: live-*.lisp and smoke.lisp are standalone scripts
run by hand against a real model, are never loaded together, and may reuse
whatever names they like."
  (handler-case
      (mapcar #'asdf:component-pathname
              (asdf:component-children
               (asdf:find-component "viva/tests" "tests")))
    (error () (directory (merge-pathnames "tests/*.lisp" (repository-root))))))

(defun test-helpers ()
  "Every (DEFUN NAME ...) in the loaded test files, as (name . file)."
  (loop for file in (suite-files)
        append (with-open-file (in file)
                 (loop for line = (read-line in nil nil)
                       while line
                       when (a:starts-with-subseq "(defun " line)
                         collect (cons (subseq line 7 (or (position #\Space line :start 7)
                                                          (position #\( line :start 7)
                                                          (length line)))
                                       (file-namestring file))))))

(defun duplicate-helpers ()
  "Helpers defined in more than one test file.

The test files share one package, so the later definition silently replaces the
earlier and breaks tests in a file it never mentions. Diagnosing that from the
failures is genuinely hard -- each broken test passes in isolation -- and it has
happened twice, so it is checked rather than remembered."
  (let ((seen (make-hash-table :test #'equal)) (clashes '()))
    (loop for (name . file) in (test-helpers)
          do (a:if-let ((first-file (gethash name seen)))
               (unless (string= first-file file)
                 (pushnew (format nil "~a is defined in both ~a and ~a" name first-file file)
                          clashes :test #'string=))
               (setf (gethash name seen) file)))
    (nreverse clashes)))

(defun command-check (parsed)
  (declare (ignore parsed))
  (let ((failed 0))
    (a:when-let ((clashes (duplicate-helpers)))
      (incf failed (length clashes))
      (format t "~&duplicate test helpers:~%")
      (dolist (clash clashes) (format t "~&  ~a~%" clash)))
    (format t "~&checking ~d experiment~:p~%" (length (experiment-files)))
    (dolist (file (experiment-files))
      (multiple-value-bind (ok-p complaints) (compile-quietly file)
        (format t "~&  ~:[FAIL~;ok  ~]  ~a~%" ok-p (file-namestring file))
        (unless ok-p
          (incf failed)
          (dolist (complaint complaints) (format t "~&          ~a~%" complaint)))))
    (format t "~&~%~[all experiments compile~:;~:*~d broken~]~%" failed)
    (if (zerop failed) 0 1)))

;;; test
;;;
;;; Loaded at runtime rather than declared as a dependency: the test system
;;; depends on the CLI (it tests the view models), so declaring it here would be
;;; a cycle.

(defun load-test-system ()
  "Load `viva/tests`, fetching what it needs.

QUICKLOAD rather than ASDF:LOAD-SYSTEM because the test system depends on
parachute, which nothing else does. The bootstrap quickloads the CLI, so a
clean machine ends up with every dependency except that one -- and ASDF
resolves dependencies but never downloads them, so `viva test` on a fresh
clone died with `Component \"parachute\" not found` while `viva check`
passed. The first thing a newcomer runs to see whether the install worked was
the one command that could not."
  (funcall (or (find-symbol "QUICKLOAD" "QL") 'asdf:load-system) "viva/tests"))

(defun command-soak (parsed)
  "Churn sessions, clients and journals for N minutes and demand a plateau.

Ten green suite runs answer `does it work`; this answers `does it stay flat`,
which is the question a months-long process actually poses. Exits non-zero on
growth."
  (load-test-system)
  (load (merge-pathnames "tests/soak.lisp" (repository-root)))
  (uiop:symbol-call :viva.tests :soak
                    :minutes (flag-integer parsed "minutes" 10)))

(defun command-mcp (parsed)
  "Serve the tool registry over MCP on stdio.

Nothing may print to standard output but a reply: the transport is one JSON
object per line, and a stray format statement corrupts the stream for the
client. Diagnostics go to stderr or nowhere."
  (let* ((cwd (namestring (truename (or (flag parsed "cwd") "."))))
         (environment (env:make-local-environment :cwd cwd)))
    (mcp:serve :environment environment
               :directories (harness:registry-directories environment)
               :cwd cwd :project cwd)
    0))

(defun command-test (parsed)
  (declare (ignore parsed))
  (load-test-system)
  ;; The stall tripwire lives in tests/daemon.lisp and arms with the FIRST
  ;; daemon test, not here: a watchdog thread alive from startup broke every
  ;; fork-based trial test, because SBCL refuses to fork a multithreaded
  ;; image -- nine failures from the instrument meant to catch one.
  (let ((status (uiop:symbol-call :parachute :status
                                  (uiop:symbol-call :parachute :test :viva.tests))))
    ;; PARACHUTE:STATUS returns :PASSED or :FAILED, and both are true. Testing
    ;; it for truth -- which is what every invocation in this project did until
    ;; now -- always exits 0, so a red suite could never fail a build.
    (if (eql :passed status) 0 1)))

;;; tasks

(defun command-tasks (parsed)
  (declare (ignore parsed))
  (format t "~&~6a ~16a ~10a ~a~%" "task" "family" "split" "package")
  (dolist (task (tasks:all-tasks))
    (format t "~&~6a ~16a ~10a ~a~%"
            (tasks:task-id task) (tasks:task-family task)
            (tasks:task-split task) (tasks:task-package task)))
  (format t "~&~%~d tasks: ~d train, ~d held-out~%"
          (length (tasks:all-tasks))
          (length (tasks:tasks-in :train))
          (length (tasks:tasks-in :held-out)))
  0)

;;; calibrate

(defun selected-tasks (parsed)
  (a:if-let ((names (flag-list parsed "tasks")))
    (mapcar (lambda (name) (tasks:find-task (a:make-keyword (string-upcase name)))) names)
    (let ((split (flag parsed "split")))
      (if split
          (tasks:tasks-in (a:make-keyword (string-upcase split)))
          (tasks:all-tasks)))))

(defun summarise (attempts)
  (multiple-value-bind (mean lowest highest) (tasks:fraction-summary attempts)
    (cond ((null mean) "err")
          ((= lowest highest) (format nil "~,2f" mean))
          (t (format nil "~,2f~~~,2f-~,2f" mean lowest highest)))))

(defun result-json (task arm attempts)
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "task" table) (string (tasks:task-id task))
          (gethash "arm" table) (arm-label arm)
          (gethash "model" table) (arm-model arm)
          (gethash "runs" table)
          (map 'vector
               (lambda (attempt)
                 (let ((row (make-hash-table :test #'equal)))
                   ;; Absent rather than a placeholder. jzon renders :NULL as
                   ;; the *string* "NULL", which would make a clean run look
                   ;; like it had errored and a crashed case look scored.
                   (setf (gethash "fraction" row) (float (tasks:attempt-fraction attempt))
                         (gethash "requests" row) (tasks:attempt-requests attempt)
                         (gethash "elapsed_ms" row) (tasks:attempt-elapsed-ms attempt)
                         (gethash "cases" row)
                         (let ((cases (make-hash-table :test #'equal)))
                           (dolist (entry (tasks:attempt-scores attempt) cases)
                             (when (cdr entry)
                               (setf (gethash (car entry) cases) (float (cdr entry)))))))
                   (a:when-let ((failure (tasks:attempt-error attempt)))
                     (setf (gethash "error" row) failure))
                   ;; Contamination has to survive into the file. It decides
                   ;; whether a row is usable at all, and a judgement that only
                   ;; ever existed on a terminal cannot be revisited when the
                   ;; detector changes -- which it already has once.
                   (a:when-let ((reached (tasks:attempt-contamination attempt)))
                     (setf (gethash "contamination" row) (coerce reached 'vector)))
                   row))
               attempts))
    table))

(defun command-calibrate (parsed)
  (let* ((arms (arms-named (flag-list parsed "models")))
         (chosen (selected-tasks parsed))
         (repeats (flag-integer parsed "repeats" 3))
         (limit (flag-integer parsed "limit" 12))
         (out (flag parsed "out"))
         (rows '()))
    (when (null arms)
      (format t "~&No arms available. Set OPENROUTER_API_KEY, DEEPSEEK_API_KEY ~
or VIVA_LOCAL_ENDPOINT.~%")
      (return-from command-calibrate 1))
    (format t "~&~d task~:p x ~d arm~:p x ~d repeat~:p~%~%"
            (length chosen) (length arms) repeats)
    ;; Progress per ATTEMPT, not per row. A cell is several minutes of silence
    ;; -- one run took 286 s -- and a table header with nothing under it reads
    ;; as a hang. It was read as one, and the run was killed.
    (format t "~&~8a~{~22a~}~%" "task" (mapcar #'arm-label arms))
    (dolist (task chosen)
      (let ((cells '()))
        (dolist (arm arms)
          (let ((attempts '()))
            (dotimes (run repeats)
              (format *error-output* "~&  ~a ~a run ~d/~d ... " (tasks:task-id task)
                      (arm-label arm) (1+ run) repeats)
              (finish-output *error-output*)
              (let ((attempt (tasks:attempt-task task
                                                 :provider (arm-provider arm)
                                                 :model (arm-model arm)
                                                 :reasoning-effort (arm-effort arm)
                                                 :limit limit)))
                (format *error-output* "~,2f  ~ds  ~d req~@[  CONTAMINATED~]~%"
                        (tasks:attempt-fraction attempt)
                        (round (tasks:attempt-elapsed-ms attempt) 1000)
                        (tasks:attempt-requests attempt)
                        (tasks:attempt-contamination attempt))
                (finish-output *error-output*)
                (push attempt attempts)))
            (setf attempts (nreverse attempts))
            (push (result-json task arm attempts) rows)
            (push (summarise attempts) cells)))
        (format t "~&~8a~{~22a~}~%" (tasks:task-id task) (nreverse cells))
        (finish-output)))
    (when out
      (with-open-file (stream out :direction :output :if-exists :supersede
                                  :if-does-not-exist :create)
        (jzon:stringify (coerce (nreverse rows) 'vector) :stream stream :pretty t))
      (format t "~&~%wrote ~a~%" out))
    0))

;;; compare -- the two-sweep diff that was done by hand

(defun rows-of (path)
  (let ((table (make-hash-table :test #'equal)))
    (map nil (lambda (row)
               (setf (gethash (list (gethash "task" row) (gethash "arm" row)) table)
                     (let ((runs (gethash "runs" row)))
                       (when (plusp (length runs))
                         (/ (reduce #'+ runs :key (lambda (r) (gethash "fraction" r)))
                            (length runs))))))
         (jzon:parse (uiop:read-file-string path)))
    table))

(defun command-compare (parsed)
  (destructuring-bind (&optional before after) (args-positional parsed)
    (unless (and before after)
      (format t "~&usage: viva compare <before.json> <after.json>~%")
      (return-from command-compare 1))
    (let ((old (rows-of before))
          (new (rows-of after))
          (comparable 0) (moved '()))
      (maphash (lambda (key was)
                 (a:when-let ((now (gethash key new)))
                   (when (and was now)
                     (incf comparable)
                     (unless (< (abs (- was now)) 1/1000)
                       (push (format nil "~a/~a ~,2f -> ~,2f" (first key) (second key) was now)
                             moved)))))
               old)
      (format t "~&comparable cells: ~d   changed: ~d (~d%)~%"
              comparable (length moved)
              (if (plusp comparable) (round (* 100 (length moved)) comparable) 0))
      (dolist (line (sort moved #'string<)) (format t "~&  ~a~%" line))
      (format t "~&~%A cell that moves between identical sweeps is the instrument's ~
noise, not a result.~%")
      0)))

;;; The Level 1 entry points
;;;
;;; Three ways into the same object. The library is the product -- these two
;;; subcommands are a hundred lines between them, and that is the point: if
;;; either needed more than wiring, the library would not be reusable.

(defun workspace-options (parsed &key (limit-default 60))
  ;; OPTION, not FLAG: a setting may come from this project's config, the
  ;; machine's, or the environment, and a person who set a model once should
  ;; not type --model on every command for the rest of time.
  ;; OPTION, NOT FLAG. `flag` reads the command line alone, so `capabilities =
  ;; on` in ~/.viva/config was listed by `viva config` and ignored by every run
  ;; that went through here -- while the daemon honoured it. One setting, two
  ;; surfaces, and only one of them reading it is the same fault the resolved
  ;; model already has a test for.
  (multiple-value-bind (names files)
      (extension:declared (option parsed "capabilities" "off"))
   (multiple-value-bind (extra-tools extra-prompts complaints)
      (extension:contributions names)
    (dolist (complaint complaints)
      (format *error-output* "~&! capabilities: ~a~%" complaint))
    (list :model (option parsed "model")
        :cwd (a:when-let ((cwd (flag parsed "cwd"))) (namestring (truename cwd)))
        :root (a:when-let ((root (option parsed "root"))) (namestring (truename root)))
        ;; Appended rather than replacing, so a condition that adds one line to
        ;; the prompt differs from the default by exactly that line. The
        ;; capability block rides here too, as a function: what the organism
        ;; has promoted changes during a run, and a string fixed at startup
        ;; would name what was true before the work began.
        :extension-directories (a:when-let ((given (flag parsed "extension")))
                                 (list (namestring (truename given))))
        :resume (a:when-let ((given (flag parsed "resume")))
                  (if (string= "true" given) t given))
        :request-limit (option-integer parsed "limit" limit-default)
        ;; The arm, as two independent switches, because three configurations
        ;; come out of them and conflating them would collapse two:
        ;;
        ;;   --capabilities on  --door open     arm A, the organism
        ;;   --capabilities on  --door closed   arm B, the same tools refused
        ;;   --capabilities off                 arm C, no live compile at all
        ;;
        ;; NEITHER HALF IS ASSEMBLED HERE ANY MORE. A capability contributes its
        ;; own tools and its own prompt, so an entry point cannot enable one and
        ;; forget to say so -- which is what happened to the door for a while.
        :extra-tools extra-tools
        :extension-files files
        :extra-prompt (append (a:ensure-list (flag parsed "append")) extra-prompts)))))

(defun apply-journal-flag (parsed)
  "Point this run's journal -- its evolution ledger, and the capability store
that ledger accounts for -- somewhere of its own. KC6's analysis is a program
over one run's ledger, and the checker refuses a file holding two arms rather
than blending them, so a battery sharing the home journal would produce one
unreadable ledger and no results.

BOTH, TOGETHER. The ledger says what was promoted and the store holds what was
promoted; a run that moved one and not the other would start by restoring
another run\'s capabilities under its own account of them."
  (a:when-let ((given (flag parsed "journal-dir")))
    (let ((directory (if (a:ends-with #\/ given) given (concatenate 'string given "/"))))
      (ensure-directories-exist directory)
      (let ((root (namestring (truename directory))))
        (setf actor:*journal-root* root
              actor:*capability-root* (concatenate 'string root "capabilities/")))))
  t)

(defun apply-door-flag (parsed)
  "Set the arm's door once, before anything can have created an owner. The
owner announces it into the ledger from its own thread, so a run's arm is a
fact about its evidence rather than about the directory it was written to."
  (let ((door (flag parsed "door" "open")))
    (unless (member door '("open" "closed") :test #'string=)
      (format *error-output* "~&--door takes open or closed, not ~a~%" door)
      (return-from apply-door-flag nil))
    (setf actor:*default-door* (if (string= door "closed") :closed :open))
    t))

(defun colour-wanted-p (parsed)
  "Should this run paint? --colour decides when given; otherwise the terminal.

Defaulting to ON regardless of where output goes is how a log file fills with
escape sequences: `viva shell < script > log` is a supported way to run
this, and it wrote codes nobody could read into a file nobody could grep. The
same test ATTEND already applied to its screen applies here, plus NO_COLOR,
which is what a person redirecting output in a pane will already have set."
  (a:if-let ((given (option parsed "colour")))
    (not (string= "false" given))
    (and (interactive-stream-p *standard-output*)
         (not (env "NO_COLOR")))))

(defun process-alive-p (pid)
  (handler-case (progn (sb-posix:kill pid 0) t)
    (sb-posix:syscall-error (condition)
      (/= (sb-posix:syscall-errno condition) sb-posix:esrch))))

(defun stop-daemon (&key (timeout 15))
  "Ask the running daemon to stop, and wait for its PROCESS to be gone.
Returns (values GONE-P PID).

THE PID, not the socket. The daemon deletes its socket file the moment it stops
listening, so a check on the socket reports it gone while the process is still
finishing -- which is how `stopped` was printed a minute before it was true, and
how a restart could start a second daemon beside the first."
  (let ((pid nil))
    (daemon:with-connection (stream)
      (a:when-let ((line (read-line stream nil nil)))
        (setf pid (ignore-errors (gethash "pid" (jzon:parse line)))))
      (daemon:request stream "type" "shutdown"))
    (values (or (null pid)
                (loop repeat (ceiling timeout 0.05)
                      while (process-alive-p pid)
                      do (sleep 0.05)
                      finally (return (not (process-alive-p pid)))))
            pid)))

(defun command-daemon (parsed)
  "Start, stop or inspect the organism.

`start` runs in the foreground so a supervisor can own it; `--background`
detaches the accept loop and returns, which is what `viva attach` uses when
it finds nobody home."
  ;; Before STATUS, which reports any failure to connect as `not running`.
  (daemon:check-socket-path (daemon:socket-path))
  (let ((verb (or (first (args-positional parsed)) "status")))
    (cond
      ;; No RUNNING-P first: the connection is the question. Asking twice was
      ;; two connections for one answer, with room for the answer to change in
      ;; between.
      ((string= "status" verb)
       (handler-case
           (daemon:with-connection (stream)
             (let ((line (read-line stream nil nil)))
               (cond ((null line) (format t "~&running, but it did not answer~%") 1)
                     (t (let ((ready (jzon:parse line)))
                          ;; `running, pid N` FIRST: scripts read the pid off
                          ;; the front of this line.
                          (format t "~&running, pid ~a, ~d session~:p~@[, ~a~]~%"
                                  (gethash "pid" ready) (length (gethash "sessions" ready))
                                  (gethash "version" ready))
                          (a:when-let ((waiting (gethash "upgrade" ready)))
                            (format t "~&upgrading: ~a~%" waiting))
                          (loop for each across (gethash "sessions" ready)
                                do (format t "~&  ~a  ~10a ~a~@[  ~d queued~]~%"
                                           (gethash "id" each) (gethash "state" each)
                                           (gethash "label" each)
                                           (let ((queued (gethash "queued" each)))
                                             (and queued (plusp queued) queued))))
                          ;; Contained failures, said out loud. A daemon that
                          ;; survived four hundred of them and cannot report
                          ;; them looks exactly like one that had none.
                          ;;
                          ;; Hangups are counted apart and shown only alongside
                          ;; something else, because they are not trouble: every
                          ;; closed pane and every finished client is one, so
                          ;; listing them as failures buries the real ones under
                          ;; ordinary use.
                          (let ((reply (daemon:request stream "type" "diagnostics")))
                            ;; What went wrong, and separately what happened.
                            ;; Both came out under `contained client failures`,
                            ;; so seven restored sessions read as seven faults.
                            ;; KIND, or the older CONDITION, or neither. A
                            ;; daemon outlives the client that talks to it, so
                            ;; a long-running one predates this field -- and
                            ;; printing NIL for it is the client falling over a
                            ;; version gap rather than stepping across it.
                            (flet ((kind-of (each)
                                     (or (gethash "kind" each)
                                         (gethash "condition" each)
                                         "failure")))
                            (let* ((recent (coerce (or (gethash "recent" reply) #()) 'list))
                                   (faults (remove "note" recent :test #'equal :key #'kind-of))
                                   (notes (remove-if-not (lambda (each)
                                                           (equal "note" (kind-of each)))
                                                         recent))
                                   (failures (or (gethash "failures" reply) 0))
                                   (hangups (gethash "hangups" reply)))
                              (when (plusp failures)
                                (format t "~&~%~d contained client failure~:p~@[, ~d hangup~:p~]~%"
                                        failures (and hangups (plusp hangups) hangups))
                                (loop for each in faults repeat 5
                                      do (format t "~&  ~a in ~a: ~a~%"
                                                 (kind-of each)
                                                 (gethash "where" each)
                                                 (gethash "detail" each))))
                              (when notes
                                (format t "~&~%recently:~%")
                                (loop for each in notes repeat 5
                                      do (format t "~&  ~a: ~a~%"
                                                 (gethash "where" each)
                                                 (gethash "detail" each)))))))
                          0)))))
         ;; Only a refused connection means no daemon. A greeting that will not
         ;; parse is a defect, and calling it `not running` is how one hid.
         (daemon:daemon-error () (format t "~&not running~%") 1)))
      ((string= "start" verb)
       (setf daemon:*version* (version))
       (if (string= "true" (flag parsed "background" "false"))
           (start-detached-daemon)
           (progn (daemon:serve :announce (lambda (path)
                                            (format t "~&listening on ~a~%" path)
                                            (finish-output)))
                  ;; The journal, closed before EXIT reaches it. See STOP-JOURNAL.
                  (actor:stop-journal)
                  0)))
      ((string= "restart" verb)
       ;; Stop and start, named as one thing, because `why is my change not
       ;; working` has this as its answer often enough that it should not be
       ;; two commands and a guess.
       (when (daemon:running-p)
         (stop-daemon))
       ;; Sessions come back with the new process; a turn that was running
       ;; does not, and the restored session says so in its own stream.
       (format t "~&running turns end with the old process; sessions come back~%")
       (start-detached-daemon))
      ((string= "upgrade" verb)
       (command-daemon-upgrade parsed))
      ;; What `upgrade` asks of the program a daemon is about to become: the
      ;; handoff formats this build reads, printed readably.
      ((string= "handoff" verb)
       (format t "~s~%" (list daemon:+handoff-format+))
       0)
      ((string= "stop" verb)
       (if (daemon:running-p)
           (multiple-value-bind (gone pid) (stop-daemon)
             (if gone
                 (progn (format t "~&stopped~%") 0)
                 (progn (format t "~&asked pid ~a to stop, and it is still running~%" pid) 1)))
           (progn (format t "~&not running~%") 1)))
      (t (format t "~&usage: viva daemon [status|start|stop|restart|upgrade]~%") 1))))

(defun command-daemon-upgrade (parsed)
  "Make the running daemon this build, without restarting anything.

The answer comes from whichever image finishes the job: the new one, on this
same connection, when the upgrade succeeds, or the old one when it cannot."
  (unless (daemon:running-p)
    (format t "~&not running~%")
    (return-from command-daemon-upgrade 1))
  (daemon:with-connection (stream)
    (let ((from (ignore-errors (gethash "version" (jzon:parse (read-line stream nil ""))))))
      (let ((request (make-hash-table :test #'equal)))
        (setf (gethash "type" request) "upgrade"
              (gethash "id" request) 1)
        (when (string= "true" (flag parsed "cancel" "false"))
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
                      ;; DETACHED, the caller does not wait on somebody's turn:
                      ;; the daemon finishes the upgrade on its own.
                      (when (and (string= "true" (flag parsed "detach" "false"))
                                 (a:starts-with-subseq "waiting" (gethash "detail" reply)))
                        (format t "~&the daemon becomes this build once that is done; ~
nothing restarts~%")
                        (return 0)))
                     ((equal "response" (gethash "type" reply))
                      (return (report-upgrade reply from (string= "true" (flag parsed "cancel" "false"))))))))))

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
        ;; A daemon from before this existed says the command is unknown.
        ((search "Unknown command upgrade" (or (gethash "error" reply) ""))
         (format t "~&This daemon~@[ (~a)~] predates upgrading in place, so this once it has ~
to restart:~%~%  viva daemon restart~%~%Every later update upgrades without restarting ~
anything.~%" from)
         1)
        (t (format t "~&not upgraded: ~a~%" (gethash "error" reply))
           1)))

(defun own-launcher (&optional (runtime sb-ext:*runtime-pathname*)
                              (core sb-ext:*core-pathname*))
  "The program to start a daemon with: THIS one, when this is one file.

A STANDALONE BUILD MUST SPAWN ITSELF. The alternative was a path into the
checkout the image happened to be built in, which is a path that need not exist
on the machine somebody copied the executable to -- and a detached daemon is
the one thing that cannot fall back on the caller, because the caller exits.

A saved executable is its own runtime and its own core; under `sbcl --script`
those are the SBCL binary and sbcl.core, which are not a launcher. So the
question `am I one file?` is exactly the question `can I spawn myself?`.

It is also the difference between one image load and two: starting detached
used to pay this image for the command and the repository's source load for the
daemon, which is most of what a cold start costs."
  (if (equal runtime core)
      (namestring runtime)
      (namestring (merge-pathnames "bin/viva" (repository-root)))))

(defun launch-daemon (&key (command (list (own-launcher) "daemon" "start")) (within 10))
  "Start a daemon in a process of its own and wait for it to answer.

A SEPARATE PROCESS, not a thread. A background daemon has to outlive the shell
that started it, and a thread cannot: `daemon start --background` used to call
SERVE with :BACKGROUND T, which detaches the accept loop into a thread and
returns -- whereupon the CLI exits, taking the thread and the socket with it.
It printed `listening on ...` and left nothing listening. SERVE's own
:BACKGROUND is still right for a caller that IS the long-lived process, which
is how the suite and the soak use it.

A CHILD THAT NEVER ANSWERS IS STOPPED. Reporting `could not start a daemon`
while it runs on leaves a process nobody can reach holding the instance lock,
and every later start is refused on its account."
  (daemon:check-socket-path (daemon:socket-path))
  (unless (daemon:running-p)
    (let ((child (uiop:launch-program command :output nil :error-output nil)))
      (loop repeat (round within 0.1)
            until (daemon:running-p)
            do (sleep 0.1))
      (unless (daemon:running-p)
        (stop-child child))))
  (daemon:running-p))

(defun stop-child (child)
  "End CHILD and reap it. SIGTERM first, so a daemon's unwind removes the socket
and releases the lock it took; SIGKILL if exiting waits on its threads."
  (when (uiop:process-alive-p child)
    (uiop:terminate-process child)
    (loop repeat 50 while (uiop:process-alive-p child) do (sleep 0.1))
    (when (uiop:process-alive-p child)
      (uiop:terminate-process child :urgent t)))
  (uiop:wait-process child))

(defun ensure-daemon ()
  "Start the organism if it is not already there, and wait for it to answer."
  (launch-daemon))

(defun start-detached-daemon ()
  (cond ((daemon:running-p) (format t "~&already running~%") 0)
        ((launch-daemon) (format t "~&listening on ~a~%" (daemon:socket-path)) 0)
        (t (format t "~&could not start a daemon~%") 1)))

(defun interrupt-attached ()
  "Ctrl-C during a session: leave the read, do not do the work here.

NO I/O IN THE HANDLER. The first version sent the cancel from inside it and
SBCL said so -- `starting a select(2) without a timeout while interrupts are
disabled` -- because that is a blocking socket call in a signal context, on the
same socket the main loop may be halfway through reading. It worked, which is
the most dangerous thing an unsound mechanism can do.

So the handler only unwinds. The loop catches it in ordinary context, where
sending a request and draining the reply is just code."
  (if *in-turn*
      (throw 'interrupted t)
      (progn (format *error-output* "~&interrupted~%")
             (finish-output *error-output*)
             (sb-ext:exit :code 130 :abort t))))

(defun connection-lost-p (outcome)
  "Was that a lost connection? If so, say so in words and stop.

`Couldn't write to #<SB-SYS:FD-STREAM for \"socket, peer: ...\">: Broken pipe`
is what a person saw, which names a Lisp object and no cause. The daemon drops
a client that falls too far behind -- deliberately, so one slow reader cannot
make the organism hoard events -- and the next thing that client writes gets
EPIPE. That is a fact about this connection, not about the session, which is
still running and can be rejoined."
  (when (eq :connection-lost outcome)
    (format t "~&~%The organism closed this connection -- usually because this ~
client fell behind~%what the session was producing. The session itself is ~
untouched and still running.~%~%  viva        rejoins it~%  ~
viva daemon status   shows what the organism is doing~%")
    t))

(defun newest-source-time ()
  "The newest write time under src/, or NIL if it cannot be read."
  (ignore-errors
   (loop for file in (directory (merge-pathnames "src/**/*.lisp" (repository-root)))
         maximize (file-write-date file))))

(defun warn-if-stale (greeting)
  "Say so when the running organism predates the code on disk.

A long-lived process keeps the code it was built from. Someone who edits
viva, rebuilds, and reattaches is talking to the OLD one -- and the change
they just made looks like it does not work. It cost a person five hours and a
model that invented a shell workaround for a tool it could not see."
  (a:when-let ((started (and greeting (gethash "started" greeting))))
    (a:when-let ((newest (newest-source-time)))
      (when (> newest started)
        (format t "~&! This organism started before the current code ~
\(~d minute~:p ago).~%  Load it without restarting anything:  viva daemon upgrade~%~%"
                (max 1 (round (- (get-universal-time) started) 60)))))))

(defun current-sequence (stream id)
  "Where this session is now, so attaching replays nothing into the socket."
  (let ((reply (daemon:request stream "type" "session.list")))
    (loop for each across (or (gethash "sessions" reply) #())
          when (equal id (gethash "id" each))
            return (or (gethash "seq" each) 0)
          finally (return 0))))

(defun live-session-here (stream cwd)
  "A session already running in the organism for CWD, or NIL.

Opening a folder that already has a live session and making a SECOND one is
how you end up with four sessions on one directory, none of which knows what
the others did. Rejoining is what a person means by opening their project."
  (let ((reply (daemon:request stream "type" "session.list")))
    (loop for each across (or (gethash "sessions" reply) #())
          when (equal (string-right-trim "/" (or (gethash "label" each) ""))
                      (string-right-trim "/" cwd))
            return (gethash "id" each))))

(defun report-earlier-sessions (cwd)
  "Say what this folder has behind it, the way an editor reopening a workspace
does. Recorded sessions are history on disk, not cells in the organism, so
this only mentions them -- continuing one is `--resume`."
  (a:when-let ((found (ignore-errors (session:list-sessions :cwd cwd :limit 3))))
    (when found
      ;; NOT `--resume continues one`, which is what this said and which is
    ;; false: --resume is read by WORKSPACE-OPTIONS, which shell, do and ipc
    ;; use, and COMMAND-ATTACH builds its own session.start request that never
    ;; looks at it. Advertising a flag the command ignores is worse than
    ;; advertising nothing.
    (format t "~&~d earlier session~:p recorded here. `/continue` carries the ~
most recent~%  one into this session; `viva sessions` lists them all.~%"
            (length found)))))

(defun command-attach (parsed)
  "Talk to a session inside the organism, and leave it running afterwards."
  (unless (ensure-daemon)
    (format t "~&could not start a daemon~%")
    (return-from command-attach 1))
  (let ((cwd (namestring (truename (or (flag parsed "cwd") ".")))))
    (setf *option-model* (option parsed "model"))
    (daemon:with-connection (stream)
      (warn-if-stale (ignore-errors (jzon:parse (read-line stream nil ""))))
      (let* ((wanted (or (first (args-positional parsed))
                         (unless (option-true-p parsed "new")
                           (live-session-here stream cwd))))
             (reply (if wanted
                        ;; FROM NOW by default. Attaching with a `since` makes
                        ;; the daemon replay into the socket, and whatever is
                        ;; not read there is read by the next prompt instead --
                        ;; which is how this file's oldest defect works. --since
                        ;; is still there for a caller that wants the replay and
                        ;; will consume it.
                        (daemon:request stream "type" "session.attach" "session" wanted
                                        "since" (or (flag-integer parsed "since" nil)
                                                    (current-sequence stream wanted)))
                        ;; OPTION, not FLAG. The daemon resolves the model in
                        ;; its own process, where this project's config is not
                        ;; in scope -- so the client, which read it, has to
                        ;; send the answer rather than the flag it was given.
                        (daemon:request stream "type" "session.start" "cwd" cwd
                                        "model" (option parsed "model")
                                        "resume" (or (flag parsed "resume") :omit)))))
        (unless (gethash "success" reply)
          (format t "~&~a~%" (gethash "error" reply))
          (return-from command-attach 1))
        (let ((id (gethash "id" (gethash "session" reply))))
          (sb-sys:enable-interrupt sb-unix:sigint
                                   (lambda (&rest ignored)
                                     (declare (ignore ignored))
                                     (interrupt-attached)))
          (format t "~&session ~a~:[~;  (rejoined)~]  (closing this leaves it running)~%"
                  id (and wanted (not (first (args-positional parsed)))))
          (report-earlier-sessions cwd)
          (when wanted (describe-rejoin reply))
          (format t "~%/help lists what this session answers.~%~%")
          (loop for line = (read-prompt)
                while line
                for trimmed = (string-trim " " line)
                ;; A verb may have moved this client; the loop follows it.
                do (a:when-let ((moved *attached-to*))
                     (setf id moved *attached-to* nil))
                do (cond ((member trimmed '("/detach" "/exit" "/quit" "/q") :test #'string=)
                          (format t "~&detached; ~a is still running~%" id)
                          (return))
                         ;; Every slash line is handled here, including one
                         ;; naming no verb at all. Falling through to the model
                         ;; with a typo'd command is a paid request answered by
                         ;; a guess at what you meant.
                         ((a:starts-with #\/ trimmed)
                          (when (connection-lost-p (run-attached-verb stream id trimmed))
                            (return)))
                         ((plusp (length trimmed))
                          (daemon:request stream "type" "prompt" "session" id "text" line)
                          ;; Shared with /retain: anything that starts a turn
                          ;; drains that turn, or the next reader inherits it.
                          ;;
                          ;; And Ctrl-C lands HERE rather than in the signal
                          ;; handler, so cancelling is ordinary code. The turn
                          ;; is then drained to its terminal event -- an
                          ;; abandoned turn's events would be read by the next
                          ;; prompt, which is the defect this file has now had
                          ;; three times in three places.
                          (when (stream-turn stream)
                            ;; Cancel in ordinary context, drain the turn's own
                            ;; ending, then leave -- deterministically. Standard
                            ;; input does not reliably survive the interrupted
                            ;; read, so returning to the prompt here works
                            ;; sometimes, and a prompt that sometimes answers is
                            ;; worse than one that always says goodbye.
                            ;; Cancel the request and STAY. Ctrl-C means stop
                            ;; what you are doing, not leave -- which is what
                            ;; every REPL has meant by it for forty years. A
                            ;; second one, at a prompt with nothing running, is
                            ;; how you leave.
                            (format t "~&interrupted; stopping the turn~%")
                            (ignore-errors
                             (daemon:request stream "type" "cancel" "session" id))
                            (stream-turn stream)
                            (setf *interrupted-recently* t)))))))
      0)))

(defun command-sessions (parsed)
  "List or search recorded sessions. Scoped to this directory unless --all."
  (let* ((where (unless (string= "true" (flag parsed "all" "false"))
                  (namestring (truename (or (flag parsed "cwd") ".")))))
         (found (a:if-let ((text (flag parsed "search")))
                  (session:search-sessions text :cwd where)
                  (session:list-sessions :cwd where
                                         :limit (flag-integer parsed "limit" 20)))))
    (if (null found)
        (format t "~&no sessions~@[ in ~a~]~%" where)
        (dolist (each found)
          (format t "~&~a  ~3d msg  ~a~%"
                  (session:summary-id each) (session:summary-messages each)
                  (session:summary-opening each))))
    0))

(defun command-trust (parsed)
  "Allow a project's own extensions and tools to be loaded and run.

The shell has had /trust since extensions existed; nothing else did. That was
survivable while trust only gated extensions -- a file a person writes -- and
stopped being survivable when the organism started writing TOOLS into the
project it is working in: it would retain a tool and then be refused it, with
the only remedy in a command that a script, a CI job and `viva do` cannot
reach.

Saying yes is still a decision a person makes about a directory, so this
prints exactly what it is agreeing to."
  (let ((root (namestring (truename (or (first (args-positional parsed))
                                        (flag parsed "cwd") ".")))))
    (if (trust:trusted-p (env:make-local-environment :cwd root) root)
        (format t "~&already trusted: ~a~%" root)
        (progn
          (trust:trust (env:make-local-environment :cwd root) root)
          (format t "~&trusted ~a~%~
Its .viva/extensions/*.lisp will be loaded, and its .viva/tools/ ~
will be run, as you.~%" root)))
    0))

(defun retain-if-asked (parsed agent)
  "Run the retention policy on the finished task, when --retain was passed.

OPT-IN, and the reason is measurement rather than caution. The dogfood found
that retention happens, that what it keeps is good, and that it does NOT yet
pay: +8.2% tokens overall, and split -- mechanical recurring work got cheaper,
judgement work got dearer. Defaulting a measured cost increase onto every user
is exactly what this project refuses to do elsewhere, so the flag is how you
ask for it, and the split is documented rather than averaged away.

Until this existed, HARNESS:REFLECT had no caller outside an experiment
driver: the organism's defining behaviour shipped switched off with no switch."
  (when (option-true-p parsed "retain")
    (handler-case (harness:reflect agent)
      ;; Reflection is an epilogue. A task that succeeded must not be reported
      ;; as failed because the turn after it did not run.
      (error (condition)
        (format *error-output* "~&! retention turn failed: ~a~%" condition)))))

(defun command-do (parsed)
  "One prompt and one answer, or -- with --serve -- a conversation another
program drives over stdin and stdout.

ONE COMMAND, because they were one thing wearing two names: the same agent,
built in this process, reading from something that is not a person. Asking once
and asking repeatedly is the only difference, and that is what a flag is for.

The higher limit belongs to serving rather than appended after the fact:
WORKSPACE-OPTIONS already carries a :REQUEST-LIMIT and in a keyword list the
first value wins, so a 200 appended there was silently 60."
  (unless (apply-door-flag parsed) (return-from command-do 2))
  (apply-journal-flag parsed)
  (when (flag parsed "serve")
    (return-from command-do
      (apply #'console:run-ipc (workspace-options parsed :limit-default 200))))
  (let* ((prompt (prompt-from parsed))
         (quiet (string= "true" (flag parsed "quiet" "false"))))
    (when (blank-prompt-p prompt)
      (format t "~&usage: viva do \"<prompt>\" [--cwd DIR] [--model NAME]~%~
       viva do --file prompt.txt~%~
       echo \"<prompt>\" | viva do~%~
       viva do --serve            keep reading JSON lines until end of input~%")
      (return-from command-do 1))
    (let* ((console:*colour* nil)
           ;; A transcript only on request. It is what lets a run's cost be
           ;; counted from what the agent actually did rather than from what it
           ;; said it did, which is the only claim a summary can make.
           (directory (a:when-let ((given (flag parsed "session-dir")))
                        (uiop:parse-native-namestring
                         (if (a:ends-with #\/ given) given (concatenate 'string given "/")))))
           (view (console::make-view :stream (if quiet (make-broadcast-stream) *standard-output*))))
      (multiple-value-bind (agent choice complaints)
          (apply #'console:build-agent
                 :listener (console::shell-listener view)
                 :persist (and directory t)
                 :session-directory directory
                 (workspace-options parsed))
        (declare (ignore choice))
        (dolist (complaint complaints) (format *error-output* "~&! ~a~%" complaint))
        (unwind-protect
             (let ((reply (harness:ask agent prompt)))
               (when quiet (format t "~&~a~%" (or reply "")))
               (retain-if-asked parsed agent)
               0)
          (a:when-let ((s (harness:agent-session agent)))
            (session:close-session s)))))))
