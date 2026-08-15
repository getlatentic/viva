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
   (templates :initarg :templates :initform '() :accessor agent-templates)
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
   (compaction :initarg :compaction :initform (compaction:make-settings)
               :accessor agent-compaction)
   (last-tokens :initform 0 :accessor agent-last-tokens)
   (active-tools :initarg :active-tools :initform nil :accessor agent-active-tools
                 :documentation "Names the model may call, or NIL for all of them.

Runtime tool control, which is Pi's setActiveTools and also the Level 2 verb this
harness lacked: an agent that can narrow or widen its own tool set has changed
how it operates, not merely what it knows.")
   (context :initform (loop*:make-context) :accessor agent-context)))

(defun available-tools (agent)
  (append (workspace:tool-set)
          (list memory:remember)
          (extension:all-tools)
          (agent-extra-tools agent)))

(defmethod agent:tools ((agent workspace-agent))
  (let ((tools (available-tools agent))
        (active (agent-active-tools agent)))
    (if active
        (remove-if-not (lambda (each) (member (tool:tool-name each) active :test #'string=)) tools)
        tools)))

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

(defun reported-tokens (message)
  (a:when-let ((usage (and message (msg:assistant-message-usage message))))
    (and (hash-table-p usage) (gethash "prompt_tokens" usage))))

(defun summary-message (summary)
  (msg:make-user-message
   :content (list (msg:make-text
                   (format nil "<earlier_conversation>~%~a~%</earlier_conversation>" summary)))))

(defun compact-now (agent &key reason)
  "Summarise the conversation so far and continue from the summary.

Returns the new context, or NIL when there was nothing to drop or an extension
declined. Costs one model request, which is why it is reached only once the
provider's own token count says the next ordinary request would not fit."
  (let* ((settings (agent-compaction agent))
         (messages (loop*:context-messages (agent-context agent)))
         (keep (compaction:retained-tail messages (compaction:settings-keep-recent settings)))
         (older (butlast messages (length keep))))
    (when (null older)
      (return-from compact-now nil))
    ;; An extension may cancel, or supply its own summary. Pi's
    ;; session_before_compact, and the reason a project can decide for itself
    ;; what survives its own compaction.
    (let ((decision (extension:fire :before-compaction
                                    (list :agent agent :older older :keep keep :reason reason))))
      (when (eq :cancel decision)
        (return-from compact-now nil))
      (let ((summary (if (stringp decision) decision (compaction:summarise agent older))))
        (when (zerop (length (string-trim '(#\Space #\Newline) (or summary ""))))
          (return-from compact-now nil))
        (a:when-let ((session (agent-session agent)))
          (session:compact session summary :keep (length keep)
                                           :tokens-before (agent-last-tokens agent)))
        (let ((context (loop*:make-context :messages (cons (summary-message summary) keep))))
          (setf (agent-context agent) context)
          (extension:fire :compaction (list :agent agent :summary summary :kept (length keep)))
          (a:when-let ((session (agent-session agent)))
            (session:append-record session :compacted
                                   "kept" (length keep) "dropped" (length older)
                                   "tokens_before" (agent-last-tokens agent)))
          context)))))

(defmethod agent:prepare-next-turn ((agent workspace-agent) message results context)
  "Where the next request is changed before it is built.

Two things happen here. Compaction, when the provider's own count says the
conversation no longer fits -- checked between turns rather than mid-request,
because that is the only moment the context can be replaced safely. And the
:CONTEXT hook, which is how a memory extension injects what it retrieved without
the harness knowing anything about retrieval."
  (declare (ignore results))
  (a:when-let ((tokens (reported-tokens message)))
    (setf (agent-last-tokens agent) tokens))
  (let* ((compacted (when (compaction:due-p (agent-compaction agent) (agent-last-tokens agent))
                      (compact-now agent :reason :threshold)))
         (current (or compacted context))
         (replacement (extension:fire :context current)))
    (cond ((and replacement (not (eq replacement context))) (list :context replacement))
          (compacted (list :context compacted)))))

(defmethod agent:emit ((agent workspace-agent) event)
  (case (getf event :type)
    (:message (a:when-let ((session (agent-session agent)))
                (session:record-entry session :message (getf event :message))))
    (:tool-start (extension:fire :before-tool event))
    (:tool-end
     (extension:fire :after-tool event)
     ;; Recorded here rather than from a :MESSAGE event, because the loop pushes
     ;; tool results straight into the context without emitting one. Without
     ;; this the transcript holds assistant messages whose tool calls have no
     ;; results -- a conversation no provider will accept, so a session that
     ;; looked saved could never be resumed. The round-trip test did not catch
     ;; it: the test recorded a tool result by hand, which is evidence about
     ;; the encoder and none at all about the caller.
     (a:when-let ((session (agent-session agent)))
       (let ((result (getf event :result)))
         (session:record-entry
          session :message
          (msg:make-tool-result-message
           :call-id (msg:tool-call-id (getf event :call))
           :output (tool:tool-result-output result)
           :error-p (tool:tool-result-error-p result))))))
    (:turn-end (extension:fire :turn-end event))
    ;; Where a run's own consequences can be acted on: everything the agent did
    ;; has happened, and nothing is waiting on the answer. Pi calls it agent_end.
    (:run-end (extension:fire :run-end event)))
  (a:when-let ((listener (agent-listener agent)))
    (funcall listener event)))

;;; Construction

(defun resource-directories (environment leaf)
  "The machine's, then the project's. Later wins, because a project that ships a
`review` template means its own."
  (list (env:join-path (uiop:native-namestring (user-homedir-pathname)) ".vivarium" leaf)
        (env:join-path (env:env-cwd environment) ".vivarium" leaf)))

(defun skill-directories (environment) (resource-directories environment "skills"))

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
            (agent-templates agent) (template:load-templates
                                     environment (resource-directories environment "prompts"))
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

(defun apply-settings (agent session)
  "Restore what the session recorded about how it was being run.

A resumed conversation with the wrong model or a wider tool set than it had is
not the same session: the transcript was produced under settings that are part
of it, and silently changing them is how a resumed run stops reproducing."
  (dolist (entry (session:entries-of session))
    (case (session:entry-kind entry)
      (:model-change
       (a:when-let ((model (gethash "model" (session:entry-payload entry))))
         (setf (agent:agent-model agent) model)))
      (:active-tools-change
       (let ((names (gethash "tools" (session:entry-payload entry))))
         (setf (agent-active-tools agent)
               (and names (plusp (length names)) (coerce names 'list))))))))

(defun resume (agent session)
  "Continue a session written earlier: rebuild the live branch into the agent's
context, and restore the settings it was run under.

SESSION may be a loaded session, a path, or a summary. The conversation
reconstructed is the one at the leaf, so a compacted session resumes from its
summary and a branched one resumes on the branch last worked on."
  (let* ((session (etypecase session
                    (session:session session)
                    (session:summary (session:load-session (session:summary-path session)))
                    ((or string pathname) (session:load-session session))))
         (messages (session:session-messages session)))
    (apply-settings agent session)
    (setf (agent-context agent) (loop*:make-context :messages messages))
    (values agent (length messages))))

(defun set-model (agent model)
  "Change the model, recording it so a resume restores this and not the default."
  (setf (agent:agent-model agent) model)
  (a:when-let ((session (agent-session agent)))
    (session:append-entry session :model-change (session:object "model" model)))
  model)

(defun set-active-tools (agent names)
  "Narrow or widen the tool set, recording it for the same reason."
  (setf (agent-active-tools agent) names)
  (a:when-let ((session (agent-session agent)))
    (session:append-entry session :active-tools-change
                          (session:object "tools" (coerce (or names '()) 'vector))))
  names)

(defun converse (agent prompts)
  "Ask each of PROMPTS in turn on one conversation. Returns the replies."
  (mapcar (lambda (prompt) (ask agent prompt)) prompts))

(defun record (kind &rest plist)
  "Write a record into the running session, from anywhere -- a tool, an
extension, a hook. Pi's appendEntry: extension bookkeeping is persisted beside
the conversation without becoming part of it.

Silently does nothing when there is no session, so an extension that traces does
not have to care whether the caller asked for a transcript."
  (a:when-let ((agent *agent*))
    (apply #'session:append-record (agent-session agent) kind plist)))

(defun harness-tool-set (agent)
  "The tool set as the model will see it on the next request."
  (agent:tools agent))
