;;;; Layers, dependencies pointing inward.
;;;;
;;;;   vivarium           the harness: messages, tools, an agent, a loop. Knows
;;;;                      nothing about what the agent is for.
;;;;   vivarium/workspace the ordinary world -- files, a shell, search, skills,
;;;;                      memory, extensions, sessions. What makes the harness
;;;;                      usable for real work rather than only for experiments.
;;;;   vivarium/image     one task domain: a live Common Lisp image the agent
;;;;                      reads, changes and rolls back.
;;;;   vivarium/search    scored trials and an archive over them. Works on any
;;;;                      candidate a backend can install.
;;;;
;;;; The split is so the harness can be loaded and tested without the task, and
;;;; so a second task domain does not have to be bolted onto the first. WORKSPACE
;;;; and IMAGE are two task domains over the same core and neither imports the
;;;; other.

(defsystem "vivarium"
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
  :in-order-to ((test-op (test-op "vivarium/tests"))))

(defsystem "vivarium/workspace"
  :description "Ordinary work: files, search, a shell, skills, memory, extensions, sessions."
  :depends-on ("vivarium" "cl-ppcre" "sb-posix" "sb-concurrency" "uiop")
  :serial t
  :components ((:module "src/workspace"
                :serial t
                :components ((:file "package")
                             (:file "env")
                             (:file "glob")
                             (:file "bound")
                             (:file "edit")
                             (:file "files")
                             (:file "search")
                             (:file "shell")
                             (:file "prompt")
                             (:file "skills")
                             (:file "memory")
                             (:file "templates")
                             (:file "extension")
                             (:file "session")
                             (:file "operation")
                             (:file "compaction")
                             (:file "models")
                             (:file "harness")))))

(defsystem "vivarium/daemon"
  :description "The organism: one long-lived process, sessions living inside it."
  :depends-on ("vivarium/workspace" "sb-concurrency" "sb-bsd-sockets")
  :serial t
  :components ((:module "src/daemon"
                :serial t
                :components ((:file "kernel")
                             (:file "package")
                             (:file "events")
                             (:file "actor")
                             (:file "server")))))

(defsystem "vivarium/console"
  :description "Two ways to run the workspace agent: an interactive shell and a JSONL IPC server."
  :depends-on ("vivarium/workspace")
  :serial t
  :components ((:module "src/console"
                :serial t
                :components ((:file "package")
                             (:file "render")
                             (:file "shell")
                             (:file "ipc")))))

(defsystem "vivarium/image"
  :description "The live-image task domain: install, roll back and introspect definitions."
  :depends-on ("vivarium" "sb-introspect")
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

(defsystem "vivarium/tasks"
  :description "The task set: a live image to repair, and the cases that score it."
  :depends-on ("vivarium/image")
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

(defsystem "vivarium/search"
  :description "Forked scored trials, an archive, and selection over it."
  :depends-on ("vivarium/image" "sb-posix")
  :serial t
  :components ((:module "src/search"
                :serial t
                :components ((:file "package")
                             (:file "trial")
                             (:file "arena")))))

(defsystem "vivarium/cli"
  :description "One entry point for every run."
  :depends-on ("vivarium/tasks" "vivarium/search" "vivarium/console" "vivarium/daemon"
               "uiop" "usocket" "croatoan")
  :serial t
  :components ((:module "src/cli"
                :serial t
                :components ((:file "package")
                             (:file "args")
                             (:file "arms")
                             (:file "render")
                             (:file "screen")
                             (:file "commands")
                             (:file "attend")
                             (:file "main")))))

(defsystem "vivarium/tests"
  :depends-on ("vivarium" "vivarium/image" "vivarium/search" "vivarium/tasks"
               "vivarium/cli" "vivarium/daemon" "parachute")
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
                             (:file "daemon"))))
  :perform (test-op (op c) (symbol-call :parachute :test :vivarium.tests)))
