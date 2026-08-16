;;;; One KC6 cell: one family x one arm x one repeat, five tasks in sequence
;;;; INSIDE ONE IMAGE. The process boundary is the run, not the task, because
;;;; arm A's retention is compiled function objects in the evolver -- a
;;;; per-task process would discard between tasks the very thing the
;;;; experiment measures. The organism shape, load-bearing.
;;;;
;;;;   sbcl --script driver.lisp FAMILY-DIR ARM(A|B|C) OUT-DIR
;;;;
;;;; Emits OUT-DIR/tasks.tsv: position task solved seconds. Transcripts land
;;;; in OUT-DIR/tN-transcripts/, the run's own ledger in OUT-DIR/journal/.
;;;; Grading is pristine-plus-outputs: fresh task copy, graded paths
;;;; overlaid, ./check run there.

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:pathname-parent-directory-pathname
     (uiop:pathname-directory-pathname *load-truename*)))))

(push *root* (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :vivarium/cli :silent t))

(destructuring-bind (family-dir arm out-dir) (rest sb-ext:*posix-argv*)
  ;; AN is pre-check 2's arm: arm A's exact configuration -- tools present,
  ;; door open -- plus a policy instruction never to use them. It isolates
  ;; the machinery's presence-tax from its use.
  (let* ((family (uiop:ensure-directory-pathname family-dir))
         (out (uiop:ensure-directory-pathname out-dir))
         (capabilities (member arm '("A" "B" "AN") :test #'string=)))
    (ensure-directories-exist out)

    ;; The arm, before any owner exists.
    (setf vivarium.actor:*journal-root*
          (namestring (ensure-directories-exist (merge-pathnames "journal/" out))))
    (setf vivarium.actor:*default-door* (if (string= arm "B") :closed :open))

    (let ((tasks (sort (remove-if-not
                        (lambda (path)
                          (let ((name (car (last (pathname-directory path)))))
                            (and (> (length name) 1) (char= #\t (char name 0)))))
                        (uiop:subdirectories family))
                       #'string< :key #'namestring))
          (carried nil))
      (with-open-file (tsv (merge-pathnames "tasks.tsv" out)
                           :direction :output :if-exists :supersede)
        (format tsv "position	task	solved	seconds~%")
        (loop for task-dir in tasks
              for position from 1
              do (let* ((task (car (last (pathname-directory task-dir))))
                        (sandbox (ensure-directories-exist
                                  (merge-pathnames (format nil "~a-sandbox/" task) out)))
                        (transcripts (namestring
                                      (ensure-directories-exist
                                       (merge-pathnames (format nil "~a-transcripts/" task) out))))
                        (grade (ensure-directories-exist
                                (merge-pathnames (format nil "~a-grade/" task) out))))
                   ;; The sandbox: everything but the reference solution.
                   (uiop:run-program
                    (list "/bin/sh" "-c"
                          (format nil "cd ~a && find . -mindepth 1 -maxdepth 1 ! -name solution -exec cp -R {} ~a \\;"
                                  (namestring task-dir) (namestring sandbox))))
                   ;; Arm-agnostic carry of workspace memory between tasks.
                   (when carried
                     (uiop:run-program
                      (list "/bin/sh" "-c"
                            (format nil "[ -d ~a/.vivarium ] && cp -R ~a/.vivarium ~a/ || true"
                                    carried carried (namestring sandbox)))))
                   (let ((started (get-internal-real-time))
                         (agent (vivarium.console:build-agent
                                 :model "deepseek"
                                 :cwd (namestring sandbox)
                                 :root (namestring sandbox)
                                 :request-limit 30
                                 :session-directory transcripts
                                 :persist t
                                 :extra-prompt (when (string= arm "AN")
                                                 "Policy for this run: never create, activate, or promote capabilities. Solve every task with the ordinary tools only.")
                                 :extra-tools (when capabilities
                                                (vivarium.actor:capability-tools)))))
                     (handler-case
                         (vivarium.harness:ask
                          agent (uiop:read-file-string (merge-pathnames "PROMPT" task-dir)))
                       (error (condition)
                         (format *error-output* "~&~a errored: ~a~%" task condition)))
                     (alexandria:when-let ((session (vivarium.harness:agent-session agent)))
                       (vivarium.session:close-session session))
                     ;; Grade: pristine task, graded outputs overlaid.
                     (uiop:run-program
                      (list "/bin/sh" "-c"
                            (format nil "cd ~a && find . -mindepth 1 -maxdepth 1 ! -name solution -exec cp -R {} ~a \\;"
                                    (namestring task-dir) (namestring grade))))
                     (dolist (line (uiop:read-file-lines (merge-pathnames "graded" task-dir)))
                       (let ((produced (merge-pathnames line sandbox)))
                         (when (probe-file produced)
                           (uiop:copy-file produced (merge-pathnames line grade)))))
                     (let* ((solved (zerop (nth-value 2 (uiop:run-program
                                                         (list "/bin/sh" "-c" "./check")
                                                         :directory grade
                                                         :ignore-error-status t))))
                            (seconds (round (- (get-internal-real-time) started)
                                            internal-time-units-per-second)))
                       (format tsv "~d	~a	~d	~d~%" position task (if solved 1 0) seconds)
                       (finish-output tsv)
                       (format t "~&  ~a ~a: ~:[  --  ~;solved~]  ~ds~%"
                               arm task solved seconds)))
                   (setf carried (namestring sandbox))))))
    (format t "~&cell done: ~a ~a~%" (car (last (pathname-directory family))) arm)))
