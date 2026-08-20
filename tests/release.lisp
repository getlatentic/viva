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
