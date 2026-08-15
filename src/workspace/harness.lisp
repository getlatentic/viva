;;;; The wiring: an agent that can do ordinary work.
;;;;
;;;; This is the only file that knows about all the others, and it is the whole
;;;; of Level 1 from a caller's point of view:
;;;;
;;;;     (let ((agent (make-workspace-agent :cwd "/some/repo" :provider p :model m)))
;;;;       (ask agent "why does the parser drop trailing commas?"))
;;;;
;;;; The system prompt and the tool set are computed per request, not captured
;;;; at construction. That is what makes a run that writes a skill, records a
;;;; memory or loads an extension take effect on its own next request rather
;;;; than on the next process.

(in-package #:vivarium.harness)

(defvar *default-model* "gpt-4.1-mini")
(defvar *default-provider-name* "openai")

(defvar *agent* nil
  "The agent whose run is in progress, for the duration of ASK.

Bound so that a TOOL can reach the agent that called it. That is not a
convenience: a tool which adds a skill, registers another tool, or changes the
prompt has to be able to act on the thing it is changing, and Level 2 is exactly
the claim that such a tool can exist. Without this the only self-modification
possible is one that waits for the next process.")

(defclass workspace-agent (agent:queued-agent)
  ((environment :initarg :environment :accessor agent-environment)
   (resource-environment :initarg :resource-environment :accessor agent-resource-environment
                         :documentation "The same directory, without the root confinement.

Confinement bounds what the MODEL can reach. It must not bound what the harness
reads on its own behalf -- skills and instructions live above the working
directory and in the home directory by design, and routing those reads through
the confined environment made a rooted agent refuse to start at all, one second
in, on a path the agent had not asked for.")
   (skills :initarg :skills :initform '() :accessor agent-skills)
   (session :initarg :session :initform nil :accessor agent-session)
   (listener :initarg :listener :initform nil :accessor agent-listener
             :documentation "Called with every loop event. The shell and the IPC
mode are both just listeners, which is why neither needs a hook of its own.")
   (extensions :initarg :extensions :initform '() :accessor agent-extensions)
   (extension-directories :initarg :extension-directories :initform '()
                          :accessor agent-extension-directories
                          :documentation "Loaded in addition to the machine's and
the project's. An extension under test should not have to be installed into the
home directory to be measured.")
   (extra-tools :initarg :extra-tools :initform '() :accessor agent-extra-tools)
   (extra-prompt :initarg :extra-prompt :initform nil :accessor agent-extra-prompt)
   (request-limit :initarg :request-limit :initform 60 :accessor agent-request-limit
                  :documentation "Requests in one ASK before it is cut off. A cap
is required rather than tidy: an agent that cannot find the defect will read and
search until something stops it, and an uncapped run against a paid endpoint is
an unbounded bill.")
   (requests :initform 0 :accessor agent-requests)
   (aborting :initform nil :accessor agent-aborting
             :documentation "Set from another thread to stop the run. Checked
between streamed events as well as between turns, so an abort lands in the
request already in flight rather than after it.")
   (context :initform (loop*:make-context) :accessor agent-context)))

(defmethod agent:tools ((agent workspace-agent))
  (append (workspace:tool-set)
          (list memory:remember)
          (extension:all-tools)
          (agent-extra-tools agent)))

(defmethod agent:system-prompt ((agent workspace-agent))
  (workspace:with-environment ((agent-environment agent))
    (workspace:build-system-prompt
     :tools (agent:tools agent)
     :skills-block (skill:prompt-block (agent-skills agent))
     :instructions-block (memory:context-block
                          (memory:context-files (agent-resource-environment agent)))
     :extra (agent-extra-prompt agent)
     :cwd (env:env-cwd (agent-environment agent)))))

(defmethod agent:should-stop-after-turn ((agent workspace-agent) message results context)
  (declare (ignore message results context))
  (or (agent-aborting agent)
      (>= (incf (agent-requests agent)) (agent-request-limit agent))))

(defmethod agent:should-abort-p ((agent workspace-agent))
  (or (agent-aborting agent) (call-next-method)))

(defmethod agent:prepare-next-turn ((agent workspace-agent) message results context)
  "Where an extension gets to change what the next request will carry.

The :CONTEXT hook receives the live context and may return a replacement, which
is how a memory extension injects what it retrieved without the harness knowing
anything about retrieval."
  (declare (ignore message results))
  (a:when-let ((replacement (extension:fire :context context)))
    (unless (eq replacement context)
      (list :context replacement))))

(defmethod agent:emit ((agent workspace-agent) event)
  (case (getf event :type)
    (:message (a:when-let ((session (agent-session agent)))
                (session:record-entry session :message (getf event :message))))
    (:tool-start (extension:fire :before-tool event))
    (:tool-end (extension:fire :after-tool event))
    (:turn-end (extension:fire :turn-end event))
    ;; Where a run's own consequences can be acted on: everything the agent did
    ;; has happened, and nothing is waiting on the answer. Pi calls it agent_end.
    (:run-end (extension:fire :run-end event)))
  (a:when-let ((listener (agent-listener agent)))
    (funcall listener event)))

;;; Construction

(defun skill-directories (environment)
  (list (env:join-path (uiop:native-namestring (user-homedir-pathname)) ".vivarium" "skills")
        (env:join-path (env:env-cwd environment) ".vivarium" "skills")))

(defun refresh-resources (agent)
  "Reload skills and extensions from disk. Returns any complaints, so a caller
can show them: a skill that silently failed to load looks exactly like a skill
the model chose not to use."
  (let* ((environment (agent-resource-environment agent))
         (complaints (extension:load-extensions
                      environment
                      :directories (append (extension:extension-directories environment)
                                           (agent-extension-directories agent)))))
    (multiple-value-bind (skills warnings) (skill:load-skills environment (skill-directories environment))
      (setf (agent-skills agent) skills
            (agent-extensions agent) (extension:loaded-extensions))
      (append complaints
              (mapcar (lambda (each)
                        (format nil "~a ~a" (skill:warning-path each) (skill:warning-message each)))
                      warnings)))))

(defun make-workspace-agent (&key (cwd (uiop:native-namestring (uiop:getcwd)))
                               root provider (model *default-model*)
                               listener (request-limit 60) session
                               extra-tools extra-prompt extension-directories
                               (load-resources t)
                               (max-tokens 8192) reasoning-effort)
  "An agent pointed at a directory, with the ordinary tool set.

Returns (values AGENT COMPLAINTS): complaints are resources that failed to load,
never a reason to refuse to start."
  (let* ((environment (env:make-local-environment :cwd cwd :root root))
         (agent (make-instance 'workspace-agent
                               :environment environment
                               :resource-environment (env:make-local-environment :cwd cwd)
                               :provider provider
                               :model model
                               :max-tokens max-tokens
                               :reasoning-effort reasoning-effort
                               :listener listener
                               :session session
                               :extra-tools extra-tools
                               :extra-prompt extra-prompt
                               :extension-directories extension-directories
                               :request-limit request-limit)))
    (values agent (when load-resources (refresh-resources agent)))))

;;; Running

(defun user-message (text)
  (msg:make-user-message :content (list (msg:make-text text))))

(defun last-assistant-text (messages)
  (a:when-let ((message (find-if #'msg:assistant-message-p (reverse messages))))
    (msg:text-of message)))

(defun ask (agent text)
  "Send TEXT and run until the agent stops. Returns (values REPLY MESSAGES).

The conversation persists on the agent, so a second ASK continues the first.
That is what makes an interactive shell and an IPC session the same object."
  (setf (agent-requests agent) 0
        (agent-aborting agent) nil)
  ;; The environment is bound around the hook as well as the run: a
  ;; :BEFORE-REQUEST handler that reads a file -- which is exactly what a memory
  ;; extension does -- would otherwise fail on every request, be caught, and be
  ;; reported as a warning nobody reads.
  (let* ((produced (let ((*agent* agent))
                     (workspace:with-environment ((agent-environment agent))
                       (let ((message (extension:fire :before-request (user-message text))))
                         (loop*:run agent (list message) :context (agent-context agent)))))))
    (values (last-assistant-text produced) produced)))

(defun converse (agent prompts)
  "Ask each of PROMPTS in turn on one conversation. Returns the replies."
  (mapcar (lambda (prompt) (ask agent prompt)) prompts))

(defun harness-tool-set (agent)
  "The tool set as the model will see it on the next request."
  (agent:tools agent))
