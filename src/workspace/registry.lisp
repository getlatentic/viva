;;;; The tool registry: behaviour the organism retained, as files it can call.
;;;;
;;;; Kill criterion six settled where retained code lives. Compiling it into
;;;; the image lost 0/6 and died with the process; what survives is a script
;;;; on disk plus a manifest describing it. This file loads those into real
;;;; agent tools, so a transformation the organism worked out once is called
;;;; by name afterwards instead of re-derived.
;;;;
;;;; A registry tool is a directory: `tool.json` and whatever it runs.
;;;;
;;;;     .vivarium/tools/usage-totals/
;;;;       tool.json     name, description, parameters, exec, version
;;;;       run.py        anything executable; the language is the model's
;;;;
;;;; THE CALLING CONVENTION IS JSON ON STDIN, result on stdout. Not argv:
;;;; arguments crossing a shell is the exact class of bug this project has
;;;; already paid for twice -- a delimiter eaten once by a Lisp string and
;;;; again by sh. A JSON object on a pipe has no quoting layer to lose.
;;;;
;;;; THE MANIFEST IS JSON because parameters are nested and frontmatter
;;;; deliberately is not (see skills.lisp), and because the same object is
;;;; what an MCP export serves -- one description, two consumers.
;;;;
;;;; A malformed manifest is REFUSED WITH A REASON and produces no tool. A
;;;; half-loaded tool is worse than a missing one: the model sees a name,
;;;; calls it, and gets a failure it cannot diagnose.

(in-package #:vivarium.registry)

(defparameter *timeout* 120
  "Seconds a registry tool may run before it is killed.")

(defparameter *inherited-environment* '("PATH" "HOME" "LANG" "LC_ALL" "TMPDIR")
  "The only variables a registry tool inherits.

A WHITELIST, not a scrub list. Blacklisting credentials means enumerating
every name a provider might ever use -- a list that is wrong the moment
somebody adds one. A tool that genuinely needs a secret should be given it
as a parameter by the caller, which is visible in the transcript, rather
than by ambient inheritance, which is not.")

(defstruct (entry (:conc-name entry-))
  (name "" :type string)
  (description "" :type string)
  (version 1)
  (exec '() :type list)
  (parameters '() :type list)
  (directory "" :type string))

;;; Reading manifests

(defparameter +types+
  '(("string" . :string) ("integer" . :integer) ("number" . :number)
    ("boolean" . :boolean))
  "JSON type names to the parameter vocabulary SCHEMA:PARAMETER-SCHEMA
speaks. Scalars only for now: an unknown type is a refusal, not a guess.")

(defun field (table key)
  (and (hash-table-p table) (gethash key table)))

(defun parse-parameter (spec)
  "One manifest parameter to the (NAME TYPE DESCRIPTION &key REQUIRED-P) form
the proven schema builder already takes. Returns (values SPEC REASON)."
  (let ((name (field spec "name"))
        (type (field spec "type"))
        (description (or (field spec "description") "")))
    (cond ((not (stringp name)) (values nil "a parameter has no name"))
          ((not (stringp type)) (values nil (format nil "parameter ~a has no type" name)))
          ((not (assoc type +types+ :test #'string=))
           (values nil (format nil "parameter ~a has unsupported type ~a" name type)))
          (t (values (list name (cdr (assoc type +types+ :test #'string=))
                           description
                           :required-p (eq t (field spec "required")))
                     nil)))))

(defun parse-manifest (text directory)
  "Returns (values ENTRY REASON). Every refusal names what is wrong, because
a tool that fails to load looks exactly like a tool nobody wrote."
  (let ((table (handler-case (com.inuoe.jzon:parse text)
                 (error (condition)
                   (return-from parse-manifest
                     (values nil (format nil "tool.json is not valid JSON: ~a" condition)))))))
    (let ((name (field table "name"))
          (description (field table "description"))
          (exec (field table "exec"))
          (parameters (field table "parameters")))
      (cond
        ((not (stringp name)) (values nil "tool.json has no name"))
        ((not (every (lambda (c) (or (alphanumericp c) (member c '(#\_ #\-)))) name))
         (values nil (format nil "tool name ~s is not alphanumeric-with-dashes" name)))
        ((not (stringp description)) (values nil (format nil "~a has no description" name)))
        ((or (not (vectorp exec)) (zerop (length exec))
             (notevery #'stringp (coerce exec 'list)))
         (values nil (format nil "~a needs exec as a non-empty array of strings" name)))
        (t
         (let ((specs '()))
           (loop for spec across (or parameters #())
                 do (multiple-value-bind (parsed reason) (parse-parameter spec)
                      (unless parsed
                        (return-from parse-manifest
                          (values nil (format nil "~a: ~a" name reason))))
                      (push parsed specs)))
           (values (make-entry :name name
                               :description description
                               :version (or (field table "version") 1)
                               :exec (coerce exec 'list)
                               :parameters (nreverse specs)
                               :directory directory)
                   nil)))))))

(defun load-entries (environment directories)
  "Every tool under DIRECTORIES. Returns (values ENTRIES WARNINGS).

Later directories win by name, matching how skills and templates already
resolve: a project that ships its own `usage_totals` means its own."
  (let ((entries '()) (warnings '()))
    (dolist (directory directories)
      (dolist (info (sort (or (ignore-errors (env:list-directory environment directory)) '())
                          #'string< :key #'env:info-name))
        (when (and (eq :directory (env:info-kind info))
                   (not (a:starts-with #\. (env:info-name info))))
          (let ((manifest (env:join-path (env:info-path info) "tool.json")))
            (when (env:path-exists-p environment manifest)
              (multiple-value-bind (entry reason)
                  (parse-manifest (or (ignore-errors (env:read-text environment manifest)) "")
                                  (env:info-path info))
                (if entry
                    (setf entries (cons entry (remove (entry-name entry) entries
                                                      :key #'entry-name :test #'string=)))
                    (push (format nil "~a: ~a" manifest reason) warnings))))))))
    (values (nreverse entries) (nreverse warnings))))

;;; Running one

(defun clean-environment ()
  (loop for name in *inherited-environment*
        for value = (uiop:getenv name)
        when value collect (format nil "~a=~a" name value)))

(defun run-entry (entry arguments directory)
  "Run ENTRY with ARGUMENTS as JSON on stdin. Returns (values EXIT OUTPUT).

DIRECTORY is where the work is -- the task's own cwd, so a tool sees the
files the task sees and nothing else it was not pointed at."
  (let* ((program (first (entry-exec entry)))
         (rest (rest (entry-exec entry)))
         (payload (com.inuoe.jzon:stringify (or arguments (make-hash-table :test #'equal))))
         (output (make-string-output-stream))
         (process (sb-ext:run-program
                   program rest
                   :input (make-string-input-stream payload)
                   :output output :error output
                   :directory (entry-directory entry)
                   :environment (append (clean-environment)
                                        (list (format nil "VIVARIUM_CWD=~a" directory)))
                   :wait nil :search t))
         (deadline (+ (get-universal-time) *timeout*)))
    (loop while (eq :running (sb-ext:process-status process))
          do (when (> (get-universal-time) deadline)
               (sb-ext:process-kill process 15)
               (sb-ext:process-wait process)
               (return))
             (sleep 0.02))
    (sb-ext:process-wait process)
    (values (or (sb-ext:process-exit-code process) 1)
            (get-output-stream-string output))))

;;; Becoming tools
;;;
;;; MAKE-INSTANCE rather than DEFINE-TOOL: the macro exists to name a tool at
;;; compile time and these are discovered at run time. The class underneath is
;;; the same one, so a registry tool reaches the model through exactly the
;;; path every other tool does -- schema included, which is the only claim
;;; that matters after the fourteen-vs-nine lesson.

(defun entry-tool (entry cwd-thunk)
  (make-instance
   'tool:function-tool
   :name (entry-name entry)
   :description (entry-description entry)
   :parameters (entry-parameters entry)
   :body (lambda (arguments context)
           (declare (ignore context))
           (handler-case
               (multiple-value-bind (exit output)
                   (run-entry entry arguments (funcall cwd-thunk))
                 (if (zerop exit)
                     (tool:make-tool-result :output output)
                     (tool:make-tool-result
                      :output (format nil "~a exited ~d~@[: ~a~]"
                                      (entry-name entry) exit
                                      (and (plusp (length output)) output))
                      :error-p t)))
             ;; A tool the organism wrote is the organism's mistake to see and
             ;; fix, never the run's death.
             (error (condition)
               (tool:make-tool-result
                :output (format nil "~a could not run: ~a" (entry-name entry) condition)
                :error-p t))))))

(defun load-tools (environment directories &key cwd)
  "The registry as agent tools. Returns (values TOOLS WARNINGS)."
  (multiple-value-bind (entries warnings) (load-entries environment directories)
    (let ((cwd-thunk (or cwd (lambda () (env:env-cwd environment)))))
      (values (mapcar (lambda (entry) (entry-tool entry cwd-thunk)) entries)
              warnings))))
