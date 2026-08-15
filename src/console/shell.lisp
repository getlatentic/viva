;;;; The interactive shell.
;;;;
;;;; Plain line-oriented terminal, not a full-screen TUI. A full-screen UI is
;;;; the harder thing to build and the easier thing to be trapped by: it cannot
;;;; be piped, cannot be scripted, and cannot be diffed. `vivarium shell < script`
;;;; works here, which is what makes an interactive session and a scored run the
;;;; same code path.

(in-package #:vivarium.console)

(defun build-agent (&key model cwd root listener (request-limit 60) (stream t)
                      session-directory (persist t) extra-prompt extension-directories)
  "An agent configured from the environment. Returns (values AGENT CHOICE COMPLAINTS)."
  (let* ((choice (models:resolve-model model))
         (session (when persist
                    (if session-directory
                        (session:open-session :directory session-directory)
                        (session:open-session)))))
    (multiple-value-bind (agent complaints)
        (harness:make-workspace-agent
         :cwd (or cwd (uiop:native-namestring (uiop:getcwd)))
         :root root
         :provider (models:choice-provider choice)
         :model (models:choice-model choice)
         :reasoning-effort (models:choice-effort choice)
         :listener listener
         :session session
         :extra-prompt extra-prompt
         :extension-directories extension-directories
         :request-limit request-limit)
      (setf (agent:agent-stream-p agent) stream)
      (values agent choice complaints))))

;;; Painting a run

(defstruct (view (:conc-name view-))
  (streamed-p nil :type boolean)
  (stream *standard-output* :type stream))

(defun shell-listener (view)
  (lambda (event)
    (let ((out (view-stream view)))
      (case (getf event :type)
        (:delta
         (a:when-let ((text (wire:text-field (getf event :delta) "content")))
           (when (plusp (length text))
             (setf (view-streamed-p view) t)
             (write-string text out)
             (force-output out))))
        (:message
         (let ((message (getf event :message)))
           (when (msg:assistant-message-p message)
             (if (view-streamed-p view)
                 (progn (terpri out) (setf (view-streamed-p view) nil))
                 (let ((text (msg:text-of message)))
                   (when (plusp (length text)) (format out "~a~%" text)))))))
        (:tool-start
         (format out "~a~%" (paint (format nil "  · ~a" (call-summary (getf event :call))) :cyan))
         (force-output out))
        (:tool-end
         (format out "~a~%" (result-summary (getf event :result)))
         (force-output out))))))

;;; Commands
;;;
;;; Everything an operator can do that is not a prompt. They are data rather
;;; than a COND so /help cannot drift out of step with what actually exists.

(defstruct (verb (:conc-name verb-))
  (name "" :type string) (argument "" :type string) (blurb "" :type string) (handler nil))

(defvar *running* t)

(defun show-tools (agent argument out)
  (declare (ignore argument))
  (dolist (each (agent:tools agent))
    (format out "  ~a~30t~a~%" (tool:tool-name each)
            (one-line (tool:tool-description each) :width 60))))

(defun show-skills (agent argument out)
  (declare (ignore argument))
  (if (null (harness:agent-skills agent))
      (format out "  no skills. Put a SKILL.md under .vivarium/skills/<name>/~%")
      (dolist (each (harness:agent-skills agent))
        (format out "  ~a~20t~a~%" (skill:skill-name each)
                (one-line (skill:skill-description each) :width 60)))))

(defun show-extensions (agent argument out)
  (declare (ignore argument))
  (if (null (harness:agent-extensions agent))
      (format out "  no extensions. Put a .lisp file under .vivarium/extensions/~%")
      (dolist (each (harness:agent-extensions agent))
        (format out "  ~a~20t~a~@[~%~{      tool: ~a~%~}~]~@[~{      /~a~%~}~]"
                (extension:extension-name each)
                (one-line (extension:extension-description each) :width 50)
                (mapcar #'tool:tool-name (extension:extension-tools each))
                (mapcar #'extension:command-name (extension:extension-commands each))))))

(defun run-skill (agent argument out)
  (let* ((space (position #\Space argument))
         (name (if space (subseq argument 0 space) argument))
         (extra (when space (string-trim '(#\Space) (subseq argument space))))
         (found (skill:find-skill (harness:agent-skills agent) name)))
    (if (null found)
        (format out "No skill called ~a.~%" name)
        (harness:ask agent (skill:invocation found extra)))))

(defparameter +verbs+
  (list
   (make-verb :name "help" :blurb "this list"
              :handler (lambda (agent argument out)
                         (declare (ignore agent argument))
                         (dolist (verb +verbs+)
                           (format out "  /~a~@[ ~a~]~24t~a~%" (verb-name verb)
                                   (when (plusp (length (verb-argument verb))) (verb-argument verb))
                                   (verb-blurb verb)))
                         (dolist (command (extension:all-commands))
                           (format out "  /~a~24t~a (extension)~%"
                                   (extension:command-name command)
                                   (extension:command-description command)))
                         (format out "  !COMMAND~24trun a shell command directly~%")))
   (make-verb :name "tools" :blurb "what the model can call" :handler #'show-tools)
   (make-verb :name "skills" :blurb "skills loaded from disk" :handler #'show-skills)
   (make-verb :name "extensions" :blurb "extensions loaded" :handler #'show-extensions)
   (make-verb :name "skill" :argument "NAME [instructions]" :blurb "run a skill now"
              :handler #'run-skill)
   (make-verb :name "memory" :blurb "what the agent has written down"
              :handler (lambda (agent argument out)
                         (declare (ignore argument))
                         (let ((text (memory:read-memory (harness:agent-environment agent))))
                           (format out "~a~%" (if (plusp (length text)) text "  nothing yet")))))
   (make-verb :name "reload" :blurb "re-read skills and extensions"
              :handler (lambda (agent argument out)
                         (declare (ignore argument))
                         (let ((complaints (harness:refresh-resources agent)))
                           (format out "  ~d skill(s), ~d extension(s)~{~%  ~a~}~%"
                                   (length (harness:agent-skills agent))
                                   (length (harness:agent-extensions agent))
                                   complaints))))
   (make-verb :name "trust" :blurb "allow this project's extensions to load"
              :handler (lambda (agent argument out)
                         (declare (ignore argument))
                         (let ((environment (harness:agent-environment agent)))
                           (extension:trust environment (env:env-cwd environment))
                           (format out "  trusted ~a. /reload to load its extensions.~%"
                                   (env:env-cwd environment)))))
   (make-verb :name "model" :argument "[NAME]" :blurb "show or switch the model"
              :handler (lambda (agent argument out)
                         (if (plusp (length argument))
                             (let ((choice (models:resolve-model argument)))
                               (setf (agent:agent-model agent) (models:choice-model choice)
                                     (agent:agent-provider agent) (models:choice-provider choice)
                                     (agent:agent-reasoning-effort agent) (models:choice-effort choice))
                               (format out "  now ~a~%" (models:choice-model choice)))
                             (format out "  ~a~%  available: ~{~a~^, ~}~%"
                                     (agent:agent-model agent)
                                     (mapcar #'models:choice-label (models:available-models))))))
   (make-verb :name "new" :blurb "forget this conversation, keep the workspace"
              :handler (lambda (agent argument out)
                         (declare (ignore argument))
                         (setf (harness:agent-context agent) (loop*:make-context))
                         (format out "  new conversation~%")))
   (make-verb :name "session" :blurb "where this transcript is being written"
              :handler (lambda (agent argument out)
                         (declare (ignore argument))
                         (a:if-let ((s (harness:agent-session agent)))
                           (format out "  ~a~%" (session:session-path s))
                           (format out "  not recording~%"))))
   (make-verb :name "exit" :blurb "leave"
              :handler (lambda (agent argument out)
                         (declare (ignore agent argument out))
                         (setf *running* nil))))
  "Built-in commands. Extension commands are dispatched after these.")

(defun run-verb (agent line out)
  "Handle a /command. Returns T when LINE was one."
  (let* ((body (subseq line 1))
         (space (position #\Space body))
         (name (if space (subseq body 0 space) body))
         (argument (if space (string-trim '(#\Space) (subseq body space)) ""))
         (verb (find name +verbs+ :key #'verb-name :test #'string-equal)))
    (cond (verb (funcall (verb-handler verb) agent argument out) t)
          ((extension:find-command name)
           (let ((result (funcall (extension:command-handler (extension:find-command name))
                                  agent argument)))
             (when (stringp result) (format out "~a~%" result)))
           t)
          (t (format out "No command /~a. Try /help.~%" name) t))))

;;; The loop

(defun banner (agent choice complaints out)
  (format out "~a~%" (paint "vivarium" :bold))
  (format out "  ~a via ~a~%" (models:choice-model choice) (models:choice-label choice))
  (format out "  ~a~%" (env:env-cwd (harness:agent-environment agent)))
  (format out "  ~d tools, ~d skills, ~d extensions~%"
          (length (agent:tools agent))
          (length (harness:agent-skills agent))
          (length (harness:agent-extensions agent)))
  (dolist (complaint complaints)
    (format out "~a~%" (paint (format nil "  ! ~a" complaint) :yellow)))
  (format out "  /help for commands, Ctrl-D to leave~%~%"))

(defun run-shell (&key model cwd root (in *standard-input*) (out *standard-output*)
                    (request-limit 60))
  "Read prompts from IN, run them, paint the result on OUT. Returns an exit code."
  (let ((view (make-view :stream out))
        (*running* t))
    (multiple-value-bind (agent choice complaints)
        (build-agent :model model :cwd cwd :root root
                     :listener (shell-listener view) :request-limit request-limit)
      (banner agent choice complaints out)
      (unwind-protect
           (loop while *running*
                 do (format out "~a" (paint "› " :green))
                    (force-output out)
                    (let ((line (read-line in nil nil)))
                      (cond ((null line) (setf *running* nil) (terpri out))
                            ((zerop (length (string-trim '(#\Space #\Tab) line))))
                            ((a:starts-with #\/ line) (run-verb agent line out))
                            ((a:starts-with #\! line)
                             (format out "~a~%"
                                     (workspace:with-environment ((harness:agent-environment agent))
                                       (workspace:run-bash (subseq line 1)))))
                            (t (handler-case (harness:ask agent line)
                                 (error (condition)
                                   (format out "~a~%" (paint (format nil "! ~a" condition) :red))))))))
        (a:when-let ((s (harness:agent-session agent))) (session:close-session s)))
      0)))
