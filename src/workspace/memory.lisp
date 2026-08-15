;;;; Durable instructions: what the agent is told, and what it decides to keep.
;;;;
;;;; Two directions through the same file format.
;;;;
;;;;   READ    project instructions the humans wrote -- VIVARIUM.md, AGENTS.md,
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

(in-package #:vivarium.memory)

(defparameter +context-names+ '("VIVARIUM.md" "AGENTS.md" "CLAUDE.md")
  "Checked in order; the first that exists in a directory is that directory's
instructions. AGENTS.md and CLAUDE.md are honoured because a repository that
already has one meant it for exactly this.")

(defvar *memory-file* ".vivarium/MEMORY.md"
  "Where REMEMBER appends, relative to the working directory.")

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
  (env:join-path (env:env-cwd environment) *memory-file*))

(defun context-files (environment &key (home (uiop:native-namestring (user-homedir-pathname))))
  "Every instruction file in scope, outermost first so the nearest one wins.

The agent's own memory comes last of all: something it worked out here should
override a general instruction it was given, not be overridden by one."
  (remove nil
          (append (list (directory-context environment (env:join-path home ".vivarium")))
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
        (format out "<project_instructions>~%Instructions for this project and this ~
machine. Later blocks are more specific and take precedence.~%~%")
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
  :description "Write down something worth knowing the next time you work in
this project, in a file that is loaded into your context on every future run.

Use it for what you had to work out and would otherwise work out again: how to
run the tests, a convention the code follows that is not obvious, a trap you
fell into, where a subsystem actually lives. Do not use it for what this
conversation already says, or for anything the code itself records."
  :parameters (("note" :string "One thing you learned, stated so it is useful with no memory of this conversation." :required-p t))
  (let ((path (record-memory (workspace:environment) (gethash "note" args))))
    (format nil "Noted in ~a." (workspace:display-path path))))

(defun memory-tool () remember)
