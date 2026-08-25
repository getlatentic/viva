;;;; Layers, dependencies pointing inward.
;;;;
;;;;   viva           the harness: messages, tools, an agent, a loop. Knows
;;;;                      nothing about what the agent is for.
;;;;   viva/workspace the ordinary world -- files, a shell, search, skills,
;;;;                      memory, extensions, sessions. What makes the harness
;;;;                      usable for real work rather than only for experiments.
;;;;   viva/image     one task domain: a live Common Lisp image the agent
;;;;                      reads, changes and rolls back.
;;;;   viva/search    scored trials and an archive over them. Works on any
;;;;                      candidate a backend can install.
;;;;
;;;; The split is so the harness can be loaded and tested without the task, and
;;;; so a second task domain does not have to be bolted onto the first. WORKSPACE
;;;; and IMAGE are two task domains over the same core and neither imports the
;;;; other.

(defsystem "viva"
  :description "An agent harness whose world is a live image rather than a directory."
  :author "Tosin Amuda"
  :license "MIT"
  :depends-on ("alexandria" "bordeaux-threads" "com.inuoe.jzon" "dexador")
  :serial t
  :components ((:module "src/core"
                :serial t
                :components ((:file "package")
                             (:file "fault")
                             (:file "wire")
                             (:file "message")
                             (:file "schema")
                             (:file "sexp")
                             (:file "tool")
                             (:file "agent")
                             (:file "provider")
                             (:file "stream")
                             (:file "client")
                             (:file "loop"))))
  :in-order-to ((test-op (test-op "viva/tests"))))

(defsystem "viva/workspace"
  :description "Ordinary work: files, search, a shell, skills, memory, extensions, sessions."
  :depends-on ("viva" "cl-ppcre" "sb-posix" "sb-concurrency" "uiop")
  :serial t
  :components ((:module "src/workspace"
                :serial t
                :components ((:file "package")
                             (:file "env")
                             (:file "auth")
                             (:file "config")
                             (:file "glob")
                             (:file "bound")
                             (:file "edit")
                             (:file "files")
                             (:file "search")
                             (:file "jobs")
                             (:file "shell")
                             (:file "prompt")
                             (:file "skills")
                             (:file "trust")
                             (:file "decay")
                             (:file "registry")
                             (:file "registration")
                             (:file "mcp")
                             (:file "memory")
                             (:file "templates")
                             (:file "extension")
                             (:file "session")
                             (:file "operation")
                             (:file "compaction")
                             (:file "models")
                             (:file "harness")
                             (:file "reflection")
                             (:file "germline")))))

(defsystem "viva/daemon"
  :description "The organism: one long-lived process, sessions living inside it."
  :depends-on ("viva/workspace" "sb-concurrency" "sb-bsd-sockets")
  :serial t
  :components ((:module "src/daemon"
                :serial t
                :components ((:file "kernel")
                             (:file "tasktree")
                             (:file "evolution")
                             (:file "package")
                             (:file "events")
                             (:file "actor")
                             (:file "evolver")
                             (:file "supervisor")
                             (:file "capability")
                             (:file "server")))))

(defsystem "viva/console"
  :description "Two ways to run the workspace agent: an interactive shell and a JSONL IPC server."
  :depends-on ("viva/workspace")
  :serial t
  :components ((:module "src/console"
                :serial t
                :components ((:file "package")
                             (:file "render")
                             (:file "shell")
                             (:file "ipc")))))

(defsystem "viva/image"
  :description "The live-image task domain: install, roll back and introspect definitions."
  :depends-on ("viva" "sb-introspect")
  :serial t
  :components ((:module "src/image"
                :serial t
                :components ((:file "package")
                             (:file "ledger")
                             (:file "image")
                             (:file "derive")
                             (:file "image-tools")
                             (:file "inspect")
                             (:file "constrained")
                             (:file "self")))))

(defsystem "viva/tasks"
  :description "The task set: a live image to repair, and the cases that score it."
  :depends-on ("viva/image")
  :serial t
  :components ((:module "src/tasks"
                :serial t
                :components ((:file "package")
                             (:file "service")
                             (:file "task")
                             (:file "state")
                             (:file "live")
                             (:file "flight")
                             (:file "capability")
                             (:file "merge")
                             (:file "control")
                             (:file "depth")
                             (:file "search")
                             (:file "impact")
                             (:file "repetition")
                             (:file "burden")
                             (:file "attempt")))))

(defsystem "viva/search"
  :description "Forked scored trials, an archive, and selection over it."
  :depends-on ("viva/image" "sb-posix")
  :serial t
  :components ((:module "src/search"
                :serial t
                :components ((:file "package")
                             (:file "trial")
                             (:file "arena")))))

(defsystem "viva/tui"
  :description "Speaking a terminal's protocols properly, without becoming one."
  :depends-on ("alexandria")
  :serial t
  :components ((:module "src/tui"
                :serial t
                :components ((:file "package")
                             (:file "keyboard")
                             (:file "mouse")
                             (:file "keys")
                             (:file "terminal")
                             (:file "screen")
                             (:file "layout")
                             (:file "size")
                             (:file "panes")
                             (:file "view")
                             (:file "chrome")
                             (:file "paint")))))

(defsystem "viva/cli"
  :description "One entry point for every run."
  :depends-on ("viva/tasks" "viva/search" "viva/console" "viva/daemon"
               "viva/tui" "uiop" "usocket" "croatoan")
  :serial t
  :components ((:module "src/cli"
                :serial t
                :components ((:file "package")
                             (:file "args")
                             (:file "arms")
                             (:file "render")
                             (:file "screen")
                             (:file "settings")
                             (:file "credentials")
                             (:file "attached")
                             (:file "commands")
                             (:file "install")
                             (:file "learned")
                             (:file "attend")
                             (:file "live")
                             (:file "main")))))

(defsystem "viva/tests"
  :depends-on ("viva" "viva/image" "viva/search" "viva/tasks"
               "viva/cli" "viva/daemon" "viva/tui" "parachute")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "suite")
                             (:file "schema")
                             (:file "sexp")
                             (:file "provider")
                             (:file "stream")
                             (:file "wire")
                             (:file "image")
                             (:file "self")
                             (:file "trial")
                             (:file "merge")
                             (:file "tasks")
                             (:file "render")
                             (:file "workspace")
                             (:file "release")
                             (:file "daemon"))))
  :perform (test-op (op c) (symbol-call :parachute :test :viva.tests)))
