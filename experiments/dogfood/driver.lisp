;;;; The dogfood driver: one image, the whole corpus, policy on.
;;;;
;;;; Deliberately NOT the KC6 driver: that one serves a family per cell with a
;;;; fresh image, which is right for comparing arms and wrong here. The
;;;; question is what ACCUMULATES, so everything shares one image, one
;;;; workspace root, and one growing .vivarium of skills and tools.

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-truename*)))))
  (push root (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL"))))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :vivarium/cli :silent t))

(in-package #:vivarium.cli)

(defun copy-entries (from to &key exclude)
  "Copy FROM's entries into TO, skipping EXCLUDE. NO SHELL.

A directory copy written as a shell string has lost its find terminator
three times in this project -- eaten once by the Lisp reader and once by sh,
each time silently, once handing a model an empty sandbox it then repaired
by reading sibling runs. The third occurrence is where a patch stops being
the answer: there is no shell here to lose anything."
  (dolist (entry (append (uiop:directory-files from) (uiop:subdirectories from)))
    (let* ((directoryp (uiop:directory-pathname-p entry))
           (name (if directoryp
                     (car (last (pathname-directory entry)))
                     (file-namestring entry))))
      (unless (member name exclude :test #'string=)
        (if directoryp
            (copy-entries entry (ensure-directories-exist
                                 (merge-pathnames (format nil "~a/" name) to)))
            (let ((target (merge-pathnames name to)))
              (uiop:copy-file entry target)
              ;; UIOP:COPY-FILE drops the mode, and ./check must stay runnable.
              (when (logtest #o111 (sb-posix:stat-mode (sb-posix:stat (namestring entry))))
                (sb-posix:chmod (namestring target) #o755))))))))

(defun clear-workspace (workspace)
  "Remove the last job's files, keeping .vivarium -- which is the whole point.
An answer.txt left behind would let a later check pass on an earlier job's
work, which is the quiet way a corpus starts measuring itself."
  (dolist (entry (append (uiop:directory-files workspace)
                         (uiop:subdirectories workspace)))
    (let ((name (if (uiop:directory-pathname-p entry)
                    (car (last (pathname-directory entry)))
                    (file-namestring entry))))
      (unless (string= name ".vivarium")
        (if (uiop:directory-pathname-p entry)
            (uiop:delete-directory-tree entry :validate (constantly t)
                                              :if-does-not-exist :ignore)
            (uiop:delete-file-if-exists entry))))))

(defun job-directories (jobs)
  "Every variant, INTERLEAVED: v1 of each shape, then v2 of each shape."
  (let ((by-variant (make-hash-table :test #'equal)))
    (dolist (shape (sort (uiop:subdirectories jobs) #'string< :key #'namestring))
      (dolist (variant (sort (uiop:subdirectories shape) #'string< :key #'namestring))
        (push variant (gethash (car (last (pathname-directory variant))) by-variant))))
    (loop for key in (sort (loop for k being the hash-keys of by-variant collect k) #'string<)
          append (sort (gethash key by-variant) #'string< :key #'namestring))))

(destructuring-bind (jobs-dir out-dir) (rest sb-ext:*posix-argv*)
  (let* ((jobs (truename (uiop:ensure-directory-pathname jobs-dir)))
         (out (uiop:ensure-directory-pathname
               (uiop:ensure-absolute-pathname
                (uiop:ensure-directory-pathname out-dir) (uiop:getcwd))))
         ;; ONE workspace for the whole corpus: the accumulated .vivarium is
         ;; the thing under measurement.
         (workspace (namestring (ensure-directories-exist (merge-pathnames "workspace/" out)))))
    (ensure-directories-exist out)
    (setf vivarium.actor:*journal-root*
          (namestring (ensure-directories-exist (merge-pathnames "journal/" out))))
    ;; The workspace is the user's own project here, so its tools are trusted.
    (vivarium.trust:trust (env:make-local-environment :cwd workspace) workspace)
    (with-open-file (tsv (merge-pathnames "results.tsv" out)
                         :direction :output :if-exists :supersede)
      (format tsv "position~ashape~avariant~asolved~aseconds~arequests~aprompt~acompletion~%"
              #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab)
      (loop for job in (job-directories jobs)
            for position from 1
            do (let* ((variant (car (last (pathname-directory job))))
                      (shape (car (last (butlast (pathname-directory job)))))
                      (label (format nil "~a-~a" shape variant))
                      ;; ONE directory for every job, not one each. Retention
                      ;; is project-scoped -- REMEMBER writes .vivarium/MEMORY.md
                      ;; relative to cwd, and RESOURCE-DIRECTORIES resolves
                      ;; skills and tools the same way -- so a corpus giving
                      ;; each task its own cwd gives each task its own germline
                      ;; and measures nothing about accumulation. The first run
                      ;; did exactly that and the organism built the same tool
                      ;; twice under two names. One repo, many jobs over time,
                      ;; is what a real week is.
                      (sandbox (ensure-directories-exist workspace))
                      (transcripts (namestring
                                    (ensure-directories-exist
                                     (merge-pathnames (format nil "~a-transcripts/" label) out))))
                      (grade (ensure-directories-exist
                              (merge-pathnames (format nil "~a-grade/" label) out))))
                 ;; The previous job's files go, the germline stays.
                 (clear-workspace sandbox)
                 (copy-entries job sandbox :exclude '("solution"))
                 (when (null (uiop:directory-files sandbox))
                   (error "sandbox arrived empty for ~a" label))
                 (let ((started (get-internal-real-time))
                       (agent (console:build-agent
                               :model "deepseek"
                               ;; cwd is the TASK's folder; root is the shared
                               ;; workspace, so skills and tools accumulate in
                               ;; one place across every job.
                               :cwd (namestring sandbox) :root workspace
                               :request-limit 30
                               :session-directory transcripts :persist t
                               :extra-tools (actor:capability-tools))))
                   (handler-case
                       (harness:ask agent (uiop:read-file-string
                                           (merge-pathnames "PROMPT" job)))
                     (error (c) (format *error-output* "~&~a errored: ~a~%" label c)))
                   ;; Grade BEFORE reflection: reflection edits in the same
                   ;; sandbox and must never un-solve banked work.
                   (copy-entries job grade :exclude '("solution"))
                   (dolist (line (uiop:read-file-lines (merge-pathnames "graded" job)))
                     (let ((produced (merge-pathnames line sandbox)))
                       (when (probe-file produced)
                         (uiop:copy-file produced (merge-pathnames line grade)))))
                   (let ((solved (zerop (nth-value 2 (uiop:run-program
                                                      (list "/bin/sh" "-c" "./check")
                                                      :directory grade :ignore-error-status t))))
                         (seconds (round (- (get-internal-real-time) started)
                                         internal-time-units-per-second)))
                     (when (uiop:getenv "KC6_REFLECT")
                       (handler-case (harness:reflect agent)
                         (error (c) (format *error-output* "~&~a reflection: ~a~%" label c))))
                     (a:when-let ((s (harness:agent-session agent)))
                       (session:close-session s))
                     (format tsv "~d~a~a~a~a~a~d~a~d~a~d~a~d~a~d~%"
                             position #\Tab shape #\Tab variant #\Tab (if solved 1 0)
                             #\Tab seconds #\Tab (harness:agent-requests agent)
                             #\Tab (harness:agent-prompt-tokens agent)
                             #\Tab (harness:agent-completion-tokens agent))
                     (finish-output tsv)
                     (format t "~&~3d ~14a ~:[  --  ~;solved~] ~3ds~%"
                             position label solved seconds))))))
    (format t "~&corpus complete~%")))
