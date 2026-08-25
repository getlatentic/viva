;;;; LS, FIND, GREP -- how the agent discovers what it is working on.
;;;;
;;;; All three share one traversal, and the traversal honours ignore files. That
;;;; is not a nicety: an agent that finds 40,000 paths under node_modules has
;;;; not been given a slow answer, it has been given a wrong one, and the cost
;;;; lands in a context window that was supposed to hold the actual work.

(in-package #:viva.workspace)

(defvar *excluded-paths* '()
  "Absolute paths a walk must not descend into, beyond the ignore rules.

Bound by the harness to wherever the live session is being written when that
happens to be inside the working tree. Without it a search finds the transcript
of the search, and an agent has been observed delegating a worker to
investigate its own conversation.")

(defun excluded-p (path)
  (some (lambda (each) (a:starts-with-subseq each path)) *excluded-paths*))

(defun walk (root visit &key ignores)
  "Call VISIT with (INFO RELATIVE-PATH) for every non-ignored file under ROOT.
VISIT returning :STOP ends the walk. Symlinks are reported, never followed."
  (let ((ignores (or ignores (glob:make-ignore-set)))
        (base (env:absolute-path (environment) root)))
    (catch 'walk
      (labels ((descend (directory prefix)
                 (a:when-let ((rules (ignore-errors
                                      (env:read-text (environment)
                                                     (env:join-path directory ".gitignore")))))
                   (glob:add-ignore-file ignores rules prefix))
                 (dolist (info (sort (env:list-directory (environment) directory)
                                     #'string< :key #'env:info-name))
                   (let* ((relative (concatenate 'string prefix (env:info-name info)))
                          (directory-p (eq :directory (env:info-kind info))))
                     (unless (or (glob:ignored-p ignores relative directory-p)
                                 (excluded-p (env:info-path info)))
                       (if directory-p
                           (descend (env:info-path info) (concatenate 'string relative "/"))
                           (when (eq :stop (funcall visit info relative))
                             (throw 'walk :stopped))))))))
        (descend base "")
        nil))))

(defun report-truncation (shown limit noun)
  (if (>= shown limit)
      (format nil "~%[Stopped at ~d ~a. Narrow the search to see the rest.]" limit noun)
      ""))

;;; ls

(defparameter +ls-limit+ 500)

(defun list-files (path &key (limit +ls-limit+))
  (let* ((resolved (env:absolute-path (environment) (or path ".")))
         (entries (sort (env:list-directory (environment) resolved)
                        #'string< :key #'env:info-name))
         (shown (subseq entries 0 (min limit (length entries)))))
    (if (null entries)
        (format nil "~a is empty." (display-path resolved))
        (format nil "~{~a~%~}~a"
                (mapcar (lambda (info)
                          (format nil "~a~:[~;/~]" (env:info-name info)
                                  (eq :directory (env:info-kind info))))
                        shown)
                (report-truncation (length shown) limit "entries")))))

(tool:define-tool ls-tool (args context)
  :name "ls"
  :description "List the contents of a directory, sorted, dotfiles included, with
a trailing slash on directories."
  :parameters (("path" :string "Directory to list. Omit for the working directory." :required-p nil)
               ("limit" :integer "Maximum entries to return (default 500)" :required-p nil))
  (list-files (gethash "path" args) :limit (or (gethash "limit" args) +ls-limit+)))

;;; find

(defparameter +find-limit+ 1000)

(defun find-files (pattern &key path (limit +find-limit+))
  (let ((found '()) (count 0))
    (walk (or path ".")
          (lambda (info relative)
            (declare (ignore info))
            (when (glob:matches-p pattern relative)
              (push relative found)
              (when (>= (incf count) limit) :stop))))
    (if (null found)
        (format nil "No files match ~a." pattern)
        (format nil "~{~a~%~}~a" (nreverse found)
                (report-truncation count limit "results")))))

(tool:define-tool find-tool (args context)
  :name "find"
  :description "Find files by glob pattern, e.g. \"*.lisp\" or \"src/**/*.test.ts\".
A pattern with no slash matches on the file name at any depth. Paths are returned
relative to the search directory, and .gitignore is respected."
  :parameters (("pattern" :string "Glob to match, e.g. \"**/*.json\"" :required-p t)
               ("path" :string "Directory to search. Omit for the working directory." :required-p nil)
               ("limit" :integer "Maximum results (default 1000)" :required-p nil))
  (find-files (gethash "pattern" args)
              :path (gethash "path" args)
              :limit (or (gethash "limit" args) +find-limit+)))

;;; grep

(defparameter +grep-limit+ 100)
(defparameter +grep-line-limit+ 500
  "Longest match line echoed back. A minified bundle is one line and would
otherwise be the whole result.")

(defun binary-p (text)
  (find #\Nul text :end (min 8192 (length text))))

(defun clip (line)
  (if (> (length line) +grep-line-limit+)
      (format nil "~a... [+~d chars]" (subseq line 0 +grep-line-limit+)
              (- (length line) +grep-line-limit+))
      line))

(defun matching-lines (scanner lines)
  (loop for line in lines
        for number from 1
        when (cl-ppcre:scan scanner line) collect number))

(defun render-match (out relative lines number context)
  (loop for index from (max 1 (- number context)) below number
        do (format out "~a-~d-~a~%" relative index (clip (nth (1- index) lines))))
  (format out "~a:~d:~a~%" relative number (clip (nth (1- number) lines)))
  (loop for index from (1+ number) to (min (length lines) (+ number context))
        do (format out "~a-~d-~a~%" relative index (clip (nth (1- index) lines)))))

(defun grep-scanner (pattern literal case-insensitive)
  (cl-ppcre:create-scanner (if literal (cl-ppcre:quote-meta-chars pattern) pattern)
                           :case-insensitive-mode (and case-insensitive t)))

(defun search-files (pattern &key path file-glob ignore-case literal (context 0)
                               (limit +grep-limit+))
  (let ((scanner (handler-case (grep-scanner pattern literal ignore-case)
                   (error (condition)
                     (error "~a is not a valid regular expression: ~a. ~
Pass literal=true to search for it as plain text."
                            pattern condition))))
        (output (make-string-output-stream))
        (files 0) (matches 0))
    (flet ((scan-file (relative absolute)
             (let ((text (ignore-errors (env:read-text (environment) absolute))))
               (when (and text (not (binary-p text)))
                 (let* ((lines (uiop:split-string text :separator (string #\Newline)))
                        (hits (matching-lines scanner lines)))
                   (when hits (incf files))
                   (dolist (number hits)
                     (render-match output relative lines number context)
                     (when (>= (incf matches) limit) (return-from scan-file :stop))))))))
      (let* ((target (env:absolute-path (environment) (or path ".")))
             (info (env:file-info (environment) target)))
        (cond ((null info) (error "No such path: ~a" (or path ".")))
              ((eq :directory (env:info-kind info))
               (walk target
                     (lambda (entry relative)
                       (when (or (null file-glob) (glob:matches-p file-glob relative))
                         (scan-file relative (env:info-path entry))))))
              (t (scan-file (display-path target) target)))))
    (let ((text (get-output-stream-string output)))
      (if (zerop matches)
          (format nil "No matches for ~a." pattern)
          (format nil "~a~%~d match~:p in ~d file~:p.~a"
                  text matches files (report-truncation matches limit "matches"))))))

(tool:define-tool grep-tool (args context)
  :name "grep"
  :description "Search file contents by regular expression. Returns
path:line:text for each match. Respects .gitignore and skips binary files."
  :parameters (("pattern" :string "Regular expression, or plain text with literal=true" :required-p t)
               ("path" :string "File or directory to search. Omit for the working directory." :required-p nil)
               ("glob" :string "Only search files matching this glob, e.g. \"*.lisp\"" :required-p nil)
               ("ignore_case" :boolean "Case-insensitive search" :required-p nil)
               ("literal" :boolean "Treat the pattern as plain text, not a regex" :required-p nil)
               ("context" :integer "Lines of context around each match (default 0)" :required-p nil)
               ("limit" :integer "Maximum matches (default 100)" :required-p nil))
  (search-files (gethash "pattern" args)
                :path (gethash "path" args)
                :file-glob (gethash "glob" args)
                :ignore-case (gethash "ignore_case" args)
                :literal (gethash "literal" args)
                :context (or (gethash "context" args) 0)
                :limit (or (gethash "limit" args) +grep-limit+)))

(defun search-tools ()
  (list ls-tool find-tool grep-tool))
