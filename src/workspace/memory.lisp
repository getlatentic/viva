;;;; Durable instructions: what the agent is told, and what it decides to keep.
;;;;
;;;; Two directions through the same file format.
;;;;
;;;;   READ    project instructions the humans wrote -- VIVA.md, AGENTS.md,
;;;;           CLAUDE.md -- gathered from the home directory down to the working
;;;;           directory, nearest last so the most specific wins.
;;;;
;;;;   WRITE   MEMORY.md, which the agent appends to itself. This is the whole
;;;;           mechanism behind "the agent learned something from a task that
;;;;           produced no artifact": the note it writes now is loaded as
;;;;           context on the next run, in a fresh window, with no transcript.
;;;;
;;;; The write side is one tool and one file on purpose. An agent that can only
;;;; persist prose can still persist a procedure, and a procedure that survives
;;;; a restart is the smallest honest instance of improvement there is.

(in-package #:viva.memory)

(defparameter +context-names+ '("VIVA.md" "AGENTS.md" "CLAUDE.md")
  "Checked in order; the first that exists in a directory is that directory's
instructions. AGENTS.md and CLAUDE.md are honoured because a repository that
already has one meant it for exactly this.")

(defvar *memory-file* "MEMORY.md"
  "Where REMEMBER appends, inside the project's viva directory.")

(defun directory-context (environment directory)
  (loop for name in +context-names+
        for path = (env:join-path directory name)
        when (env:path-exists-p environment path)
          return (a:when-let ((text (ignore-errors (env:read-text environment path))))
                   (when (plusp (length (string-trim '(#\Space #\Newline) text)))
                     (cons path text)))))

(defun ancestors (directory)
  "DIRECTORY and every directory above it, outermost first."
  (let ((chain '()) (current directory))
    (loop (push current chain)
          (let ((parent (env:parent-path current)))
            (when (string= parent current) (return))
            (setf current parent)))
    chain))

(defun memory-path (environment)
  (env:project-path (env:env-cwd environment) *memory-file*))

(defun context-files (environment &key (home (uiop:native-namestring (user-homedir-pathname))))
  "Every instruction file in scope, outermost first so the nearest one wins.

The agent's own memory comes last of all: something it worked out here should
override a general instruction it was given, not be overridden by one."
  (remove nil
          (append (list (directory-context environment (env:data-directory home)))
                  (mapcar (lambda (directory) (directory-context environment directory))
                          (ancestors (env:env-cwd environment)))
                  (let ((path (memory-path environment)))
                    (when (env:path-exists-p environment path)
                      (a:when-let ((text (ignore-errors (env:read-text environment path))))
                        (list (cons path text))))))))

(defun context-block (files)
  (if (null files)
      ""
      (with-output-to-string (out)
        ;; Saying it is already here matters: measured across 54 runs, agents
        ;; carrying memory spent 0.28-0.56 tool calls each re-opening the very
        ;; file whose contents are printed below, because `ls` shows .viva/
        ;; and an unexplained directory invites a look.
        (format out "<project_instructions>~%Instructions for this project and this ~
machine. Later blocks are more specific and take precedence. Their full contents ~
are below -- you do not need to open these files.~%~%")
        (loop for (path . content) in files
              do (format out "<instructions path=\"~a\">~%~a~%</instructions>~%~%" path content))
        (format out "</project_instructions>"))))

;;; Writing

(defun read-memory (environment)
  (let ((path (memory-path environment)))
    (if (env:path-exists-p environment path)
        (env:read-text environment path)
        "")))

(defun record-memory (environment note)
  "Append NOTE to the memory file. Returns the path written."
  (let* ((path (memory-path environment))
         (existing (read-memory environment))
         (header (if (plusp (length existing)) "" (format nil "# What I have learned working here~%~%")))
         (separator (if (and (plusp (length existing))
                             (not (a:ends-with #\Newline existing)))
                        (string #\Newline)
                        "")))
    (env:write-text environment path
                    (format nil "~a~a~a- ~a~%" existing separator header
                            (string-trim '(#\Space #\Newline) note)))
    path))

(tool:define-tool remember (args context)
  :description "Write down something about this project that will still be worth
knowing while working on something completely different here.

What you write is loaded into your context on every future run in this project,
so a note earns its place by being true of the PROJECT, not by describing
today's work: how the tests are run, a convention the code follows that is not
obvious from any one file, which directories are live and which are dead, where
a subsystem actually lives.

Do not write up the problem you just solved. That work is finished and the note
cannot help it, while a description of one defect is noise to every task that
follows. The test before writing: would someone starting an unrelated job in
this repository tomorrow want this sentence? If it is only useful to someone who
hits the same bug you just hit, leave it out."
  :parameters (("note" :string "One durable fact about this project, useful to someone with no memory of this conversation and a different task." :required-p t))
  (let ((path (record-memory (workspace:environment) (gethash "note" args))))
    (format nil "Noted in ~a." (workspace:display-path path))))

(defun memory-tool () remember)
