;;;; Arm A's tool set: fixed schemas over a live image.
;;;;
;;;; The mapping from Pi's four file tools is deliberate. Pi's world is a
;;;; directory, so it reads, writes, edits and shells out. Here the world is a
;;;; running process, so the same four jobs are: read a definition, compile one
;;;; in, undo that, and shell out. WRITE and EDIT collapse into INSTALL because
;;;; in an image there is no difference between creating a definition and
;;;; replacing one.
;;;;
;;;; Arm B ([E5]) replaces all of this with a single EVAL tool. Both arms drive
;;;; the same backend so the comparison isolates tool cardinality rather than
;;;; tool semantics.

(in-package #:viva.image-tools)

(defvar *backend* nil
  "The image these tools act on. Bound per run rather than per tool so a forked
trial child can rebind it without rebuilding the tool set.")

(defun backend ()
  (or *backend* (error "No image backend bound. Bind VIVA.IMAGE-TOOLS:*BACKEND*.")))

(defun report-installation (result)
  (cond ((image:installation-error result)
         (tool:make-tool-result
          :output (format nil "~a failed to compile:~%~a"
                          (image:installation-target result)
                          (image:installation-error result))
          :error-p t))
        ((image:installation-warnings result)
         (format nil "Installed ~a, with warnings:~%~{  ~a~%~}"
                 (image:installation-target result)
                 (image:installation-warnings result)))
        (t (format nil "Installed ~a." (image:installation-target result)))))

(tool:define-tool read-definition (args context)
  :description "Read the source of one definition in the running image."
  :parameters (("target" :string "A definition, e.g. \"DEFUN MY-PACKAGE::ORDER-TOTAL\"" :required-p t))
  (let* ((target (gethash "target" args))
         (source (image:definition-source (backend) target)))
    (if source
        (format nil "~a~%~%~a" target source)
        ;; A bare "not found" sends the model round the same loop again. Name
        ;; what does exist so its next call can be right.
        (tool:make-tool-result
         :output (format nil "No source recorded for ~a.~@[ Known definitions: ~{~a~^, ~}~]"
                         target (image:find-targets (backend) ""))
         :error-p t))))

(tool:define-tool install (args context)
  :description "Compile one top-level definition into the running image. This is
how you change behaviour -- there are no files to edit and nothing restarts."
  :parameters (("source" :string "Exactly one top level form, e.g. (defun foo (x) ...)" :required-p t)
               ("note" :string "One line saying what this changes and why" :required-p nil))
  (handler-case
      (report-installation (image:install-definition (backend)
                                                     (gethash "source" args)
                                                     :note (gethash "note" args)))
    (image:install-error (condition)
      (tool:make-tool-result :output (image:install-error-detail condition) :error-p t))))

(tool:define-tool rollback (args context)
  :description "Undo the most recent installation of a definition, restoring the
version it replaced."
  :parameters (("target" :string "The definition to roll back" :required-p t))
  (report-installation (image:rollback-definition (backend) (gethash "target" args))))

(tool:define-tool find-definitions (args context)
  :description "List definitions in the running image. Called with no pattern it
lists EVERY definition, which is how you discover state you were not told about;
with a pattern it lists those whose name contains it."
  ;; Optional, and the description says what omitting it does. Required-with-no-
  ;; enumeration made E24 unsolvable: the only way to reach *NEGOTIATED* was to
  ;; guess the substring "negotiated", a word absent from the prompt and from
  ;; every definition the agent could read. Five runs scored `exposure NONE` and
  ;; I read that as the agent failing to search widely, when the tool surface
  ;; had no wide search in it. My own feasibility path used the empty pattern --
  ;; knowledge I had from reading FIND-TARGETS and the model did not.
  :parameters (("pattern" :string "Substring to look for, case-insensitive. Omit to list everything." :required-p nil))
  (let ((targets (image:find-targets (backend) (or (gethash "pattern" args) ""))))
    (if targets
        (format nil "~{~a~%~}" targets)
        (format nil "Nothing matches ~s." (gethash "pattern" args)))))

;;; Shell access, kept because a live image still has to be checked from outside
;;; itself -- an HTTP request against the running app proves a change took in a
;;; way that calling the function from inside does not.

(defvar *bash-timeout* 120)

(defvar *bash-directory* nil
  "Working directory for BASH, or NIL for the process's own.

Scored runs must set this. An agent given a shell on the machine that holds the
benchmark will find the benchmark: in a calibration run one listed /, found the
scratch verification scripts in /private/tmp, then ran `ps` and located the
calibration process driving it. A harness that can read its own answer key is
not measuring anything.")

(defvar *bash-commands* nil
  "When bound to a list, every command run is pushed onto it. Scored runs bind
it so a trajectory can be audited for exactly the reach described above.")

(defun run-shell (command)
  (when (listp *bash-commands*)
    (push command *bash-commands*))
  (let* ((output (make-string-output-stream))
         (process (sb-ext:run-program "/bin/sh" (list "-c" command)
                                      :output output :error output
                                      :directory *bash-directory*
                                      :wait nil :search nil))
         (deadline (+ (get-universal-time) *bash-timeout*)))
    (loop while (eq :running (sb-ext:process-status process))
          do (when (> (get-universal-time) deadline)
               (sb-ext:process-kill process 15)
               (sb-ext:process-wait process)
               (return))
             (sleep 0.05))
    (sb-ext:process-wait process)
    (values (or (sb-ext:process-exit-code process) 1)
            (get-output-stream-string output))))

(defparameter +shell-allowed-prefixes+ '("/usr/" "/bin/" "/sbin/" "/opt/" "/dev/null")
  "Absolute paths a scored command may still name: the tools themselves.")

(defun absolute-paths-in (command)
  (let ((paths '()) (start 0))
    (loop for slash = (position #\/ command :start start)
          while slash
          do (let ((end (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\" #\' #\; #\|)))
                                         command :start slash)
                            (length command))))
               (push (subseq command slash end) paths)
               (setf start end)))
    paths))

(defun escaping-paths (command directory)
  "Absolute paths the command names that lie outside DIRECTORY."
  (when directory
    (let ((jail (namestring directory)))
      (remove-if (lambda (path)
                   (or (a:starts-with-subseq jail path)
                       (some (lambda (ok) (a:starts-with-subseq ok path))
                             +shell-allowed-prefixes+)))
                 (absolute-paths-in command)))))

(tool:define-tool bash (args context)
  :description "Run a shell command and return its combined output. It runs in a
scratch directory of its own and cannot reach the rest of the filesystem."
  :parameters (("command" :string "The command to run" :required-p t))
  (let* ((command (gethash "command" args))
         (escaping (escaping-paths command *bash-directory*)))
    ;; Refused rather than sandboxed, because the sandbox is not the point. A
    ;; scored agent that reads the machine hosting its own benchmark has read
    ;; the exam: calibration caught one doing `cat src/tasks/control.lisp` --
    ;; the file holding the very cases it was being scored on -- and writing
    ;; verification scripts into the repository. The cwd jail alone does not
    ;; stop it, because an absolute path ignores the cwd.
    (if escaping
        (tool:make-tool-result
         :output (format nil "Refused: this shell only reaches its own directory.~
~%Outside it: ~{~a~^ ~}~%Nothing you need for this task lives elsewhere, and a ~
fresh process cannot see the running image in any case."
                         escaping)
         :error-p t)
        (multiple-value-bind (code output) (run-shell command)
          (let ((text (if (plusp (length output)) output "(no output)")))
            (if (zerop code)
                text
                (tool:make-tool-result :output (format nil "exit ~d~%~a" code text)
                                       :error-p t)))))))

(defun tool-set ()
  "Arm A's fixed tool set, in the order Pi lists its own."
  (list read-definition install rollback find-definitions bash))

(defvar *system-prompt*
  "You change a running Common Lisp image by compiling one definition into it.
There are no files to edit and nothing restarts; state in the image is preserved
across your changes.

Source definitions and live runtime state are both evidence. An existing
definition may be correct while objects, caches, registries or other values
created earlier are stale. Use the inspection tools when runtime state may be
part of the failure.

Installing a definition DEFINES it; it does not run it. If your repair is a
function that has to execute -- to update stored data, rebuild a cache, migrate
instances -- you must call it after installing it.

Read a definition before you replace it. Install exactly one top level form at a
time. If a change does not do what you expected, roll it back rather than
installing a second fix on top of it. Verify from outside the image where you
can -- a shell command that exercises the running program proves more than
calling the function yourself."
  "Kept under Pi's sub-1000-token budget on purpose: arm A is a control, and a
larger prompt would confound tool cardinality with prompt size.

AMENDED for B14 after E24's Gate 1 failed 0 of 5. The second paragraph is new.
The tool set had gained INSPECT_VALUE while this prompt still described a world
of reading source and installing replacements, so five runs used it 0, 0, 1, 0
and 1 times and every one left the world unrepaired.

Stated as narrowly as it was measured: ON E24, EXPOSING INSPECT_VALUE IN THE
TOOL SET WAS INSUFFICIENT TO MAKE THE AGENT USE LIVE-STATE EVIDENCE WHILE THE
PROMPT CONTINUED TO FRAME THE TASK AS SOURCE REPAIR. Not the broad claim that
registering a tool never confers a capability.

The new paragraph describes the execution model and what a baseline tool is for.
It names no variable, no defect and no strategy: a prompt saying which values to
compare would be an answer key and would destroy Gate 2 exactly as a blanket
recompute destroyed the first E24.")
