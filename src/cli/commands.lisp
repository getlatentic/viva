;;;; The subcommands.

(in-package #:vivarium.cli)

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
  (or (a:when-let ((override (env "VIVARIUM_ROOT"))) (truename override))
      (asdf:system-source-directory "vivarium")))

(defun check-fasl-for (file)
  (merge-pathnames (format nil "vivarium-check-~a.fasl" (pathname-name file))
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
               (asdf:find-component "vivarium/tests" "tests")))
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
  "Load `vivarium/tests`, fetching what it needs.

QUICKLOAD rather than ASDF:LOAD-SYSTEM because the test system depends on
parachute, which nothing else does. The bootstrap quickloads the CLI, so a
clean machine ends up with every dependency except that one -- and ASDF
resolves dependencies but never downloads them, so `vivarium test` on a fresh
clone died with `Component \"parachute\" not found` while `vivarium check`
passed. The first thing a newcomer runs to see whether the install worked was
the one command that could not."
  (funcall (or (find-symbol "QUICKLOAD" "QL") 'asdf:load-system) "vivarium/tests"))

(defun command-soak (parsed)
  "Churn sessions, clients and journals for N minutes and demand a plateau.

Ten green suite runs answer `does it work`; this answers `does it stay flat`,
which is the question a months-long process actually poses. Exits non-zero on
growth."
  (load-test-system)
  (load (merge-pathnames "tests/soak.lisp" (repository-root)))
  (uiop:symbol-call :vivarium.tests :soak
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
                                  (uiop:symbol-call :parachute :test :vivarium.tests))))
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
or VIVARIUM_LOCAL_ENDPOINT.~%")
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
      (format t "~&usage: vivarium compare <before.json> <after.json>~%")
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

(defun workspace-options (parsed)
  (list :model (flag parsed "model")
        :cwd (a:when-let ((cwd (flag parsed "cwd"))) (namestring (truename cwd)))
        :root (a:when-let ((root (flag parsed "root"))) (namestring (truename root)))
        ;; Appended rather than replacing, so a condition that adds one line to
        ;; the prompt differs from the default by exactly that line.
        :extra-prompt (flag parsed "append")
        :extension-directories (a:when-let ((given (flag parsed "extension")))
                                 (list (namestring (truename given))))
        :resume (a:when-let ((given (flag parsed "resume")))
                  (if (string= "true" given) t given))
        :request-limit (flag-integer parsed "limit" 60)
        ;; The arm, as two independent switches, because three configurations
        ;; come out of them and conflating them would collapse two:
        ;;
        ;;   --capabilities on  --door open     arm A, the organism
        ;;   --capabilities on  --door closed   arm B, the same tools refused
        ;;   --capabilities off                 arm C, no live compile at all
        :extra-tools (when (string= "on" (flag parsed "capabilities" "off"))
                       (actor:capability-tools))))

(defun apply-journal-flag (parsed)
  "Point this run's journal -- and so its evolution ledger -- somewhere of its
own. KC6's analysis is a program over one run's ledger, and the checker refuses
a file holding two arms rather than blending them, so a battery sharing the
home journal would produce one unreadable ledger and no results."
  (a:when-let ((given (flag parsed "journal-dir")))
    (let ((directory (if (a:ends-with #\/ given) given (concatenate 'string given "/"))))
      (ensure-directories-exist directory)
      (setf actor:*journal-root* (namestring (truename directory)))))
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

(defun command-shell (parsed)
  "Interactive work in a directory. Reads stdin, so it also runs a script."
  (unless (apply-door-flag parsed) (return-from command-shell 2))
  (apply-journal-flag parsed)
  (let ((console:*colour* (not (string= "false" (flag parsed "colour" "true")))))
    (apply #'console:run-shell (workspace-options parsed))))

(defun command-ipc (parsed)
  "The same agent, driven by another program over stdin and stdout."
  (apply #'console:run-ipc (append (workspace-options parsed)
                                   (list :request-limit (flag-integer parsed "limit" 200)))))

(defun command-daemon (parsed)
  "Start, stop or inspect the organism.

`start` runs in the foreground so a supervisor can own it; `--background`
detaches the accept loop and returns, which is what `vivarium attach` uses when
it finds nobody home."
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
                          (format t "~&running, pid ~a, ~d session~:p~%"
                                  (gethash "pid" ready) (length (gethash "sessions" ready)))
                          (loop for each across (gethash "sessions" ready)
                                do (format t "~&  ~a  ~10a ~a~@[  ~d queued~]~%"
                                           (gethash "id" each) (gethash "state" each)
                                           (gethash "label" each)
                                           (let ((queued (gethash "queued" each)))
                                             (and queued (plusp queued) queued))))
                          ;; Contained failures, said out loud. A daemon that
                          ;; survived four hundred of them and cannot report
                          ;; them looks exactly like one that had none.
                          (let ((reply (daemon:request stream "type" "diagnostics")))
                            (a:when-let ((failures (gethash "failures" reply)))
                              (when (plusp failures)
                                (format t "~&~%~d contained client failure~:p~%" failures)
                                (loop for each across (gethash "recent" reply)
                                      repeat 5
                                      do (format t "~&  ~a in ~a: ~a~%"
                                                 (gethash "condition" each)
                                                 (gethash "where" each)
                                                 (gethash "detail" each))))))
                          0)))))
         ;; Only a refused connection means no daemon. A greeting that will not
         ;; parse is a defect, and calling it `not running` is how one hid.
         (daemon:daemon-error () (format t "~&not running~%") 1)))
      ((string= "start" verb)
       (daemon:serve :background (string= "true" (flag parsed "background" "false"))
                     :announce (lambda (path)
                                 (format t "~&listening on ~a~%" path)
                                 (finish-output)))
       0)
      ((string= "stop" verb)
       (if (daemon:running-p)
           (progn (daemon:with-connection (stream)
                    (read-line stream nil nil)
                    (daemon:request stream "type" "shutdown"))
                  (format t "~&stopped~%") 0)
           (progn (format t "~&not running~%") 1)))
      (t (format t "~&usage: vivarium daemon [status|start|stop]~%") 1))))

(defun ensure-daemon ()
  "Start the organism if it is not already there, and wait for it to answer."
  (unless (daemon:running-p)
    (let ((root (repository-root)))
      (uiop:launch-program (list (namestring (merge-pathnames "bin/vivarium" root))
                                 "daemon" "start")
                           :output nil :error-output nil))
    (loop repeat 100
          until (daemon:running-p)
          do (sleep 0.1)))
  (daemon:running-p))

(defun command-attach (parsed)
  "Talk to a session inside the organism, and leave it running afterwards."
  (unless (ensure-daemon)
    (format t "~&could not start a daemon~%")
    (return-from command-attach 1))
  (let ((cwd (namestring (truename (or (flag parsed "cwd") ".")))))
    (daemon:with-connection (stream)
      (read-line stream nil nil)
      (let* ((wanted (first (args-positional parsed)))
             (reply (if wanted
                        (daemon:request stream "type" "session.attach" "session" wanted
                                        "since" (flag-integer parsed "since" 0))
                        (daemon:request stream "type" "session.start" "cwd" cwd
                                        "model" (flag parsed "model")))))
        (unless (gethash "success" reply)
          (format t "~&~a~%" (gethash "error" reply))
          (return-from command-attach 1))
        (let ((id (gethash "id" (gethash "session" reply))))
          (format t "~&session ~a  (closing this leaves it running)~%~%" id)
          (loop for line = (progn (format t "› ") (finish-output) (read-line *standard-input* nil nil))
                while line
                do (cond ((string= "/detach" (string-trim " " line))
                          (format t "~&detached; ~a is still running~%" id)
                          (return))
                         ((plusp (length (string-trim " " line)))
                          (daemon:request stream "type" "prompt" "session" id "text" line)
                          ;; Events stream in until the turn ends.
                          (loop for reply = (ignore-errors (jzon:parse (read-line stream nil "")))
                                while reply
                                for name = (gethash "event" reply)
                                do (cond ((equal name "model.delta")
                                          (write-string (gethash "text" (gethash "data" reply)))
                                          (force-output))
                                         ((equal name "tool.started")
                                          (format t "~&  · ~a~%"
                                                  (gethash "name" (gethash "call" (gethash "data" reply)))))
                                         ((equal name "turn.completed") (terpri) (return)))))))))
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

(defun command-do (parsed)
  "One prompt, one answer. What a script or a CI job wants."
  (unless (apply-door-flag parsed) (return-from command-do 2))
  (apply-journal-flag parsed)
  (let* ((prompt (or (a:when-let ((file (flag parsed "file")))
                       (uiop:read-file-string file))
                     (format nil "~{~a~^ ~}" (args-positional parsed))))
         (quiet (string= "true" (flag parsed "quiet" "false"))))
    (when (zerop (length (string-trim '(#\Space #\Newline) prompt)))
      (format t "~&usage: vivarium do \"<prompt>\" [--cwd DIR] [--model NAME]~%")
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
               0)
          (a:when-let ((s (harness:agent-session agent)))
            (session:close-session s)))))))
