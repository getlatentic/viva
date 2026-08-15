;;;; BASH.
;;;;
;;;; The escape hatch, and deliberately the last tool in the list. Everything a
;;;; shell can do that the other tools already do -- reading, listing, searching
;;;; -- it does with worse output limits and no ignore rules, so the description
;;;; says so rather than leaving the model to find out one 40,000-line result at
;;;; a time.

(in-package #:vivarium.workspace)

(defvar *bash-timeout* 120)

(defun run-bash (command &key (timeout *bash-timeout*))
  (multiple-value-bind (status output) (env:exec (environment) command :timeout timeout)
    (let* ((cut (bound:truncate-head output))
           (text (cond ((zerop (length (string-trim '(#\Space #\Newline #\Tab) output)))
                        "(no output)")
                       ((bound:truncation-cut-p cut)
                        (format nil "~a~%~%[Output truncated at ~d lines. Narrow the ~
command, or write it to a file and read that.]"
                                (bound:truncation-text cut) (bound:truncation-lines cut)))
                       (t (bound:truncation-text cut)))))
      (values text status))))

(tool:define-tool bash-tool (args context)
  :name "bash"
  :description "Run a shell command and return its output, stdout and stderr
interleaved. Use it to run builds, tests and version control. For reading,
listing and searching prefer read, ls, find and grep -- they bound their output
and honour .gitignore, which a shell command does not."
  :parameters (("command" :string "The command to run" :required-p t)
               ("timeout" :integer "Seconds before the command is killed (default 120)" :required-p nil))
  (multiple-value-bind (text status)
      (run-bash (gethash "command" args)
                :timeout (or (gethash "timeout" args) *bash-timeout*))
    (cond ((eql 0 status) text)
          ((eq :timeout status)
           (tool:make-tool-result :output text :error-p t))
          (t (tool:make-tool-result :output (format nil "exit ~a~%~a" status text)
                                    :error-p t)))))

(defun tool-set ()
  "The ordinary-work tool set, in the order the system prompt lists it."
  (append (file-tools) (search-tools) (list bash-tool)))
