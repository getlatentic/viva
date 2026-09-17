;;;; Dispatch.

(in-package #:viva.cli)

(defparameter +commands+
  (list (list "daemon" #'command-daemon
              "Start, stop or inspect the long-lived organism.")
        (list "attach" #'command-attach
              "Open a session inside the organism; closing leaves it running.")
        (list "do" #'command-do
              "One prompt, one answer, no session.")
        (list "mcp" #'command-mcp
              "Serve the tool registry over MCP on stdio, for any client.")
        (list "config" #'command-config
              "Show every setting, its value, and which file decided it.")
        (list "learned" #'command-learned
              "What this project's agent has retained: notes, skills, tools.")
        (list "install" #'command-install
              "Link viva into a directory on your PATH.")
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
  "viva                          the full-screen client, on a terminal;
                              the line client when piped or redirected
viva <command> [options]

THE ORGANISM

  daemon [status|start|stop]  the long-lived process sessions live inside
      --background            detach the accept loop and return
  daemon upgrade              become the build on disk, restarting nothing
      --detach                return at once; it switches once turns end
  attach [SESSION] [options]  open or rejoin a session; /detach leaves it running
      --new                   always start a fresh one, never rejoin
      --cwd DIR               where a new session works
      --since N               replay events after sequence N

  `viva` starts the daemon if there is not one, rejoins a session for this
  directory, or continues the most recent conversation recorded here.
  `attach` is the same sessions on the line: it pipes, scripts and diffs.

  A session outlives the terminal that started it. Closing a client removes a
  subscriber, not the work.

ORDINARY WORK

  do \"<prompt>\" [options]     one prompt, one answer, no session
      --serve                 keep reading, as JSON lines on stdin and stdout,
                              until end of input. For another program to drive;
                              --limit defaults to 200 here
      --file prompt.txt       read the prompt from a file
      --cwd DIR               where to work (default: here)
      --model NAME            which model (default: the first configured)
      --root DIR              refuse any path outside DIR
      --limit N               model requests per prompt (default 60)
      --colour false          plain output, for a log
      --resume [ID]           continue the last session here, or one by id
      --append TEXT           add one line to the system prompt
      --extension DIR         load extensions from DIR as well
      --capabilities on       let the agent compile new code into this image
                              and call it (off by default; see the README)
      --capabilities loop     let the agent send itself the next prompt, so
                              work carries on past the end of a turn. /stop,
                              ctrl-c, or the agent\'s own `continue stop`
                              ends it. Names combine: `on,loop`
      --quiet                 print only the final answer
      --retain                after the task, decide what should outlive it
      --session-dir DIR       record the transcript, for counting the work done

  Capabilities are a flag only here, where the agent is built in this process.
  A session inside the daemon takes them from ~/.viva/config, and from this
  project's .viva/config once `viva trust` has been run here.

  config [DIR]                every setting, its value, and where it came from
                              (~/.viva/config, then .viva/config, then
                              the environment, then a flag -- later wins)
  learned [DIR]               what the agent has retained here: notes, skills
                              and tools, and where each came from
  install [--prefix DIR]      link `viva` onto your PATH, so the commands
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

  Skills go in .viva/skills/<name>/SKILL.md, prompt templates in
  .viva/prompts/*.md (invoked as /name, with $1..$9 and $ARGUMENTS),
  extensions in .viva/extensions/*.lisp, and what the agent chooses to
  keep in .viva/MEMORY.md. The same four work from ~/.viva/ for every
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

  --version                   which build this is
  --help                      this text

The full-screen client does not ask the terminal for the mouse, so dragging
selects text the way it does anywhere else. VIVA_MOUSE=1 asks for it back, for
the wheel and clickable rows -- then hold alt or shift to select.

Credentials are read from ~/.viva/auth.json by the engine itself, so no run
depends on the caller having exported anything.
")

(defun bare-p (parsed)
  "Is this `viva` and nothing else?

THE CLIENT READS NO ARGUMENTS, so anything given alongside would be accepted
and dropped. `viva --cwd elsewhere` means the line client, where --cwd is read,
rather than a full screen that silently ignored it. The launcher tests the same
thing before it hands over, and the two must agree or the answer depends on
whether a checkout was involved."
  (and (null (args-positional parsed))
       (zerop (hash-table-count (args-flags parsed)))))

(defun help-wanted-p (parsed name)
  "Did they ask for the usage text, rather than just typing the command?"
  (or name (flag parsed "help") (flag parsed "h")))

(defparameter +session-flags+
  '("help" "h" "version" "cwd" "new" "resume" "since" "model")
  "What bare `viva` accepts on its own. Every CONFIG setting is also a flag,
because OPTION falls back to the config table, so the two lists together are the
answer rather than either alone.")

(defun unknown-flags (parsed)
  "The flags bare `viva` cannot act on, in the order they were given.

A FLAG WITH NO COMMAND USED TO OPEN A SESSION. `viva --versoin` is a question,
and answering it by starting an interactive agent in the current directory is
the wrong answer to a typo -- the more so because the right one was one letter
away."
  (let ((known (append +session-flags+ (mapcar #'car config:+settings+))))
    (sort (loop for name being the hash-keys of (args-flags parsed)
                unless (member name known :test #'string=) collect name)
          #'string<)))

(defun main (tokens)
  (let* ((parsed (parse-arguments tokens))
         (name (first (args-positional parsed)))
         (entry (find name +commands+ :key #'first :test #'equal)))
    (cond
      ;; Before anything reads a config or opens a socket: it is a question
      ;; about this file, and an installer asks it to find out what it replaced.
      ((flag parsed "version")
       (format t "~&viva ~a~%" (version))
       0)
      ;; A FLAG THAT CANNOT REACH THE DAEMON. Sessions here are created inside a
      ;; process that outlives this command, so a capability named on this line
      ;; arrives after the decision. Saying where it does belong beats a flag
      ;; that is accepted and does nothing.
      ((and (null entry) (flag parsed "capabilities"))
       (format *error-output* "~&viva: a session's capabilities are not set here.~%~%~
Name them in ~~/.viva/config, or in this project's .viva/config once~%~
`viva trust` has been run here:~%~%  capabilities = ~a~%~%~
`viva do --capabilities ...` is the one that takes a flag, because it builds~%~
its agent in this process.~%" (flag parsed "capabilities"))
       1)
      ((and (null entry) (not (help-wanted-p parsed name)) (unknown-flags parsed))
       (let ((unknown (unknown-flags parsed)))
         (format *error-output* "~&viva: ~{--~a~^, ~} ~:[is not an option~;are not options~] here.~%~
Try `viva --help`.~%" unknown (rest unknown)))
       1)
      ;; Bare `viva` opens the organism. Starting work was `daemon start
      ;; --background` and then `attach` -- two commands and one concept
      ;; before anything happened, for the case that is almost always what
      ;; somebody wants.
      ;;
      ;; THE NAME IS THE WHOLE INTERFACE. `viva tui` was a second word for the
      ;; thing everybody wants, and `viva` meant the line client whatever the
      ;; terminal was -- so the usage text promised a full screen and the
      ;; command gave a prompt. On a terminal this is the full-screen client;
      ;; piped or redirected it is the line one, which is what a pipe can use.
      ;; Neither is reimplemented here, so there is one path into each.
      ((and (null entry) (not (help-wanted-p parsed name)))
       (handler-case (load-cli-settings parsed)
         (error (condition) (format *error-output* "~&! config: ~a~%" condition)))
       (handler-case (if (and (tui:terminal-p) (bare-p parsed))
                         (command-tui parsed)
                         (command-attach parsed))
         (error (condition) (format *error-output* "~&viva: ~a~%" condition) 1)))
      ((null entry)
           (write-string +usage+)
           (if name 1 0))
          (t
           (setf (args-positional parsed) (rest (args-positional parsed)))
           ;; Before the command runs, so every command sees the same settings
           ;; and none has to remember to load them.
           (handler-case (load-cli-settings parsed)
             (error (condition) (format *error-output* "~&! config: ~a~%" condition)))
           (handler-case (funcall (second entry) parsed)
             (error (condition)
               (format *error-output* "~&~a: ~a~%" name condition)
               1))))))
