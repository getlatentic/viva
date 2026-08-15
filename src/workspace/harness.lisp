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
   (lane :initarg :lane :initform session:+main-lane+ :accessor agent-lane
         :documentation "Which line of the session this agent writes to. A
sub-agent gets its own, so its turns land on their own branch of the same file.")
   (context :initform (loop*:make-context) :accessor agent-context)))

(defun available-tools (agent)
  (append (workspace:tool-set)
          (list memory:remember delegate-tool)
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

(defmethod agent:call-in-tool-context ((agent workspace-agent) thunk)
  "Everything a workspace tool reads, re-established.

The one place that knows which specials a run depends on, so a parallel batch
and an ordinary one see the same world."
  (let ((*agent* agent)
        (workspace:*environment* (agent-environment agent))
        (workspace:*excluded-paths* (session-paths agent)))
    (funcall thunk)))

(defmethod agent:before-tool ((agent workspace-agent) call)
  "Let extensions refuse or rewrite a call before it runs.

The first handler to return something decides -- a veto that later handlers
could overturn would make the order of extensions load-bearing and invisible."
  (extension:decide :tool-call (list :agent agent :call call)))

(defmethod agent:after-tool ((agent workspace-agent) call result)
  (extension:decide :tool-result (list :agent agent :call call :result result)))

(defmethod agent:before-request ((agent workspace-agent) messages)
  (extension:decide :before-provider-request (list :agent agent :messages messages)))

(defmethod agent:after-response ((agent workspace-agent) message)
  (extension:decide :after-provider-response (list :agent agent :message message)))

(defmethod agent:emit ((agent workspace-agent) event)
  (case (getf event :type)
    (:message (a:when-let ((session (agent-session agent)))
                (session:append-entry session :message (getf event :message)
                                      :lane (agent-lane agent))))
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
         (session:append-entry
          session :message
          (msg:make-tool-result-message
           :call-id (msg:tool-call-id (getf event :call))
           :output (tool:tool-result-output result)
           :error-p (tool:tool-result-error-p result))
          :lane (agent-lane agent)))))
    (:turn-start (extension:fire :turn-start event))
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
    (let ((complaints (when load-resources (refresh-resources agent))))
      (let ((*agent* agent))
        (extension:fire :session-start (list :agent agent :cwd cwd)))
      (values agent complaints))))

(defun close-agent (agent)
  "End a session: let extensions write anything they were keeping, then close."
  (let ((*agent* agent))
    (extension:fire :session-end (list :agent agent)))
  (a:when-let ((session (agent-session agent)))
    (session:close-session session))
  agent)

;;; Running

(defun session-paths (agent)
  "The live transcript's directory, when it sits inside the working tree."
  (a:when-let ((session (agent-session agent)))
    ;; Canonicalised before comparing. ENV-CWD already is, so a raw session path
    ;; spelled /tmp/... never looked like it was inside a cwd spelled
    ;; /private/tmp/... and the exclusion silently did nothing.
    (let ((directory (env:canonical-directory (env:parent-path (session:session-path session))))
          (cwd (env:env-cwd (agent-environment agent))))
      (when (a:starts-with-subseq cwd directory) (list directory)))))

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
  (extension:fire :agent-start (list :agent agent :text text))
  ;; The environment is bound around the hook as well as the run: a
  ;; :BEFORE-REQUEST handler that reads a file -- which is exactly what a memory
  ;; extension does -- would otherwise fail on every request, be caught, and be
  ;; reported as a warning nobody reads.
  (let* ((produced (agent:call-in-tool-context
                    agent
                    (lambda ()
                      (let ((message (extension:fire :before-request (user-message text))))
                        (loop*:run agent (list message) :context (agent-context agent)))))))
    (extension:fire :agent-end (list :agent agent :messages produced))
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

(defun navigate (agent target &key (summarise t))
  "Move to another point in the session tree and rebuild the context there.

Optionally summarise the branch being left, and record that summary on the
branch being resumed -- otherwise the abandoned attempt's findings sit on disk
and are entirely absent from the conversation, so the model rediscovers what it
already established having been given no way to know that it did."
  (let ((session (agent-session agent)))
    (unless session (error "This agent has no session to navigate."))
    (unless (session:entry-at session target)
      (error "No entry ~a in this session." target))
    (let* ((from (session:session-leaf session))
           (leaving (and summarise from (session:abandoned-branch session from target))))
      (session:fork session target)
      (when (and leaving (rest leaving))
        (let ((messages (session:session-messages leaving)))
          (when messages
            (let ((summary (compaction:summarise agent messages)))
              (when (plusp (length (string-trim '(#\Space #\Newline) (or summary ""))))
                (session:append-branch-summary session summary :from from))))))
      (setf (agent-context agent)
            (loop*:make-context :messages (session:session-messages session)))
      (extension:fire :navigation (list :agent agent :from from :to target))
      (agent-context agent))))

(defun tree-lines (agent)
  "The session tree, one line per entry, marking branch points and the leaf."
  (a:when-let ((session (agent-session agent)))
    (let ((leaf (session:session-leaf session)))
      (loop for entry in (remove-if #'session:record-p (session:entries-of session))
            for id = (session:entry-id entry)
            collect (format nil "~a ~a ~a~a"
                            (if (equal id leaf) "*" " ")
                            id
                            (string-downcase (symbol-name (session:entry-kind entry)))
                            (let ((children (length (session:children-of session id))))
                              (if (> children 1) (format nil "  <- ~d branches" children) "")))))))

(defun send-message (custom-type text &key (display t))
  "Put TEXT into the conversation on an extension's behalf, attributed to it.

Pi's sendMessage. The alternative -- which RECALL did until this existed -- is
to return a replacement for the user's message from a :BEFORE-REQUEST handler,
which works and quietly destroys the record of what the person typed.

Appended to the live context, so it precedes the prompt being answered, and
recorded as a custom message so the transcript keeps the attribution."
  (a:when-let ((agent *agent*))
    (let ((message (msg:make-user-message :content (list (msg:make-text text)))))
      (setf (loop*:context-messages (agent-context agent))
            (append (loop*:context-messages (agent-context agent)) (list message)))
      (a:when-let ((session (agent-session agent)))
        (session:append-custom-message session custom-type message :display display))
      (a:when-let ((listener (agent-listener agent)))
        (funcall listener (list :type :custom-message :custom-type custom-type :text text)))
      message)))

(defun append-custom (custom-type data)
  "Persist extension state beside the conversation, never sending it to a model."
  (a:when-let ((agent *agent*))
    (a:when-let ((session (agent-session agent)))
      (session:append-custom session custom-type data))))

(defvar *lane-counter* 0)

(defun sub-agent (parent lane &key (request-limit 20))
  "A worker sharing PARENT's world but not its conversation.

Shares the environment, the session, the tools and the model; keeps its own
context and its own lane, so its turns are recorded in the same file on their
own branch and neither conversation is in the other's context window. That
separation is the point: a sub-agent exists to keep a search out of the main
thread, and one that inherited the transcript would defeat itself."
  ;; The parent's own class, not WORKSPACE-AGENT. A subclass that changes how
  ;; requests are made, how turns end, or what tools exist means it for its
  ;; workers too -- and a sub-agent that silently reverted to the base class
  ;; would go to the real provider from inside a test that had replaced it.
  (let ((child (make-instance (class-of parent)
                              :environment (agent-environment parent)
                              :resource-environment (agent-resource-environment parent)
                              :provider (agent:agent-provider parent)
                              :model (agent:agent-model parent)
                              :max-tokens (agent:agent-max-tokens parent)
                              :reasoning-effort (agent:agent-reasoning-effort parent)
                              :skills (agent-skills parent)
                              :templates (agent-templates parent)
                              :session (agent-session parent)
                              :listener (agent-listener parent)
                              :active-tools (agent-active-tools parent)
                              :request-limit request-limit)))
    (setf (agent-lane child) lane
          (agent-compaction child) (agent-compaction parent))
    child))

(defun delegate (parent task &key (request-limit 20))
  "Run TASK on a sub-agent and return what it concluded.

Synchronous within its own tool call. Parallelism, when it happens, comes from
the loop running a batch of calls at once -- which is why WITH-ENVIRONMENT is
re-established here rather than relied on: a dynamic binding does not cross into
a thread the loop spawned, so a delegate running in parallel would find no
environment at all and every tool would refuse."
  (let* ((lane (format nil "lane-~d" (incf *lane-counter*)))
         (child (sub-agent parent lane :request-limit request-limit)))
    (agent:call-in-tool-context
     child
     (lambda ()
       (let ((produced (loop*:run child (list (user-message task))
                                  :context (agent-context child))))
         (values (or (last-assistant-text produced) "") lane))))))

(defun delegate-async (parent task &key (request-limit 20))
  "Start a delegate and return the OPERATION rather than waiting.

The wrapper is not decoration: a spawned thread does not inherit the caller's
dynamic bindings, so without it the worker would find no environment and every
tool it called would refuse."
  (let* ((lane (format nil "lane-~d" (incf *lane-counter*)))
         (child (sub-agent parent lane :request-limit request-limit)))
    (operation:start
     (lambda ()
       (let ((produced (loop*:run child (list (user-message task))
                                  :context (agent-context child))))
         (or (last-assistant-text produced) "")))
     :label lane
     :wrapper (lambda (thunk) (agent:call-in-tool-context child thunk)))))

(tool:define-tool delegate-tool (args context)
  :name "delegate"
  :description "Hand a self-contained piece of work to a separate worker and get
back what it concluded.

The worker has the same tools and the same files, and none of this conversation
-- so it must be told everything it needs. Worth it when the work would fill
this context with material you do not need afterwards: searching a large tree
for where something lives, reading several files to answer one question,
checking a hypothesis you expect to discard. Not worth it for work whose
intermediate detail you need, because you will not see any of it."
  :parameters (("task" :string "The whole task, self-contained: what to do, where, and what to report back." :required-p t))
  (a:if-let ((agent *agent*))
    (delegate agent (gethash "task" args))
    (tool:make-tool-result :output "No agent to delegate from." :error-p t)))

(defun harness-tool-set (agent)
  "The tool set as the model will see it on the next request."
  (agent:tools agent))
