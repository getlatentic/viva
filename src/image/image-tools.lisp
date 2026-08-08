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

(in-package #:vivarium.image-tools)

(defvar *backend* nil
  "The image these tools act on. Bound per run rather than per tool so a forked
trial child can rebind it without rebuilding the tool set.")

(defun backend ()
  (or *backend* (error "No image backend bound. Bind VIVARIUM.IMAGE-TOOLS:*BACKEND*.")))

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
  :description "Find definitions whose name contains a substring."
  :parameters (("pattern" :string "Substring to look for, case-insensitive" :required-p t))
  (let ((targets (image:find-targets (backend) (gethash "pattern" args))))
    (if targets
        (format nil "~{~a~%~}" targets)
        (format nil "Nothing matches ~s." (gethash "pattern" args)))))

;;; Shell access, kept because a live image still has to be checked from outside
;;; itself -- an HTTP request against the running app proves a change took in a
;;; way that calling the function from inside does not.

(defvar *bash-timeout* 120)

(defun run-shell (command)
  (let* ((output (make-string-output-stream))
         (process (sb-ext:run-program "/bin/sh" (list "-c" command)
                                      :output output :error output
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

(tool:define-tool bash (args context)
  :description "Run a shell command and return its combined output."
  :parameters (("command" :string "The command to run" :required-p t))
  (multiple-value-bind (code output) (run-shell (gethash "command" args))
    (let ((text (if (plusp (length output)) output "(no output)")))
      (if (zerop code)
          text
          (tool:make-tool-result :output (format nil "exit ~d~%~a" code text) :error-p t)))))

(defun tool-set ()
  "Arm A's fixed tool set, in the order Pi lists its own."
  (list read-definition install rollback find-definitions bash))

(defvar *system-prompt*
  "You change a running Common Lisp image by compiling one definition into it.
There are no files to edit and nothing restarts; state in the image is preserved
across your changes.

Read a definition before you replace it. Install exactly one top level form at a
time. If a change does not do what you expected, roll it back rather than
installing a second fix on top of it. Verify from outside the image where you
can -- a shell command that exercises the running program proves more than
calling the function yourself."
  "Kept under Pi's sub-1000-token budget on purpose: arm A is a control, and a
larger prompt would confound tool cardinality with prompt size.")
