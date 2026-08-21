;;;; The install surface: what a person who has never seen this repository hits.
;;;;
;;;; Everything else in this suite tests the harness. These test the front door,
;;;; because a clean-machine run found that the first command a newcomer types
;;;; to check their install -- `vivarium test` -- was the one command that could
;;;; not work on a clean machine, and nothing here would ever have noticed: the
;;;; suite only ever ran on a machine where the dependency was already present.
;;;;
;;;; The rule these encode is that a claim in a file a newcomer reads is a claim
;;;; the suite checks. Documentation drifts silently; a red test does not.

(in-package #:vivarium.tests)

(defun repository-file (relative)
  (uiop:read-file-string
   (merge-pathnames relative (asdf:system-source-directory "vivarium"))))

(define-test "every provider in the catalogue is named in .env.example"
  ;; A provider added to the catalogue and not to the example is a provider
  ;; nobody can discover: the error message names the key, but only once you
  ;; have already failed to configure anything.
  (let ((example (repository-file ".env.example")))
    (dolist (entry models::+catalogue+)
      (dolist (variable (list (getf entry :key)
                              (getf entry :endpoint-var)
                              (getf entry :model-var)))
        (true (search variable example)
              "~a is in the catalogue but not in .env.example" variable)))))

(define-test ".env.example carries names and never a value"
  ;; The file is committed, so a key pasted into it is a key published. Every
  ;; assignment is either empty or a commented-out default.
  (dolist (line (uiop:split-string (repository-file ".env.example")
                                   :separator '(#\Newline)))
    (let ((trimmed (string-left-trim " " line)))
      (unless (or (zerop (length trimmed)) (char= #\# (char trimmed 0)))
        (let ((equals (position #\= trimmed)))
          (true equals "~s is neither a comment nor an assignment" line)
          (when equals
            (is string= "" (subseq trimmed (1+ equals))
                "~a has a value in a committed file" (subseq trimmed 0 equals))))))))

(define-test ".env.example is not swallowed by the .env ignore"
  ;; `.env.*` was added before `.env.example` existed and matched it exactly.
  ;; Writing the file is not the same as shipping it.
  (true (search "!.env.example" (repository-file ".gitignore"))))

(define-test "the test system is loaded the way that resolves its dependencies"
  ;; ASDF resolves dependencies and never downloads them. The bootstrap
  ;; quickloads the CLI, so a clean machine gets every dependency except
  ;; parachute -- which only the test system wants, and which ASDF:LOAD-SYSTEM
  ;; therefore could never obtain.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (false (search "(asdf:load-system \"vivarium/tests\")" source)
           "vivarium/tests must be loaded through LOAD-TEST-SYSTEM, ~
which fetches what ASDF alone cannot")))

;;; The entry points, against the arguments the CLI actually hands them

(defun accepted-keywords (function)
  "The keywords FUNCTION's lambda list accepts, or T for &allow-other-keys."
  (let ((lambda-list (sb-introspect:function-lambda-list function)))
    (if (member '&allow-other-keys lambda-list)
        t
        (loop for entry in (rest (member '&key lambda-list))
              until (and (symbolp entry) (alexandria:starts-with #\& (string entry)))
              collect (alexandria:make-keyword
                       (string (if (consp entry) (first entry) entry)))))))

(define-test "every option the CLI builds reaches the agent it is built for"
  ;; `vivarium shell` died at startup with `Unknown &KEY argument: :EXTRA-TOOLS`
  ;; -- WORKSPACE-OPTIONS grew a key and two hand-copied lambda lists did not.
  ;; Nothing failed until a person ran the command, because no test ever built
  ;; the CLI's argument list and offered it to the thing that receives it.
  ;;
  ;; The chain is checked at both links, and the second is why: the runners now
  ;; forward everything, so asking only THEM whether a key is acceptable is a
  ;; question that can no longer be answered wrong. BUILD-AGENT is where a key
  ;; is finally accepted or refused, so that is what the CLI is measured
  ;; against.
  (let ((keys (loop for (key nil) on (cli::workspace-options
                                      (cli::parse-arguments '()))
                    by #'cddr collect key))
        (accepted (accepted-keywords #'vivarium.console::build-agent)))
    (true keys)
    (true (listp accepted) "BUILD-AGENT must name its keywords, not accept anything")
    (dolist (key keys)
      (true (member key accepted) "~a is passed by the CLI but BUILD-AGENT refuses it" key))
    ;; And the runners in between must not re-list them, which is the mistake
    ;; itself rather than its symptom.
    (dolist (runner (list #'vivarium.console:run-shell #'vivarium.console:run-ipc))
      (is eq t (accepted-keywords runner)
          "a runner that enumerates BUILD-AGENT's keywords rots the next time one is added"))))

(define-test "--limit reaches ipc, and its documented default is the real one"
  ;; :REQUEST-LIMIT was appended after a list that already carried one, and in a
  ;; keyword list the first value wins -- so ipc's documented 200 was 60.
  (is = 200 (getf (cli::workspace-options (cli::parse-arguments '()) :limit-default 200)
                  :request-limit))
  (is = 5 (getf (cli::workspace-options (cli::parse-arguments '("--limit" "5"))
                                        :limit-default 200)
                :request-limit)))

(define-test "colour is off when output is not a terminal, and --colour still wins"
  ;; Escape codes in a redirected log are the pane case: nothing about a
  ;; multiplexer changes this, but running inside one is when people redirect.
  (flet ((wanted (tokens) (cli::colour-wanted-p (cli::parse-arguments tokens))))
    (with-output-to-string (*standard-output*)
      (false (wanted '()) "a string stream is not a terminal")
      (true (wanted '("--colour" "true")) "an explicit request is honoured anyway")
      (false (wanted '("--colour" "false"))))))

;;; The organism's own behaviour, reachable from a command

(define-test "the retention policy has a caller outside an experiment"
  ;; HARNESS:REFLECT existed, was exported, was measured by the dogfood -- and
  ;; nothing in src/ called it. The organism's defining behaviour shipped
  ;; switched off, with no switch. `do --retain` is the switch; this is the
  ;; test that there is one at all.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "harness:reflect" source)
          "no command runs the retention policy")
    (true (search "\"retain\"" source)
          "--retain is not read anywhere")))

(define-test "a project can be trusted without an interactive shell"
  ;; Trust gates whether a project's own tools may run. The organism WRITES
  ;; tools into the project it works in, so a retained tool it cannot be
  ;; granted is a tool it can never call -- and until this command existed the
  ;; only way to grant it was a verb in the interactive shell, which a script,
  ;; a CI job and `vivarium do` cannot reach.
  (true (find "trust" cli::+commands+ :key #'first :test #'equal)))

(define-test "the demo names its model instead of taking whichever is first"
  ;; The catalogue offers the first provider configured, so on a machine with
  ;; several keys the demo would run against whichever came first -- while
  ;; quoting a price measured on a different one.
  (let ((source (repository-file "demo/retention")))
    (true (search "--model" source) "the demo does not pin a model")
    (true (search "budget.py" source) "the demo states a cap it never checks")))

;;; Being a command, not a path

(defun shell-code (text)
  "TEXT with whole-line comments removed, for asserting about what a script
DOES rather than about what it says."
  (format nil "~{~a~^~%~}"
          (remove-if (lambda (line) (alexandria:starts-with #\# (string-left-trim " " line)))
                     (uiop:split-string text :separator '(#\Newline)))))

(define-test "the launcher resolves symlinks to find its repository"
  ;; `vivarium install` puts a link on PATH, so $0 is usually somewhere like
  ;; ~/.local/bin -- and deriving the root from the LINK's directory looked for
  ;; the repository beside the link. The install reported success and the
  ;; command was broken; it only shows when you run it from elsewhere.
  (let ((launcher (repository-file "bin/vivarium")))
    (true (search "while [ -L \"$target\" ]" launcher)
          "the launcher must follow symlinks, or an installed vivarium cannot find its repo")
    (false (search "$(dirname \"$0\")/.." launcher)
           "the root must come from the resolved target, never from $0")
    ;; GNU-only flags do not exist on the readlink macOS ships. Comments are
    ;; stripped first: the file explains why it does NOT use that flag, and a
    ;; search over the whole text finds the explanation and fails on it.
    (false (search "readlink -f" (shell-code launcher)))))

(define-test "install refuses to replace something it did not put there"
  (let ((source (repository-file "src/cli/install.lisp")))
    (true (search "describe-existing" source))
    (true (search "not this repository's launcher" source)
          "overwriting a stranger's binary is not an installer's decision")))

;;; Seeing what a project's agent knows

(define-test "a refused tool is reported as refused, never as absent"
  ;; LOAD-ENTRIES returns nothing for an untrusted project, so `no tools here`
  ;; and `tools here that cannot run` produced identical output -- opposite
  ;; situations reading the same. The germline reads the disk separately so it
  ;; can tell them apart.
  (let ((trust:*trust-file* (format nil "/tmp/vivarium-germline-~36r.sexp"
                                    (random (expt 2 48) (make-random-state t))))
        (root (format nil "/tmp/vivarium-germline-~36r/" (random (expt 2 48) (make-random-state t)))))
    (unwind-protect
         (let ((tools (merge-pathnames ".vivarium/tools/greet/" root)))
           (ensure-directories-exist tools)
           (with-open-file (out (merge-pathnames "tool.json" tools) :direction :output)
             (write-string "{\"name\":\"greet\",\"description\":\"hi\",\"exec\":[\"true\"]}" out))
           ;; Untrusted: present, refused, and NOT listed as available.
           (let ((view (germline:inspect-directory (namestring root))))
             (false (germline:view-trusted-p view))
             (is = 0 (length (germline:view-tools view)))
             (is = 1 (length (germline:view-refused view)))
             (is string= "greet" (germline:item-name (first (germline:view-refused view)))))
           ;; Trusted: the same tool, now reachable and nothing refused.
           (trust:trust (env:make-local-environment :cwd (namestring root)) (namestring root))
           (let ((view (germline:inspect-directory (namestring root))))
             (true (germline:view-trusted-p view))
             (is = 1 (length (germline:view-tools view)))
             (is = 0 (length (germline:view-refused view)))))
      (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                  :if-does-not-exist :ignore)
      (uiop:delete-file-if-exists (trust:trust-file)))))

(define-test "the germline reports what the agent wrote, not what it was told"
  ;; MEMORY:CONTEXT-FILES also gathers the instruction files a PERSON wrote in
  ;; this directory and its ancestors. Counting those as retention would credit
  ;; the organism with everything it was handed.
  (let ((source (repository-file "src/workspace/germline.lisp")))
    (true (search "memory-files" source))
    (false (search "(memory:context-files" source)
           "notes must come from the agent's own memory files only")))

;;; The organism's own interface

(define-test "no slash line is ever forwarded to the model"
  ;; `/help` in an attached session used to be sent as a literal prompt: a paid
  ;; request, answered by a guess at what the typo meant. Every slash line is
  ;; now handled by the client, including one naming no verb at all.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "(a:starts-with #\\/ trimmed)" source)
          "the attach loop must claim every slash line before the prompt branch")))

(define-test "a mistyped verb is refused with the verb it resembles"
  ;; Prefix matching cannot see a dropped letter, which is the typo a
  ;; suggestion exists for.
  (is = 1 (cli::edit-distance "tols" "tools"))
  (is = 3 (cli::edit-distance "kitten" "sitting"))
  (is string= "tools" (cli::attached-name (cli::nearest-verb "tols")))
  (is string= "memory" (cli::attached-name (cli::nearest-verb "memry")))
  (is string= "retain" (cli::attached-name (cli::nearest-verb "retian")))
  (false (cli::nearest-verb "xyzzy") "a wrong suggestion is worse than none"))

(define-test "every verb that starts a turn drains that turn"
  ;; A request that starts a turn and does not consume its events leaves them
  ;; for whatever reads next, so the following prompt prints the previous
  ;; turn's output and stops at the previous turn's completion -- one behind,
  ;; forever. /retain did exactly that.
  (let ((source (repository-file "src/cli/attached.lisp")))
    (true (search "session.retain" source))
    (let ((retain (search "session.retain" source)))
      (true (search "stream-turn" source :start2 retain)
            "the retain verb must drain the turn it started"))))

(define-test "the daemon protocol answers for the germline and for retention"
  (let ((source (repository-file "src/daemon/server.lisp")))
    (true (search "\"session.inspect\"" source))
    (true (search "\"session.retain\"" source))
    ;; Answered from disk, never by reading the cell's live agent from a
    ;; client thread -- the violation ACTOR:SNAPSHOT exists to prevent.
    (true (search "germline:inspect-directory" source))
    (false (search "(agent:tools (actor:cell-agent" source))))

(define-test "a queued turn keeps everything it arrived with"
  ;; The queue stored (turn . text). A retention turn queued behind a running
  ;; one would have come back as an ordinary prompt: the right words with the
  ;; wrong budget, and nothing afterwards able to tell which it had been.
  (let ((source (repository-file "src/daemon/actor.lisp")))
    (true (search "(cons (first arguments) options)" source)
          "the queue must carry the whole message, not just its text")
    (true (search "(getf options :retain)" source)
          "the worker decides prompt-or-retention from the message it was given")))

;;; Giving it a prompt

(define-test "a prompt can be an argument, a file, or a pipe"
  ;; `do` had its own reader that took positionals only, so
  ;; `echo "..." | vivarium do` printed usage with the prompt sitting unread on
  ;; stdin -- while `run`, in the same binary, read stdin fine.
  (flet ((from (tokens &optional (input ""))
           (let ((*standard-input* (make-string-input-stream input)))
             (cli::prompt-from (cli::parse-arguments tokens)))))
    (is string= "fix the tests" (from '("fix" "the" "tests"))
        "unquoted arguments must still join")
    (is string= "piped in" (string-trim '(#\Newline) (from '() "piped in")))
    (is string= "via dash" (string-trim '(#\Newline) (from '("--file" "-") "via dash")))
    ;; An argument wins over a pipe: what you typed is what you meant.
    (is string= "typed" (from '("typed") "ignored"))
    (true (cli::blank-prompt-p (from '() "")))
    ;; A real newline: Common Lisp strings have no \n escape, and "\n" is the
    ;; single character n -- which is not blank, and the first draft of this
    ;; test asserted that it was.
    (true (cli::blank-prompt-p (from '() (format nil "   ~%  "))))))

;;; Settings

(defmacro with-config ((path &rest lines) &body body)
  "A project config of our own, removed afterwards."
  `(let* ((root (format nil "/tmp/vivarium-config-~36r/" (random (expt 2 48) (make-random-state t))))
          (,path (merge-pathnames ".vivarium/config" root)))
     (unwind-protect
          (progn (ensure-directories-exist ,path)
                 (with-open-file (out ,path :direction :output :if-exists :supersede)
                   (dolist (line (list ,@lines)) (write-line line out)))
                 (let ((cwd root)) (declare (ignorable cwd)) ,@body))
       (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                   :if-does-not-exist :ignore))))

(define-test "no setting maps onto a variable vivarium sets for itself"
  ;; VIVARIUM_ROOT is the REPOSITORY, set by the launcher on every run. The
  ;; `root` setting is the workspace jail. The mechanical name mapping put them
  ;; on one variable, so every run in every project silently took the
  ;; repository as its jail and the agent could not touch the work it was
  ;; pointed at. Found by reading `vivarium config` output, not by a crash.
  (dolist (entry config:+settings+)
    (let ((variable (config:environment-name (car entry))))
      (false (member variable config:+reserved-variables+ :test #'string=)
             "the ~a setting maps onto ~a, which vivarium sets itself"
             (car entry) variable))))

(define-test "a credential in a config file is refused by name"
  ;; .env is gitignored and a config file is committed, so a key in one is a
  ;; key published.
  (with-config (path "model=deepseek" "DEEPSEEK_API_KEY=sk-pretend")
    (declare (ignore path))
    (multiple-value-bind (table complaints) (config:load-settings cwd)
      (is string= "deepseek" (config:setting table "model"))
      (true (find-if (lambda (said) (search "Credentials belong in .env" said)) complaints)
            "a key in a config file must be refused, not stored"))))

(define-test "a mistyped setting is named rather than ignored"
  (with-config (path "mdoel=deepseek")
    (declare (ignore path))
    (multiple-value-bind (table complaints) (config:load-settings cwd)
      (false (config:setting table "mdoel"))
      (true (find-if (lambda (said) (search "is not a setting" said)) complaints)
            "a config that quietly does nothing sends you looking at the wrong thing"))))

(define-test "the environment beats a config file, and both beat the default"
  (with-config (path "model=deepseek")
    (declare (ignore path))
    (is eq :project (config:source (config:load-settings cwd) "model"))
    (is string= "deepseek" (config:setting (config:load-settings cwd) "model"))
    (sb-posix:setenv "VIVARIUM_MODEL" "bedrock" 1)
    (unwind-protect
         (progn
           (is eq :environment (config:source (config:load-settings cwd) "model"))
           (is string= "bedrock" (config:setting (config:load-settings cwd) "model")))
      (sb-posix:unsetenv "VIVARIUM_MODEL"))
    (is eq :default (config:source (config:load-settings cwd) "colour"))))

;;; Sitting down to work

(define-test "bare vivarium opens a session, and --help still explains itself"
  ;; Starting work was `daemon start --background` then `attach`: two commands
  ;; and one concept before anything happened, for the case that is almost
  ;; always what somebody wants.
  (false (cli::help-wanted-p (cli::parse-arguments '()) nil)
         "no arguments means open a session")
  (true (cli::help-wanted-p (cli::parse-arguments '("--help")) nil))
  (true (cli::help-wanted-p (cli::parse-arguments '()) "wibble")
        "an unknown command must still print usage, not open a session")
  ;; And it calls ATTACH rather than reimplementing it: one path into a
  ;; session cannot disagree with itself.
  (true (search "(command-attach parsed)" (repository-file "src/cli/main.lisp"))))

(define-test "the resolved model reaches the daemon, not the raw flag"
  ;; The daemon resolves a model in ITS process, where the project's config is
  ;; not in scope. Sending the flag meant `model=deepseek` in .vivarium/config
  ;; was ignored by every attached session while `vivarium config` cheerfully
  ;; reported it.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "\"model\" (option parsed \"model\")" source)
          "session.start must carry the resolved model")))

(define-test "credentials load from the machine as well as the clone"
  ;; Settings moved to ~/.vivarium/config and keys stayed in the repository, so
  ;; half the setup still lived in a checkout you might never open again.
  (let ((launcher (shell-code (repository-file "bin/vivarium"))))
    (true (search ".vivarium/.env" launcher))
    ;; The repository's is sourced second so it wins for a run made inside it.
    (let ((machine (search ".vivarium/.env" launcher))
          (repo (search "$root/.env" launcher)))
      (true (and machine repo (< machine repo))
            "the repository's .env must be sourced after the machine's"))))

;;; Sessions as tabs

(define-test "switching detaches before it attaches"
  ;; Subscriptions ADD rather than replace, so attaching to a second session
  ;; without detaching leaves the client receiving both streams interleaved --
  ;; exactly what a switch would otherwise produce.
  (let ((source (repository-file "src/cli/attached.lisp")))
    (let ((attach (search "\"session.attach\"" source))
          (detach (search "\"session.detach\"" source)))
      (true (and attach detach) "switching needs both halves")
      (true (< attach detach)
            "attach first, so a switch to a session that does not exist leaves ~
you where you were rather than nowhere"))))

(define-test "opening a folder rejoins its live session instead of duplicating it"
  ;; Four sessions on one directory, none knowing what the others did, is what
  ;; `always start a new one` produces.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "live-session-here" source))
    (true (search "(option-true-p parsed \"new\")" source)
          "--new must still force a fresh session")))

(define-test "the daemon can stop watching one session"
  (let ((source (repository-file "src/daemon/server.lisp")))
    (true (search "\"session.detach\"" source))
    (true (search "(defun unwatch (client cell)" source))))

(define-test "the installer refuses to guess, and never writes a key"
  (let* ((script (repository-file "install.sh"))
         (code (shell-code script)))
    ;; Every prerequisite it cannot supply is a named refusal with the command
    ;; that fixes it, not a stack trace or a silent skip.
    (true (search "brew install sbcl" script))
    (true (search "quicklisp-quickstart:install" code))
    ;; It copies the EXAMPLE, which carries names and no values, and locks it
    ;; down. Writing a credential file the world can read would be worse than
    ;; writing none.
    (true (search ".env.example" code))
    (true (search "chmod 600" code))
    ;; And it never clobbers a key file that is already there.
    (true (search "leaving it alone" script))))

;;; Interrupting, and coming back

(define-test "a tool call shows what it was called with"
  ;; An attached session printed the tool NAME alone, so a run showed as twelve
  ;; identical lines saying `bash`, which tells you the agent is busy and
  ;; nothing at all about what it is doing.
  (flet ((call (name &rest pairs)
           (let ((arguments (make-hash-table :test #'equal))
                 (table (make-hash-table :test #'equal)))
             (loop for (k v) on pairs by #'cddr do (setf (gethash k arguments) v))
             (setf (gethash "name" table) name (gethash "arguments" table) arguments)
             table)))
    (is string= "bash wc -l f.txt" (cli::call-line (call "bash" "command" "wc -l f.txt")))
    (is string= "read f.txt" (cli::call-line (call "read" "path" "f.txt")))
    ;; A tool with no recognised key still shows something rather than nothing.
    (is string= "odd hello" (cli::call-line (call "odd" "whatever" "hello")))
    (is string= "bare" (cli::call-line (call "bare")))))

(define-test "Ctrl-C cancels the work rather than only the client"
  ;; It used to kill the client and print `interrupted` while the daemon
  ;; carried on running the turn -- so the word was false, and it kept
  ;; spending. And the handler does NO I/O: sending the cancel from a signal
  ;; context is a blocking socket call on the socket the loop may be mid-read
  ;; on, which SBCL warns about and which worked, the most dangerous thing an
  ;; unsound mechanism can do.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "(throw 'interrupted t)" source))
    (true (search "\"cancel\" \"session\" id" source)
          "the interrupt must actually cancel the turn")
    (let ((handler (search "defun interrupt-attached" source)))
      (true handler)
      (false (search "daemon:request" source :start2 handler :end2 (+ handler 600))
             "no I/O in the signal handler"))))

(define-test "rejoining a session cannot hang, and leaves the socket clean"
  ;; The first version asked for a replay and read until it saw the sequence
  ;; the attach reply named -- which is the NEXT sequence to be assigned, not
  ;; the last one used, so rejoining blocked forever. Replay is a nicety;
  ;; hanging is not.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "current-sequence" source))
    (false (search "replay-into-view" source)))
  (let ((source (repository-file "src/cli/attached.lisp")))
    (true (search "describe-rejoin" source))
    ;; It reads nothing: whatever a rejoin does not consume is consumed by the
    ;; next prompt instead.
    (let ((describe (search "defun describe-rejoin" source)))
      (false (search "read-line" source :start2 describe
                     :end2 (min (length source) (+ describe 900)))))))

(define-test "Ctrl-C stops the request and keeps the session"
  ;; What every REPL has meant by Ctrl-C for forty years: stop what you are
  ;; doing, not leave. A second one, at a prompt with nothing running, exits.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "(setf *interrupted-recently* t)" source)
          "cancelling must not fall through to the exit path")
    (false (search "is still open. `vivarium` rejoins it" source)
           "that message belonged to the version that gave up and left")))

(define-test "the interrupted read is not mistaken for end of input"
  ;; SBCL's READ-LINE returns NIL once after the signal that interrupted the
  ;; syscall, which is indistinguishable from Ctrl-D -- so cancelling a turn
  ;; exited the client, and `stay in the session` was the one thing the fix
  ;; did not do.
  (let ((source (repository-file "src/cli/attached.lisp")))
    (true (search "(defun read-prompt" source))
    (true (search "*interrupted-recently*" source))))

(define-test "a lost connection is a sentence, not an FD-STREAM"
  ;; `Couldn't write to #<SB-SYS:FD-STREAM for "socket, peer: ...">: Broken
  ;; pipe` names a Lisp object and no cause. The daemon drops a client that
  ;; falls too far behind, deliberately; the session is untouched.
  (true (search "The organism closed this connection"
                (repository-file "src/cli/commands.lisp")))
  (true (search ":connection-lost" (repository-file "src/cli/attached.lisp"))))

;;; Processes that are supposed to keep running

(define-test "a long-running command can be started without waiting for it"
  ;; Asked to start a dev server, an agent ran it in the foreground, waited out
  ;; the whole 120-second timeout, got an error, RAN IT AGAIN, waited another
  ;; 120, and then explained it could not. Four minutes, two identical
  ;; commands, no server.
  (let ((job (jobs:start "while true; do echo tick; sleep 1; done" :name "suite-ticker")))
    (unwind-protect
         (progn
           (sleep 1)
           (true (jobs:alive-p job))
           (is string= "running" (jobs:status-of job))
           (true (find "suite-ticker" (jobs:all-jobs) :key #'jobs:job-name :test #'string=))
           (true (search "tick" (jobs:output-of job))))
      (jobs:stop job))
    (false (jobs:find-job "suite-ticker") "a stopped job is forgotten")))

(define-test "stopping a job kills what it started, not just the shell"
  ;; `sh -c \"npm run dev\"` is a shell whose CHILD holds the port. Killing only
  ;; the shell leaves the server running, which looks exactly like the stop
  ;; having failed.
  (let ((marker (format nil "/tmp/vivarium-job-marker-~36r" (random (expt 2 40) (make-random-state t)))))
    (let ((job (jobs:start (format nil "sh -c 'while true; do echo x >> ~a; sleep 0.2; done'" marker))))
      (sleep 1)
      (jobs:stop job)
      (let ((size (and (probe-file marker)
                       (with-open-file (in marker) (file-length in)))))
        (sleep 1)
        (is equal size (and (probe-file marker)
                            (with-open-file (in marker) (file-length in)))
            "the grandchild kept writing after the job was stopped")))
    (uiop:delete-file-if-exists marker)))

(define-test "the model is told the background option exists"
  ;; A mechanism nobody is told about is a mechanism nobody uses -- and the
  ;; timeout has to name it too, since a bare timeout reads as `slow`, which
  ;; is what invites the retry.
  (let ((description (tool:tool-description workspace::bash-tool))
        (source (repository-file "src/workspace/shell.lisp")))
    (true (search "background true" description))
    ;; Not "keep running": the description wraps between those two words, and
    ;; a test that asserts on text spanning a line break is a test about
    ;; formatting.
    (true (search "meant to keep" description))
    (true (search "background true instead" source)
          "the timeout message must name the fix -- a bare timeout reads as ~
`slow`, which is what invites the retry")))

(define-test "a stale organism says so, and can be restarted"
  ;; A long-lived process keeps the code it was built from. Someone who edits
  ;; vivarium, rebuilds and reattaches is talking to the OLD one -- and the
  ;; change they just made looks like it does not work. It cost a person five
  ;; hours and a model that invented a shell workaround for a tool it could
  ;; not see, because the tool did not exist in the process it was talking to.
  (let ((source (repository-file "src/cli/commands.lisp")))
    (true (search "warn-if-stale" source))
    (true (search "newest-source-time" source))
    ;; The warning has to name the cost of acting on it: sessions live in the
    ;; process, so a restart ends them.
    (true (search "Sessions live in the process" source))
    (true (search "\"restart\" verb" source) "acting on the warning must be one command"))
  ;; And the daemon has to send what the comparison needs.
  (true (search "\"started\" *started-at*" (repository-file "src/daemon/server.lisp"))))

(define-test "background jobs do not outlive the process that started them"
  ;; A `daemon restart` -- the command a person is told to run when their code
  ;; is stale -- would otherwise leave every dev server it ever started alive,
  ;; holding ports, with the only record of them in a process that just died.
  ;; Pi tracks detached child pids and kills the tree on SIGHUP/SIGTERM for the
  ;; same reason; here the process lives longer, so it matters more.
  (jobs:start "while true; do sleep 1; done" :name "suite-orphan-a")
  (jobs:start "while true; do sleep 1; done" :name "suite-orphan-b")
  (true (>= (length (jobs:all-jobs)) 2))
  (jobs:stop-all)
  (is = 0 (length (jobs:all-jobs)) "stop-all left a job behind")
  ;; And the daemon actually calls it, which is the half a unit test misses.
  (true (search "(jobs:stop-all)" (repository-file "src/daemon/server.lisp"))
        "nothing stops the jobs when the organism shuts down"))

;;; Sessions that were never used

(define-test "an unused session leaves no transcript, and a used one always does"
  ;; A session with nothing in it is an accident of attaching: somebody opened
  ;; the organism in a directory, looked, and left. Keeping those makes
  ;; `vivarium sessions` a list of mostly nothing.
  ;;
  ;; The second assertion is the important one. Two earlier versions of this
  ;; predicate asked the session object whether it had messages -- once with a
  ;; string kind against an EQ test on keywords, once with the keyword -- and
  ;; BOTH answered `empty` for a session that had one, which would have deleted
  ;; a person's transcript. Deleting user data on a predicate that has been
  ;; wrong twice is not something to leave to review.
  (let ((root (format nil "/tmp/vivarium-emptysess-~36r/" (random (expt 2 48) (make-random-state t)))))
    (unwind-protect
         (progn
           (ensure-directories-exist root)
           (let ((unused (session:open-session :directory root :cwd "/tmp")))
             (session:close-session unused)
             (false (probe-file (session:session-path unused))
                    "an unused session left a transcript behind"))
           (let ((used (session:open-session :directory root :cwd "/tmp")))
             (session:append-entry used :message
                                   (let ((payload (make-hash-table :test #'equal)))
                                     (setf (gethash "role" payload) "user"
                                           (gethash "content" payload) "hello")
                                     payload))
             (session:close-session used)
             (true (probe-file (session:session-path used))
                   "A SESSION WITH A MESSAGE WAS DELETED. This has been wrong ~
twice; it is somebody's record.")))
      (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                  :if-does-not-exist :ignore))))

(define-test "an earlier session is found before this one is created"
  ;; OPEN-SESSION writes the new session's own file, so a resume lookup running
  ;; after it resolved `the most recent session here` to the empty one being
  ;; created -- and faithfully loaded nothing. The verb reported success and
  ;; the conversation stayed blank, which is indistinguishable from a resume
  ;; that was never wired at all.
  (let ((source (repository-file "src/daemon/server.lisp")))
    (let ((lookup (search "(earlier (a:when-let ((wanted (text-of command \"resume\")))" source))
          (open (search "(session (session:open-session" source)))
      (true (and lookup open) "the resume lookup and the session open must both be there")
      (true (< lookup open)
            "the earlier session must be resolved BEFORE this session's file exists"))
    ;; And the daemon says which it loaded, so a resume that finds nothing can
    ;; be told apart from one that worked.
    (true (search "found no session there" source))
    (true (search "loaded ~a (~d message~:p)" source))))

(define-test "one session list, numbered, live and saved together"
  ;; Two lists in two places was the real problem: /sessions showed live cells,
  ;; the on-entry line counted recorded transcripts, they were different sets,
  ;; and neither could be chosen from -- while /switch and /continue both
  ;; wanted an id nobody had been shown beside the thing it named.
  (let ((source (repository-file "src/cli/attached.lisp")))
    (true (search "(defun show-sessions" source))
    (true (search "session:list-sessions" source) "recorded sessions must be listed too")
    (true (search "(defun listed-choice" source) "a number must mean something")
    ;; A live session's own transcript is in the recorded list holding nothing
    ;; yet; showing it as a separate `saved` row makes one session look like two.
    (true (search "zerop (session:summary-messages summary)" source)
          "an empty transcript belonging to a live session must not be listed")
    ;; The id keeps working. A list printed ten minutes ago is not a promise.
    (true (search "never the only" source))))

;;; A slow command that looks like work rather than a hang

(define-test "a command's output arrives while it runs, not all at the end"
  ;; EXEC collected everything into a string and returned at the end, so a
  ;; two-minute install showed nothing and then everything. That is why a slow
  ;; command read as a freeze -- and part of why background jobs got reached
  ;; for to work around output nobody could see. Pi has streamed since it
  ;; existed, which is why it needs no background option for this case.
  (let ((pieces '())
        (environment (env:make-local-environment :cwd "/tmp")))
    (multiple-value-bind (status output)
        (env:exec environment "for i in 1 2 3; do echo piece-$i; sleep 1; done"
                  :on-output (lambda (chunk) (push chunk pieces)))
      (is eql 0 status)
      ;; Every line still reaches the caller as the return value: streaming
      ;; must not cost the collected output the model reads.
      (dolist (n '("piece-1" "piece-2" "piece-3"))
        (true (search n output) "~a missing from the returned output" n))
      (true (> (length pieces) 1)
            "output arrived in one lump; nothing was streamed")
      (true (search "piece-1" (format nil "~{~a~}" (reverse pieces)))
            "the streamed pieces must carry the same text"))))

(define-test "streamed output reaches the event stream, not just the caller"
  ;; One stream for everything the agent does, so an attached session, a pane
  ;; and any future full-screen client all receive it without one of them
  ;; needing to know a process exists.
  (true (search "workspace:*on-output*" (repository-file "src/workspace/harness.lisp")))
  (true (search ":tool-output" (repository-file "src/console/shell.lisp")))
  (true (search "\"tool.output\"" (repository-file "src/daemon/events.lisp"))))

(define-test "two clients stopping one job do not race"
  ;; The job's state was a question asked of the OS at each call, and
  ;; PROCESS-STATUS can change between the check and the act -- which is how
  ;; `stop it` raced `it already exited` and left a SIGKILL aimed at a pid the
  ;; kernel had since recycled. The state is now the job's own, written in one
  ;; place under its lock, and the stop is claimed once.
  (let ((job (jobs:start "while true; do sleep 1; done" :name "suite-racer")))
    (sleep 0.4)
    (is string= "running" (jobs:status-of job))
    (mapc #'bt:join-thread
          (loop repeat 8 collect (bt:make-thread (lambda () (ignore-errors (jobs:stop job))))))
    (false (jobs:alive-p job) "the job survived eight concurrent stops")
    (false (jobs:find-job "suite-racer") "a stopped job must leave the table")))

(define-test "a background job can be watched, not only polled"
  ;; A running server's output sat in a file until somebody asked for it, so
  ;; `is it up?` meant polling. One pipe, two consumers: the log is what
  ;; `jobs output` reads afterwards, the callback is what reaches whoever is
  ;; watching now. The reader thread is also the drain -- an unread pipe fills
  ;; and stops the process producing it.
  (let* ((seen '())
         (job (jobs:start "for i in 1 2 3; do echo tick-$i; sleep 1; done"
                          :name "suite-pumped"
                          :on-output (lambda (chunk) (push chunk seen)))))
    (unwind-protect
         (progn
           (sleep 2)
           (let ((live (remove #\Newline (format nil "~{~a~}" (reverse seen)))))
             (true (search "tick-1" live) "nothing arrived while the job was running")
             ;; MID-RUN: the third tick has not happened yet, which is what
             ;; makes this live rather than a report after the fact.
             (false (search "tick-3" live)
                    "the whole output arrived at once; that is not streaming"))
           (true (search "tick-1" (jobs:output-of job))
                 "the log must still hold what the watcher saw"))
      (jobs:stop job))))

;;; Services: the retention router's fourth shape

(define-test "a project can declare a service, and starting it is idempotent"
  ;; Tiers 1-3 are a note, a code-carrying skill and a registered tool --
  ;; knowledge, a transformation, a callable. A service is none of those: it is
  ;; something that should be RUNNING while work happens here. The organism
  ;; already notices it starts the same dev server every session; until now the
  ;; most it could do about that was write a note saying so.
  (let ((root (format nil "/tmp/vivarium-svc-~36r/" (random (expt 2 48) (make-random-state t)))))
    (unwind-protect
         (let ((environment (env:make-local-environment :cwd root)))
           (ensure-directories-exist (merge-pathnames ".vivarium/services/" root))
           (with-open-file (out (merge-pathnames ".vivarium/services/ticker" root)
                                :direction :output)
             (write-string "while true; do echo tick; sleep 1; done" out))
           (is equal '(("ticker" . "while true; do echo tick; sleep 1; done"))
               (jobs:declared environment root))
           (is equal '("ticker") (mapcar #'car (jobs:start-declared environment root)))
           (sleep 0.5)
           (true (jobs:alive-p (jobs:find-job "ticker")))
           ;; Asking twice must not start a second one. A project opened in two
           ;; terminals would otherwise hold the port against itself.
           (false (jobs:start-declared environment root)
                  "a running service was started a second time")
           ;; A file with no command is not a service.
           (with-open-file (out (merge-pathnames ".vivarium/services/empty" root)
                                :direction :output)
             (write-string "   " out))
           (is = 1 (length (jobs:declared environment root))
               "an empty declaration must not count as a service"))
      (jobs:stop-all)
      (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                  :if-does-not-exist :ignore))))

(define-test "the README does not sell an abort every harness has"
  ;; It claimed `a steer can abort a request in flight` as one of three
  ;; deliberate differences, with a 1,927ms-vs-323,875ms measurement. Any
  ;; harness that passes an abort signal into its streaming request gets that;
  ;; Pi does. The difference is what happens NEXT -- Pi's run ends and steering
  ;; is polled at the end of an iteration, so a steer waits out the request --
  ;; and that is a loop policy, not a capability nobody else has.
  (let ((readme (repository-file "README.md")))
    (false (search "ABORTED after 1,927 ms" readme)
           "the front page still sells stop-early as a differentiator")
    (true (search "carried into the next request" readme))))

;;; The package file is a dependency graph maintained by hand
;;;
;;; A local nickname resolves when its DEFPACKAGE is read, so pointing at a
;;; package defined further down the SAME file fails at load. That bit three
;;; times in one session -- germline, jobs, skill -- each costing a
;;; compile-fail-diagnose cycle, and each failing with a message about a
;;; package graph lock that names neither the nickname nor the ordering.
;;;
;;; A test was written here to catch it and then REMOVED, because it cannot.
;;; Moving a package breaks the build, so the suite never loads and the test
;;; never runs: a check that only executes after a successful load cannot guard
;;; a load failure. Verified by reintroducing the bug -- the suite did not fail,
;;; it failed to start.
;;;
;;; Then it was moved into `vivarium check`, on the reasoning that check reads
;;; files rather than requiring them -- and that was WRONG in the same way, one
;;; level up. `bin/vivarium check` quickloads vivarium/cli before COMMAND-CHECK
;;; runs, so a broken package file kills the load before any check can read
;;; anything. Verified the same way: reintroduce the bug, and check dies in the
;;; loader rather than reporting.
;;;
;;; So the rule is sharper than it first looked. ANYTHING THAT GUARDS A LOAD
;;; FAILURE MUST NOT ITSELF REQUIRE THE LOAD, and both obvious homes do. What
;;; would work is a standalone script -- `sbcl --script` over the package files
;;; alone, touching none of the system -- run by install.sh or CI. Not written,
;;; and named precisely enough that nobody has to rediscover the two dead ends.

(define-test "the package-order guard exists, standalone, and is wired in"
  ;; Third home, and the first that can work. The suite cannot guard this --
  ;; a broken package file stops the suite loading. `vivarium check` cannot
  ;; either -- bin/vivarium quickloads before any command runs. Both were
  ;; tried and both verified dead by reintroducing the bug and looking.
  ;;
  ;; This test does NOT prove the guard works; by construction it cannot, since
  ;; it only runs when the tree already loads. It proves the guard exists, is
  ;; standalone, and is run by something. The proof that it catches the bug is
  ;; in the commit: on a tree with the fault, the script reports the file, the
  ;; line and the fix while `vivarium check` exits 1 having said nothing.
  (let* ((raw (repository-file "tools/check-package-order.lisp"))
         ;; Comments stripped first. The file EXPLAINS that it must not
         ;; quickload, so searching the whole text finds the explanation and
         ;; fails on it -- the same mistake the launcher test made with
         ;; `readlink -f`, made again three hours later.
         (script (format nil "~{~a~^~%~}"
                         (remove-if (lambda (line)
                                      (alexandria:starts-with #\; (string-left-trim " " line)))
                                    (uiop:split-string raw :separator '(#\Newline))))))
    (false (search "quickload" script) "the guard must not require the system it guards")
    (false (search "asdf:" script))
    (setf raw (or raw ""))
    (true (search "lateness is the whole rule" raw)
          "the rule it enforces should be stated in it"))
  (true (search "check-package-order.lisp" (repository-file "install.sh"))
        "a guard nothing runs is a guard that does not exist"))

;;; The tier-2 reuse signal, working

(define-test "a skill's snippet can be run by name, and the run is counted"
  ;; docs/tier-2-reuse-signal.md. A skill is injected into the prompt and read,
  ;; so there is no use event -- and without one, graduation (#8) has nothing to
  ;; threshold on and tier 3 is unreachable, which three runs of
  ;; experiments/tier3 demonstrated. Calling a skill makes use a fact.
  ;;
  ;; The tool lives in HARNESS, not WORKSPACE:TOOL-SET, and that placement took
  ;; three attempts: it needs SKILL-DIRECTORIES, which is in harness, and
  ;; shell.lisp loads first. Duplicating RESOURCE-DIRECTORIES there would have
  ;; worked today and drifted tomorrow.
  (let ((root (format nil "/tmp/vivarium-runskill-~36r/" (random (expt 2 48) (make-random-state t)))))
    (unwind-protect
         (let ((directory (merge-pathnames ".vivarium/skills/total/" root)))
           (ensure-directories-exist directory)
           (with-open-file (out (merge-pathnames "SKILL.md" directory) :direction :output)
             (write-string "---
name: total
description: Print a total.
language: python
---

```python
print(sum([2, 3, 5]))
```
" out))
           (let* ((environment (env:make-local-environment :cwd (namestring root)))
                  (skills (skill:load-skills environment
                                             (harness:skill-directories environment)))
                  (found (skill:find-skill skills "total")))
             (true found)
             (is string= "python" (skill:skill-language found)
                 "the language must survive into the struct, or nothing can run it")
             (true (search "sum([2, 3, 5])" (skill:snippet-of found))
                   "the fenced block must be extractable")
             (is = 0 (skill:uses-of environment found))
             (skill:note-use environment found)
             (skill:note-use environment found)
             (is = 2 (skill:uses-of environment found)
                 "the count is what graduation thresholds on")))
      (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                  :if-does-not-exist :ignore))))

(define-test "a skill run enough times becomes a tool the registry can call"
  ;; Tier 3, reached by EVIDENCE rather than judgement. Three tier3 runs showed
  ;; reflection cannot get here on its own: once a skill exists, the
  ;; re-derivation cost it would promote on is gone, so the case for a tool
  ;; never accumulates. Counting runs is what accumulates instead.
  (let ((root (format nil "/tmp/vivarium-grad-~36r/" (random (expt 2 48) (make-random-state t))))
        (trust:*trust-file* (format nil "/tmp/vivarium-gradtrust-~36r.sexp"
                                    (random (expt 2 48) (make-random-state t)))))
    (unwind-protect
         (let ((directory (merge-pathnames ".vivarium/skills/total/" root)))
           (ensure-directories-exist directory)
           (with-open-file (out (merge-pathnames "SKILL.md" directory) :direction :output)
             (write-string "---
name: total
description: Total three numbers.
language: python
---

```python
print(sum([2, 3, 5]))
```
" out))
           (let* ((environment (env:make-local-environment :cwd (namestring root)))
                  (skill (skill:find-skill
                          (skill:load-skills environment
                                             (harness:skill-directories environment))
                          "total")))
             (trust:trust environment (namestring root))
             ;; Below the threshold, nothing is promoted: two is a coincidence.
             (skill:note-use environment skill)
             (false (harness::graduate environment skill 1)
                    "a snippet promoted on its first run has not earned anything")
             ;; The registry must accept what graduation writes -- a promoted
             ;; tool the loader refuses is worse than no promotion, because it
             ;; looks like the ladder worked.
             (true (harness::graduate environment skill 3))
             (let ((tools (registry:load-tools environment
                                               (harness:registry-directories environment)
                                               :project (trust:canonical environment
                                                                         (namestring root)))))
               (true (find "total" tools :key #'tool:tool-name :test #'string=)
                     "graduation wrote a manifest the registry will not load"))))
      (uiop:delete-file-if-exists (trust:trust-file))
      (uiop:delete-directory-tree (pathname root) :validate (constantly t)
                                                  :if-does-not-exist :ignore))))

;;; Speaking a terminal's protocol without becoming one

(define-test "kitty keyboard detection answers, and never hangs"
  ;; The protocol is a PROTOCOL: a terminal that supports it reports keys
  ;; unambiguously, and one that does not IGNORES the query -- so the read must
  ;; be bounded. A detector that hangs on an old terminal is worse than one
  ;; that assumes the old terminal.
  ;;
  ;; Verified in a real tmux pane too: TERM=tmux-256color answers NIL in 0.15s
  ;; rather than blocking, which is the degradation path that actually matters
  ;; since a pane is where this will live.
  (false (tui:supported-p :input (make-string-input-stream "")
                          :output (make-broadcast-stream))
         "a pipe cannot answer, and asking puts an escape sequence in a log")
  ;; A terminal that never replies: give up on time.
  (let ((start (get-internal-real-time)))
    (false (tui::read-reply (make-concatenated-stream)
                            (+ (get-internal-real-time)
                               (round (* tui:*reply-timeout*
                                         internal-time-units-per-second)))))
    (let ((elapsed (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second)))
      (true (< elapsed (* 4 tui:*reply-timeout*))
            "detection took ~,2fs; a silent terminal must not block it" elapsed)))
  ;; One that does reply.
  (true (search "[?" (tui::read-reply
                      (make-string-input-stream (format nil "~c[?1u" #\Escape))
                      (+ (get-internal-real-time) internal-time-units-per-second))))
  ;; And the flags are the TERMINAL's state: a crash that leaves them pushed
  ;; leaves somebody's shell reporting keys it cannot read.
  (true (search "unwind-protect" (repository-file "src/tui/keyboard.lisp"))))

(define-test "a key decodes the same whichever dialect the terminal speaks"
  ;; The point of the protocol, in one assertion: Ctrl-I and Tab are the same
  ;; byte (9) in the legacy dialect and cannot be told apart. Under kitty they
  ;; are different keys. Everything above this should be written once against a
  ;; KEY, not twice against two dialects.
  (flet ((k (s) (tui:decode s))
         (csi (body) (format nil "~c[~au" #\Escape body)))
    ;; Legacy: indistinguishable, and honest about it.
    (is eq :tab (tui:key-value (k (string (code-char 9)))))
    ;; Kitty: 9 with the control bit set is Ctrl-I, not Tab.
    (let ((ctrl-i (k (csi "105;5"))))
      (is eql #\i (tui:key-value ctrl-i))
      (true (tui:key-control ctrl-i))
      (is string= "C-i" (tui:describe-key ctrl-i)))
    (is eq :tab (tui:key-value (k (csi "9;1"))))
    ;; The modifier field is the mask PLUS ONE. A decoder that forgets the
    ;; subtraction reports shift on every unmodified key.
    (let ((plain (k (csi "97;1"))))
      (is eql #\a (tui:key-value plain))
      (false (tui:key-shift plain))
      (false (tui:key-control plain))
      (false (tui:key-alt plain)))
    ;; Legacy arrows still work -- most terminals will never speak kitty.
    (is eq :up (tui:key-value (k (format nil "~c[A" #\Escape))))
    (is eq :left (tui:key-value (k (format nil "~c[D" #\Escape))))
    ;; C0: Ctrl-A is byte 1, and that much is recoverable.
    (let ((ctrl-a (k (string (code-char 1)))))
      (is eql #\a (tui:key-value ctrl-a))
      (true (tui:key-control ctrl-a)))
    ;; An unknown sequence is NIL, never a guess. A wrong key gets acted on.
    (false (k (format nil "~c[999~~" #\Escape)))
    (false (k ""))))

(define-test "reading a key knows where a sequence ends, and when there is none"
  ;; ESC alone is a key people press; ESC [ A is Up. Nothing in the bytes says
  ;; which until you have them, so the reader takes ESC and then looks -- with
  ;; a bound, because a person pressing Escape must not wait for a sequence
  ;; that will never arrive.
  (flet ((from (text) (tui::read-key (make-string-input-stream text) :timeout 0.02)))
    ;; A complete sequence returns as soon as its final byte arrives, without
    ;; waiting out the timeout.
    (is eq :up (tui:key-value (from (format nil "~c[A" #\Escape))))
    (let ((ctrl-i (from (format nil "~c[105;5u" #\Escape))))
      (is eql #\i (tui:key-value ctrl-i))
      (true (tui:key-control ctrl-i)))
    ;; Escape with nothing after it is Escape, and costs the timeout once.
    (is eq :escape (tui:key-value (from (string #\Escape))))
    ;; An ordinary byte does not wait at all.
    (is eql #\a (tui:key-value (from "a")))
    ;; End of input is NIL, not a key.
    (false (from ""))))

(define-test "a complete sequence does not wait out the timeout"
  ;; If the reader waited for the bound on every escape sequence, every arrow
  ;; key would cost it -- which is how a TUI comes to feel laggy for reasons
  ;; nobody can point at.
  (let ((start (get-internal-real-time)))
    (tui::read-key (make-string-input-stream (format nil "~c[A" #\Escape)) :timeout 1.0)
    (let ((elapsed (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
      (true (< elapsed 0.5)
            "an arrow key took ~,3fs against a 1s bound; it waited when it did not have to"
            elapsed))))

(define-test "raw mode is restored, including when the body crashes"
  ;; A TUI that exits without restoring leaves a shell with no echo and no line
  ;; editing, which looks like the machine broke -- and the fix a person
  ;; reaches for is closing the window. The UNWIND-PROTECT is the point of the
  ;; macro, not a detail of it.
  ;;
  ;; The suite does not run on a terminal, so this asserts the SHAPE. The
  ;; behaviour was verified in a real tmux pane and is in the commit:
  ;;   before (CANON T ECHO T) / inside (CANON NIL ECHO NIL) /
  ;;   after (CANON T ECHO T) / after a crash (CANON T ECHO T).
  (let ((source (repository-file "src/tui/terminal.lisp")))
    (true (search "unwind-protect" source))
    ;; The restore must use the SAVED attributes, not freshly-read ones -- by
    ;; then the terminal is raw, and reading it back would restore raw.
    (true (search "sb-posix:tcsetattr 0 sb-posix:tcsanow ,saved" source)
          "the restore must use what was saved before the change")
    ;; And the modified object must be independent of the saved one. SB-POSIX
    ;; has no copier, so this asks the kernel twice; mutating the saved object
    ;; would make the restore restore the modification.
    (false (search "copy-termios" source)
           "sb-posix has no copier -- that function was invented")
    (true (search "ask the kernel twice" source)))
  ;; Off a terminal, the body simply runs: a piped run is a real way to use
  ;; this and should not need a special case at the call site.
  (is eq :ran (tui:with-raw-terminal :ran)))

(define-test "a screen writes only what changed"
  ;; The naive loop clears and redraws every frame: simple, and it flickers.
  ;; Over ssh or in a multiplexer a full 80x24 repaint is ~2KB for a cursor
  ;; that moved one column. Two buffers and a comparison is the whole feature.
  (let ((screen (tui:make-blank-screen :width 20 :height 3)))
    ;; First frame draws what is there.
    (tui:put screen 0 0 "hello")
    (let* ((out (make-string-output-stream))
           (first (tui:flush screen out)))
      (true (plusp first))
      (true (search "hello" (get-output-stream-string out))))
    ;; An UNCHANGED frame costs nothing. This is a number, not an impression,
    ;; which is why it is the assertion.
    (tui:clear-back screen)
    (tui:put screen 0 0 "hello")
    (let* ((out (make-string-output-stream))
           (idle (tui:flush screen out)))
      (is = 0 idle "an unchanged frame wrote ~d bytes" idle)
      (is string= "" (get-output-stream-string out)))
    ;; A one-character change costs a cursor move and a character, not a row.
    (tui:clear-back screen)
    (tui:put screen 0 0 "hellp")
    (let* ((out (make-string-output-stream))
           (small (tui:flush screen out))
           (text (get-output-stream-string out)))
      (true (< small 12) "a one-character change wrote ~d bytes" small)
      (true (search "p" text))
      (false (search "hell" text) "it redrew the whole word for one changed letter"))))

(define-test "a screen clips rather than wrapping"
  ;; A line that wraps has silently changed the layout of everything below it.
  ;; A truncated line is a visible bug; a shifted layout is a confusing one.
  (let ((screen (tui:make-blank-screen :width 8 :height 2)))
    (tui:put screen 0 4 "abcdefgh")
    (let ((out (make-string-output-stream)))
      (tui:flush screen out)
      (let ((text (get-output-stream-string out)))
        (true (search "abcd" text))
        (false (search "efgh" text) "the overflow wrapped instead of being clipped"))))
  ;; Off-screen rows and negative columns are ignored, not errors: a layout
  ;; that computes a position off the edge should draw nothing, not crash.
  (let ((screen (tui:make-blank-screen :width 8 :height 2)))
    (tui:put screen 99 0 "nowhere")
    (tui:put screen 0 -3 "left")
    (is = 1 (length (tui::row-differences screen 0))
        "a negative column should still draw the part that is on screen")))

(defun tiling-fault (form width height)
  "NIL if FORM's regions tile WIDTH x HEIGHT exactly, else a description."
  (let ((covered (make-array (list height width) :initial-element 0)))
    (loop for (nil . region) in (tui:divide form :width width :height height)
          do (loop for row from (tui::region-row region)
                     below (+ (tui::region-row region) (tui::region-height region))
                   do (loop for column from (tui::region-column region)
                              below (+ (tui::region-column region)
                                       (tui::region-width region))
                            do (if (and (< -1 row height) (< -1 column width))
                                   (incf (aref covered row column))
                                   (return-from tiling-fault
                                     (format nil "region ~a spills to ~d,~d"
                                             (tui::region-name region) row column))))))
    (dotimes (row height)
      (dotimes (column width)
        (case (aref covered row column)
          (1)
          (0 (return-from tiling-fault (format nil "gap at ~d,~d" row column)))
          (t (return-from tiling-fault (format nil "overlap at ~d,~d" row column))))))
    nil))

(define-test "a layout tiles its area exactly, at every size"
  ;; The whole difficulty of a layout is the remainder. Three panes sharing 80
  ;; columns get 26 each and lose two, and those two are the blank stripe down
  ;; the right edge of every hand-rolled TUI. So the assertion is exactness --
  ;; no gap, no overlap -- checked at every width rather than at one.
  (let ((form '(:stack (:fixed 1 :title)
                       (:weight 1 (:beside (:fixed 24 :sessions)
                                           (:weight 2 :output)
                                           (:weight 1 :tasks)))
                       (:fixed 1 :status))))
    (loop for width from 1 to 200
          for fault = (tiling-fault form width 24)
          when fault do (fail (format nil "width ~d: ~a" width fault)))
    (loop for height from 1 to 60
          for fault = (tiling-fault form 80 height)
          when fault do (fail (format nil "height ~d: ~a" height fault)))
    (false (tiling-fault form 80 24))))

(define-test "a layout starves rather than overflowing"
  ;; A pane asking for 24 columns inside 10 must not be handed 24, and the
  ;; pane after it must not be handed -14. Both are the same bug and both
  ;; corrupt every row they touch.
  (let ((regions (tui:divide '(:beside (:fixed 24 :sessions) (:fixed 24 :output))
                             :width 10 :height 3)))
    (is = 10 (tui::region-width (tui:region-of regions :sessions)))
    (is = 0 (tui::region-width (tui:region-of regions :output))))
  (false (tiling-fault '(:beside (:fixed 24 :a) (:fixed 24 :b)) 10 3))
  ;; A zero-height screen is a resize in flight, not an error.
  (false (tiling-fault '(:stack (:fixed 1 :a) (:weight 1 :b)) 0 0)))

(define-test "a pane clips to itself, not to the screen"
  ;; One pane's long line bleeding into its neighbour is the only thing that
  ;; stops panes looking like panes.
  (let* ((screen (tui:make-blank-screen :width 20 :height 3))
         (regions (tui:divide '(:beside (:fixed 10 :left) (:weight 1 :right))
                              :width 20 :height 3)))
    (tui:draw-in screen (tui:region-of regions :left) 0
                 "0123456789OVERFLOW")
    (tui:draw-in screen (tui:region-of regions :right) 0 "right")
    (let ((out (make-string-output-stream)))
      (tui:flush screen out)
      (let ((text (get-output-stream-string out)))
        (true (search "0123456789" text))
        (false (search "OVERFLOW" text) "the left pane bled into the right")
        (true (search "right" text)))))
  ;; A row past the bottom of a pane draws nothing rather than in the pane below.
  (let* ((screen (tui:make-blank-screen :width 8 :height 4))
         (regions (tui:divide '(:stack (:fixed 2 :top) (:weight 1 :bottom))
                              :width 8 :height 4)))
    (tui:draw-in screen (tui:region-of regions :top) 5 "escaped")
    (let ((out (make-string-output-stream)))
      (tui:flush screen out)
      (is string= "" (get-output-stream-string out)
          "a row past the pane's bottom drew somewhere"))))

(define-test "a terminal size is never garbage"
  ;; The failure this guards is not "wrong size", it is a size that came from
  ;; uninitialised memory after a failed ioctl -- 4522 rows and 0 columns,
  ;; which looks measured. The suite has no controlling terminal, so what is
  ;; asserted here is that the no-terminal path is sane; that the ioctl path
  ;; reads the REAL size is checked by tools/pty-size-check.sh against a pty of
  ;; a known size, which is the only place it can be checked.
  (let ((size (tui:terminal-size)))
    (true (consp size))
    (true (plusp (car size)) "~d rows" (car size))
    (true (plusp (cdr size)) "~d columns" (cdr size))
    (true (< (car size) 1000) "~d rows is not a terminal" (car size))
    (true (< (cdr size) 1000) "~d columns is not a terminal" (cdr size))))

(define-test "a resize is a flag, not work in the handler"
  ;; A signal arrives on whichever thread the kernel picks, wherever it happens
  ;; to be. Repainting from there draws from two threads at once, so the
  ;; handler sets a flag and the loop acts on it.
  (let ((tui::*resized* nil))
    (false (tui:take-resize))
    (tui::note-resize)
    (true (tui:take-resize))
    (false (tui:take-resize) "a resize was reported twice")))

(defun frame-of (view &key (width 100) (height 12))
  "VIEW painted, as a list of strings. What the person would see."
  (let ((screen (tui:make-blank-screen :width width :height height)))
    (tui:paint view screen)
    (tui:screen-rows screen)))

(defun frame-has (frame text)
  (some (lambda (row) (search text row)) frame))

(define-test "streamed output becomes whole lines, however it arrives"
  ;; A line arrives in five pieces and a piece holds three lines. Drawing each
  ;; piece as it comes is how a client turns one sentence into five rows.
  (let ((view (tui:make-view)))
    ;; Written with FORMAT because a Common Lisp string has no \n escape --
    ;; "a\nb" is the seven characters a, n, b, and a test that used it would
    ;; assert on output the splitter never saw.
    (dolist (piece (list "one" " and" (format nil " two~%three~%fo") (format nil "ur~%")))
      (tui:absorb view "model.delta" (list (cons "text" piece))))
    (is equal '("one and two" "three" "four") (tui::view-lines view))
    (is string= "" (tui::view-partial view)))
  ;; An unfinished line is still shown -- it is what the model is saying now.
  (let ((view (tui:make-view)))
    (tui:absorb view "model.delta" (list (cons "text" "thinking")))
    (is equal '() (tui::view-lines view))
    (true (frame-has (frame-of view) "thinking"))))

(define-test "one frame shows sessions, output and tasks together"
  ;; This is #45's reason to exist: the three things were in three places and
  ;; the operator held the layout in their head.
  (let ((view (tui:make-view)))
    (setf (tui::view-current view) "alpha")
    (tui:absorb view "session.list"
                (list (cons "sessions" '(("alpha" . "alpha  vivarium")
                                         ("beta" . "beta   notes")))))
    (tui:absorb view "turn.started" nil)
    (tui:absorb view "model.delta" (list (cons "text" (format nil "the answer is 42~%"))))
    (tui:absorb view "tool.started" (list (cons "call" "bash npm test")))
    (tui:absorb view "task.started" (list (cons "id" "t1") (cons "text" "indexing")))
    (tui:absorb view "task.completed" (list (cons "id" "t2") (cons "text" "linted")))
    (let ((frame (frame-of view)))
      (true (frame-has frame "alpha  vivarium") "no session list")
      (true (frame-has frame "beta   notes") "the other session is missing")
      (true (frame-has frame "the answer is 42") "no output")
      (true (frame-has frame "bash npm test") "no tool call")
      (true (frame-has frame "~ indexing") "no running task")
      (true (frame-has frame "+ linted") "no finished task")
      (true (frame-has frame "working") "the turn does not look busy")
      ;; The current session is marked, not merely listed.
      (true (some (lambda (row) (search "> alpha" row)) frame)
            "the current session is not marked"))))

(define-test "a narrow pane keeps the output and drops the rest"
  ;; Where this actually lives is a tmux split, not an 80-column window. Side
  ;; panes that squeeze the output to nothing are worse than no side panes.
  (let ((view (tui:make-view)))
    (tui:absorb view "session.list" (list (cons "sessions" '(("a" . "alpha")))))
    (tui:absorb view "model.delta" (list (cons "text" (format nil "still readable~%"))))
    (let ((wide (frame-of view :width 120 :height 12))
          (narrow (frame-of view :width 40 :height 12)))
      (true (frame-has wide "tasks") "the wide frame has no task pane")
      (true (frame-has narrow "still readable") "the narrow frame lost the output")
      (false (frame-has narrow "tasks") "the task pane survived into 40 columns")))
  ;; Three rows is a status bar's worth of pane: show output, nothing else.
  (let ((view (tui:make-view)))
    (tui:absorb view "model.delta" (list (cons "text" (format nil "tiny~%"))))
    (true (frame-has (frame-of view :width 80 :height 3) "tiny"))))

(define-test "ctrl-c stops the turn, and only then leaves"
  ;; Quitting on the keystroke people use to stop a runaway command is how a
  ;; client loses a session someone was in the middle of.
  (let ((view (tui:make-view)))
    (setf (tui::view-busy view) t)
    (is eq :cancel (tui:type-key view (tui::make-key :value #\c :control t)))
    (setf (tui::view-busy view) nil)
    (is eq :quit (tui:type-key view (tui::make-key :value #\c :control t))))
  ;; Ctrl-D with something typed is not a quit -- that is a half-written prompt.
  (let ((view (tui:make-view)))
    (tui:type-key view (tui::make-key :value #\h))
    (is eq nil (tui:type-key view (tui::make-key :value #\d :control t)))
    (is eq :quit (progn (tui:type-key view (tui::make-key :value :backspace))
                        (tui:type-key view (tui::make-key :value #\d :control t))))))

(define-test "typing, sending, and what the cursor follows"
  (let ((view (tui:make-view)))
    (dolist (character (coerce "hi" 'list))
      (tui:type-key view (tui::make-key :value character)))
    (is string= "hi" (tui::view-input view))
    (true (frame-has (frame-of view) "> hi"))
    ;; The cursor sits after what was typed, not wherever the last write ended.
    (let* ((screen (tui:make-blank-screen :width 100 :height 12))
           (place (progn (tui:paint view screen) (tui:cursor-for view screen))))
      (is = 4 (cdr place) "the cursor is not after the typed text"))
    (is eq :send (tui:type-key view (tui::make-key :value :enter)))
    (is string= "hi" (tui:take-input view))
    (is string= "" (tui::view-input view))
    ;; An empty line is not a prompt worth paying for.
    (is eq nil (tui:type-key view (tui::make-key :value :enter)))))

(define-test "long lines wrap at words and scroll from the bottom"
  (is equal '("the quick" "brown fox") (tui:wrap "the quick brown fox" 10))
  ;; A word longer than the pane still has to break somewhere.
  (is equal '("abcde" "fghij") (tui:wrap "abcdefghij" 5))
  (let ((view (tui:make-view)))
    (dotimes (index 50)
      (tui:absorb view "model.delta" (list (cons "text" (format nil "line~d~%" index)))))
    ;; Following: the newest is shown without anybody asking.
    (let ((rows (tui:visible-rows view 20 5)))
      (is equal '("line45" "line46" "line47" "line48" "line49") rows))
    (tui:type-key view (tui::make-key :value :page-up))
    (let ((rows (tui:visible-rows view 20 5)))
      (is equal '("line35" "line36" "line37" "line38" "line39") rows))
    (tui:type-key view (tui::make-key :value :page-down))
    (is equal '("line45" "line46" "line47" "line48" "line49")
        (tui:visible-rows view 20 5))))

(define-test "an unknown event is ignored, not fatal"
  ;; A client one version behind its daemon should lose a feature, not fall over.
  (let ((view (tui:make-view)))
    (tui:absorb view "something.invented.later" (list (cons "text" "?")))
    (is equal '() (tui::view-lines view))
    (true (frame-of view))))
