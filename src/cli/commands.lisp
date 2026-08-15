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

(defun command-check (parsed)
  (declare (ignore parsed))
  (let ((failed 0))
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

(defun command-test (parsed)
  (declare (ignore parsed))
  (asdf:load-system "vivarium/tests")
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
        :request-limit (flag-integer parsed "limit" 60)))

(defun command-shell (parsed)
  "Interactive work in a directory. Reads stdin, so it also runs a script."
  (let ((console:*colour* (not (string= "false" (flag parsed "colour" "true")))))
    (apply #'console:run-shell (workspace-options parsed))))

(defun command-ipc (parsed)
  "The same agent, driven by another program over stdin and stdout."
  (apply #'console:run-ipc (append (workspace-options parsed)
                                   (list :request-limit (flag-integer parsed "limit" 200)))))

(defun command-do (parsed)
  "One prompt, one answer, no session. What a script or a CI job wants."
  (let* ((prompt (or (a:when-let ((file (flag parsed "file")))
                       (uiop:read-file-string file))
                     (format nil "~{~a~^ ~}" (args-positional parsed))))
         (quiet (string= "true" (flag parsed "quiet" "false"))))
    (when (zerop (length (string-trim '(#\Space #\Newline) prompt)))
      (format t "~&usage: vivarium do \"<prompt>\" [--cwd DIR] [--model NAME]~%")
      (return-from command-do 1))
    (let* ((console:*colour* nil)
           (view (console::make-view :stream (if quiet (make-broadcast-stream) *standard-output*))))
      (multiple-value-bind (agent choice complaints)
          (apply #'console:build-agent
                 :listener (console::shell-listener view)
                 :persist nil
                 (workspace-options parsed))
        (declare (ignore choice))
        (dolist (complaint complaints) (format *error-output* "~&! ~a~%" complaint))
        (let ((reply (harness:ask agent prompt)))
          (when quiet (format t "~&~a~%" (or reply "")))
          0)))))
