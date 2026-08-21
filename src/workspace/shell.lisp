;;;; BASH.
;;;;
;;;; The escape hatch, and deliberately the last tool in the list. Everything a
;;;; shell can do that the other tools already do -- reading, listing, searching
;;;; -- it does with worse output limits and no ignore rules, so the description
;;;; says so rather than leaving the model to find out one 40,000-line result at
;;;; a time.

(in-package #:vivarium.workspace)

(defvar *bash-timeout* 120)

(defvar *on-output* nil
  "Called with each piece of a running command's output, or NIL.

Bound by the agent that is watching, so RUN-BASH does not have to know who is
looking. Collecting everything and returning at the end is why a slow command
read as a hang -- two minutes of nothing, then all of it at once.")

(defun run-bash (command &key (timeout *bash-timeout*))
  (multiple-value-bind (status output)
      (env:exec (environment) command :timeout timeout :on-output *on-output*)
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
and honour .gitignore, which a shell command does not.

THIS WAITS FOR THE COMMAND TO FINISH. For anything that is meant to keep
running -- a dev server, a watcher, a database -- pass background true, which
starts it and returns at once. Running a server here instead just burns the
timeout and kills it."
  :parameters (("command" :string "The command to run" :required-p t)
               ("background" :boolean "Start it and return immediately, for a
process meant to keep running. Its output goes to a log you can read with
`jobs`." :required-p nil)
               ("name" :string "A name for a background job, so you can find it
again (default: one is made up)" :required-p nil)
               ("timeout" :integer "Seconds before the command is killed (default 120)" :required-p nil))
  (if (eq t (gethash "background" args))
      (start-background args)
      (multiple-value-bind (text status)
          (run-bash (gethash "command" args)
                    :timeout (or (gethash "timeout" args) *bash-timeout*))
        (cond ((eql 0 status) text)
              ((eq :timeout status)
               ;; Say what to do instead. A bare timeout is why an agent asked
               ;; for a dev server ran it, waited out the whole limit, and then
               ;; RAN IT AGAIN: nothing in the failure suggested the command was
               ;; the wrong shape rather than merely slow.
               (tool:make-tool-result
                :output (format nil "~a~%~%[Timed out after the limit. If this ~
command is meant to keep running -- a server, a watcher -- start it with ~
background true instead, and read it with `jobs`.]" text)
                :error-p t))
              (t (tool:make-tool-result :output (format nil "exit ~a~%~a" status text)
                                        :error-p t))))))

(defun start-background (args)
  "Start a long-lived process and say where to watch it."
  (handler-case
      (let ((job (jobs:start (gethash "command" args)
                             :name (gethash "name" args)
                             :directory (env:env-cwd (environment)))))
        ;; A moment before reporting: a command that dies instantly -- a typo, a
        ;; missing binary -- should say so now rather than be announced as
        ;; started and found dead later.
        (sleep 0.4)
        (if (jobs:alive-p job)
            (format nil "started ~a in the background~%  ~a~%~
Read its output with jobs {\"action\":\"output\",\"name\":\"~a\"}, ~
stop it with {\"action\":\"stop\",\"name\":\"~a\"}."
                    (jobs:job-name job) (jobs:job-command job)
                    (jobs:job-name job) (jobs:job-name job))
            (tool:make-tool-result
             :output (format nil "~a ~a at once:~%~a" (jobs:job-name job)
                             (jobs:status-of job) (jobs:output-of job))
             :error-p t)))
    (error (condition)
      (tool:make-tool-result :output (format nil "could not start: ~a" condition)
                             :error-p t))))

(tool:define-tool jobs-tool (args context)
  :name "jobs"
  :description "List, read or stop the background processes started with
`bash` and background true. Use it to see whether a dev server came up, what it
printed, and to stop it when you are done."
  :parameters (("action" :string "list, output, or stop" :required-p t)
               ("name" :string "Which job, for output and stop" :required-p nil))
  (let* ((action (or (gethash "action" args) "list"))
         (name (gethash "name" args))
         (job (and name (jobs:find-job name))))
    (cond
      ((string-equal "list" action)
       (let ((all (jobs:all-jobs)))
         (if (null all)
             "no background jobs"
             (format nil "~{~a~^~%~}"
                     (mapcar (lambda (each)
                               (format nil "~a~12t~a~24t~a" (jobs:job-name each)
                                       (jobs:status-of each) (jobs:job-command each)))
                             all)))))
      ((null name)
       (tool:make-tool-result :output "that action needs a name" :error-p t))
      ((null job)
       (tool:make-tool-result
        :output (format nil "no job called ~a. `list` shows them." name) :error-p t))
      ((string-equal "output" action)
       (format nil "~a is ~a~%~%~a" (jobs:job-name job) (jobs:status-of job)
               (jobs:output-of job)))
      ((string-equal "stop" action)
       (jobs:stop job)
       (format nil "stopped ~a" name))
      (t (tool:make-tool-result
          :output (format nil "no such action: ~a. Use list, output or stop." action)
          :error-p t)))))

(defun tool-set ()
  "The ordinary-work tool set, in the order the system prompt lists it."
  (append (file-tools) (search-tools) (list bash-tool jobs-tool)))
