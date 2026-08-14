;;;; Dispatch.

(in-package #:vivarium.cli)

(defparameter +commands+
  (list (list "test" #'command-test
              "Run the whole test suite. Exits non-zero if anything fails.")
        (list "check" #'command-check
              "Compile every experiment. No model server, no network.")
        (list "tasks" #'command-tasks
              "List the task set with families and the held-out split.")
        (list "calibrate" #'command-calibrate
              "Attempt tasks with real models and report per-task scores.")
        (list "attend" #'command-attend
              "Watch one task run, and steer the agent while it works.")
        (list "run" #'command-run
              "Point the agent at your own code with your own prompt.")
        (list "compare" #'command-compare
              "Diff two calibrate --out files; reports the noise floor.")))

(defparameter +usage+
  "vivarium <command> [options]

  test                        run the test suite (exits non-zero on failure)
  check                       compile every experiment; catches a script that
                              stopped loading during a refactor
  tasks                       list the task set
  calibrate [options]         attempt tasks with real models
      --models a,b            arms to use (default: every arm with credentials)
      --tasks T1,T4           tasks to run  (default: all)
      --split train           or held-out   (ignored if --tasks is given)
      --repeats N             runs per cell (default 3; n=1 is inside the noise)
      --limit N               request cap per attempt (default 12)
      --out results.json      write structured results for `compare`
  attend <task> [options]     watch one run and steer it live
      --model NAME            which arm (default: the first available)
      --limit N               request cap (default 12)
  run <prompt> [options]      your own task, not a benchmark one
      --package NAME          package definitions land in (default: a scratch one)
      --system S              quickload S first, so there is code to work on
      --load F                load file F first
      --model NAME            which arm
      --jail DIR              confine the shell (scored runs do this; you need not)
      --file prompt.txt       read the prompt from a file, or pipe it on stdin
  compare <before> <after>    how many cells moved between two sweeps

Credentials are read from .env at the repository root by bin/vivarium, so no
run depends on the caller having sourced it.
")

(defun main (tokens)
  (let* ((parsed (parse-arguments tokens))
         (name (first (args-positional parsed)))
         (entry (find name +commands+ :key #'first :test #'equal)))
    (cond ((null entry)
           (write-string +usage+)
           (if name 1 0))
          (t
           (setf (args-positional parsed) (rest (args-positional parsed)))
           (handler-case (funcall (second entry) parsed)
             (error (condition)
               (format *error-output* "~&~a: ~a~%" name condition)
               1))))))
