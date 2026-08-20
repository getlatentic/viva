;;;; Dispatch.

(in-package #:vivarium.cli)

(defparameter +commands+
  (list (list "daemon" #'command-daemon
              "Start, stop or inspect the long-lived organism.")
        (list "attach" #'command-attach
              "Open a session inside the organism; closing leaves it running.")
        (list "shell" #'command-shell
              "Work in a directory, interactively.")
        (list "ipc" #'command-ipc
              "Serve one agent over stdin and stdout, as JSON lines.")
        (list "do" #'command-do
              "One prompt, one answer, no session.")
        (list "mcp" #'command-mcp
              "Serve the tool registry over MCP on stdio, for any client.")
        (list "install" #'command-install
              "Link vivarium into a directory on your PATH.")
        (list "trust" #'command-trust
              "Allow a project's own extensions and tools to run.")
        (list "sessions" #'command-sessions
              "List or search recorded sessions.")
        (list "test" #'command-test
              "Run the whole test suite. Exits non-zero if anything fails.")
        (list "check" #'command-check
              "Compile every experiment. No model server, no network.")
        (list "soak" #'command-soak
              "Churn sessions and clients for minutes; exit non-zero on growth.")
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

THE ORGANISM

  daemon [status|start|stop]  the long-lived process sessions live inside
      --background            detach the accept loop and return
  attach [SESSION] [options]  open or rejoin a session; /detach leaves it running
      --cwd DIR               where a new session works
      --since N               replay events after sequence N

  A session outlives the terminal that started it. Closing a client removes a
  subscriber, not the work.

ORDINARY WORK

  shell [options]             work in a directory, interactively
      --cwd DIR               where to work (default: here)
      --model NAME            which model (default: the first configured)
      --root DIR              refuse any path outside DIR
      --limit N               model requests per prompt (default 60)
      --colour false          plain output, for a log
      --resume [ID]           continue the last session here, or one by id
  ipc [options]               serve one agent over stdin/stdout as JSON lines
      (same options; --limit defaults to 200)
      --append TEXT           add one line to the system prompt
      --extension DIR         load extensions from DIR as well
  do \"<prompt>\" [options]     one prompt, one answer, no session
      --file prompt.txt       read the prompt from a file
      --quiet                 print only the final answer
      --retain                after the task, decide what should outlive it
      --session-dir DIR       record the transcript, for counting the work done
      --extension DIR         load extensions from DIR as well
  install [--prefix DIR]      link `vivarium` onto your PATH, so the commands
                              above are the ones you actually type
  trust [DIR]                 allow DIR's own extensions and tools to run
                              (needed before a tool the organism wrote in a
                              project can be called back; /trust in the shell)
  sessions [options]          list what has been recorded
      --search TEXT           only sessions whose conversation contains TEXT
      --all                   every project, not just this directory

  --retain is the retention policy: one bounded turn in which the agent
  decides what -- a note, or a tool it writes -- should outlive the task.
  Interactively the same turn is /retain. It is opt-in because it was
  measured: what it keeps is good, and it costs about 8% more tokens
  overall -- less on mechanical recurring work, more on judgement.
  See docs/retention-policy.md and experiments/dogfood/RESULTS.md.

  Skills go in .vivarium/skills/<name>/SKILL.md, prompt templates in
  .vivarium/prompts/*.md (invoked as /name, with $1..$9 and $ARGUMENTS),
  extensions in .vivarium/extensions/*.lisp, and what the agent chooses to
  keep in .vivarium/MEMORY.md. The same four work from ~/.vivarium/ for every
  project. /help in the shell lists what is loaded.

EXPERIMENTS

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
