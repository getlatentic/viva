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

(in-package #:viva.harness)

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
   ;; Files named one by one, as a config line names them, beside the
   ;; directories that are scanned whole.
   (extension-files :initarg :extension-files :initform '()
                    :accessor agent-extension-files)
   (extension-directories :initarg :extension-directories :initform '()
                          :accessor agent-extension-directories
                          :documentation "Loaded in addition to the machine's and
the project's. An extension under test should not have to be installed into the
home directory to be measured.")
   (extra-tools :initarg :extra-tools :initform '() :accessor agent-extra-tools)
   ;; Complaints from the last registry load. A tool that failed to load looks
   ;; exactly like a tool nobody wrote, so the reason is kept where a caller
   ;; can show it.
   (registry-warnings :initform '() :accessor agent-registry-warnings)
   (extra-prompt :initarg :extra-prompt :initform nil :accessor agent-extra-prompt)
   (request-limit :initarg :request-limit :initform 60 :accessor agent-request-limit
                  :documentation "Requests in one ASK before it is cut off. A cap
is required rather than tidy: an agent that cannot find the defect will read and
search until something stops it, and an uncapped run against a paid endpoint is
an unbounded bill.")
   (requests :initform 0 :accessor agent-requests)
   (last-prompt-shape :initform nil :accessor agent-last-prompt-shape
                      :documentation "The last recorded shape of the request's
system prompt, so an unchanged one is not recorded again.")
   (prompt-tokens :initform 0 :accessor agent-prompt-tokens
                  :documentation "Prompt tokens billed across this agent's whole
life, summed per request.")
   (completion-tokens :initform 0 :accessor agent-completion-tokens
                      :documentation "Completion tokens, likewise.

These exist because the experiment driver had a tokens column and wrote a
literal zero into it -- eight rows of results, every token count 0, and the
retention measurements #2 asks for read against a number nobody was recording.
A cost measure that is always zero is worse than an absent one: it looks
answered.")
   (aborting :initform nil :accessor agent-aborting
             :documentation "Set from another thread to stop the run. Checked
between streamed events as well as between turns, so an abort lands in the
request already in flight rather than after it.")
   (gate :initform (sb-concurrency:make-gate :open t) :reader agent-gate
         :documentation "Closed while the run is to be held at its next safe point.

A gate rather than a semaphore or a condition variable, because the question a
suspended run asks is `may I proceed`, not `has something happened`. A waiter
arriving after a condition variable's notification waits forever, and that race
is exactly the shape of RESUME landing before the run reaches its checkpoint.")
   (compaction :initarg :compaction :initform (compaction:make-settings)
               :accessor agent-compaction)
   (last-tokens :initform 0 :accessor agent-last-tokens)
   ;; What the context was estimated to cost when it was last measured, and
   ;; whether the gap between that and the provider's own count has already
   ;; been reported. See CHECK-CONTEXT-ACCOUNTED.
   (last-estimate :initform nil :accessor agent-last-estimate)
   (accounting-reported :initform nil :accessor agent-accounting-reported)
   (active-tools :initarg :active-tools :initform nil :accessor agent-active-tools
                 :documentation "Names the model may call, or NIL for all of them.

Runtime tool control, which is Pi's setActiveTools and also the Level 2 verb this
harness lacked: an agent that can narrow or widen its own tool set has changed
how it operates, not merely what it knows.")
   (lane :initarg :lane :initform session:+main-lane+ :accessor agent-lane
         :documentation "Which line of the session this agent writes to. A
sub-agent gets its own, so its turns land on their own branch of the same file.")
   (context :initform (loop*:make-context) :accessor agent-context)
   ;; What to say to this agent once the turn it is in has finished, or NIL.
   ;;
   ;; A CONTINUATION IS NOT A STEER AND NOT A FOLLOW-UP. A steer lands inside
   ;; the running turn; a follow-up restarts the loop without the turn ever
   ;; having ended, so nothing outside sees a turn boundary and the request
   ;; limit that bounds a turn never resets. This is neither: the turn ends
   ;; normally, everything watching sees it end, and the next one begins with
   ;; this text as its prompt. That is what makes a loop observable from the
   ;; outside and stoppable by the ordinary cancel.
   (continuation :initform nil :accessor agent-continuation)
   ;; Turns still permitted, or NIL for no bound. Counted down as they are
   ;; taken, so a bounded loop cannot be re-armed to run forever by accident.
   (continuation-left :initform nil :accessor agent-continuation-left)
   (continuation-lock :initform (bt:make-lock "viva.continuation")
                      :reader agent-continuation-lock)))

(defvar delegate-tool)  ; defined with the other tools below; referenced here

(defparameter *graduation-threshold* 3
  "Runs after which a skill's snippet is written into the registry as a tool.

Three, because two is a coincidence and the router's own rule is that code you
have ALREADY wanted again is a tool. The number is the first thing to argue
with once there is data; it is a parameter rather than a constant for exactly
that reason.")

(defun graduate (environment skill runs)
  "Write SKILL's snippet into the registry as a tool. Returns its name or NIL.

Tier 3 by evidence rather than by judgement. Three experiments showed
reflection cannot get here on its own -- once a skill exists the re-derivation
cost it would promote on is gone, so the case for a tool never accumulates.
Counting the runs is what accumulates instead.

The promoted tool TAKES NO PARAMETERS. A snippet is a procedure somebody ran,
not a function with a signature, and inventing arguments for it would be a
guess dressed as an interface. It runs, and it prints what it printed before."
  (let* ((name (skill:skill-name skill))
         (directory (env:project-path (env:env-cwd environment) "tools" name))
         (language (string-downcase (skill:skill-language skill)))
         (interpreter (cdr (assoc language skill:+interpreters+ :test #'string=)))
         (extension (if (search "python" language) "py" language)))
    ;; The threshold is checked HERE, not by the caller. A promotion function
    ;; that promotes whatever it is handed is one careless caller away from
    ;; promoting on the first run, and the rule -- code you have ALREADY wanted
    ;; again -- belongs with the thing that acts on it.
    (when (and (>= runs *graduation-threshold*)
               interpreter (skill:snippet-of skill)
               (not (env:path-exists-p environment (env:join-path directory "tool.json"))))
      ;; Through REGISTRY:REGISTER rather than writing the two files here.
      ;; One registration path means the manifest records a digest -- so a
      ;; snippet edited afterwards is reported stale instead of called -- and
      ;; means the checks #41 added apply to everything that reaches the
      ;; registry, not to whichever caller remembered them.
      (values (registry:register environment
                                 :name name
                                 :description (format nil "~a (promoted from a skill after ~d runs)"
                                                      (skill:skill-description skill) runs)
                                 :exec (list interpreter (format nil "run.~a" extension))
                                 :parameters '()
                                 :script (skill:snippet-of skill)
                                 :script-name (format nil "run.~a" extension))))))

(defun run-skill-tool (agent)
  "Run the code a tier-2 skill carries, by name, and count the run.

HERE rather than in WORKSPACE:TOOL-SET, and that placement is the whole reason
this took three attempts: it needs SKILL-DIRECTORIES, which lives in this file,
and shell.lisp loads before it. Duplicating RESOURCE-DIRECTORIES there would
have worked today and drifted tomorrow.

The count is the reuse signal (docs/tier-2-reuse-signal.md). A skill is
injected into the prompt and read, so there is no use event -- and without one,
graduation has nothing to threshold on and tier 3 is unreachable, which three
runs of experiments/tier3 demonstrated. Calling a skill makes use a fact."
  (make-instance
   'tool:function-tool
   :name "run_skill"
   :description "Run the code a skill carries, by name. Your instructions list
the skills loaded here; one that declares a language holds a runnable snippet.
Reach for this instead of retyping the same transformation."
   :parameters (list (list "name" :string "Which skill to run" :required-p t))
   :body
   (lambda (arguments context)
     (declare (ignore context))
     (let* ((environment (agent-resource-environment agent))
            (found (skill:find-skill
                    (skill:load-skills environment (skill-directories environment))
                    (gethash "name" arguments)))
            (snippet (and found (skill:snippet-of found)))
            (interpreter (and found (cdr (assoc (string-downcase (skill:skill-language found))
                                                skill:+interpreters+ :test #'string=)))))
       (cond
         ((null found)
          (tool:make-tool-result :output (format nil "No skill called ~a."
                                                 (gethash "name" arguments))
                                 :error-p t))
         ((null snippet)
          (tool:make-tool-result
           :output (format nil "~a carries no runnable snippet -- it is a skill you read."
                           (gethash "name" arguments))
           :error-p t))
         ((null interpreter)
          (tool:make-tool-result
           :output (format nil "~a declares language ~s, which cannot be run here."
                           (gethash "name" arguments) (skill:skill-language found))
           :error-p t))
         (t
          (let ((script (format nil "/tmp/viva-skill-~36r"
                                (random (expt 2 48) (make-random-state t)))))
            (unwind-protect
                 (progn
                   (with-open-file (out script :direction :output :if-exists :supersede)
                     (write-string snippet out))
                   ;; Counted BEFORE the run: a snippet that fails was still
                   ;; reached for, and reaching for it is the signal. Counting
                   ;; successes would measure the code, not the reuse.
                   (let ((runs (skill:note-use environment found)))
                     (when (>= runs *graduation-threshold*)
                       (a:when-let ((promoted (graduate (agent-environment agent) found runs)))
                         (extension:fire :custom-message
                                         (list :type "graduated" :text promoted)))))
                   (workspace:with-environment ((agent-environment agent))
                     (multiple-value-bind (text status)
                         (workspace:run-bash (format nil "~a ~a" interpreter script))
                       (if (eql 0 status)
                           text
                           (tool:make-tool-result
                            :output (format nil "~a exited ~a~%~a"
                                            (gethash "name" arguments) status text)
                            :error-p t)))))
              (ignore-errors (delete-file script))))))))))

(defun available-tools (agent)
  (append (workspace:tool-set)
          (list memory:remember delegate-tool (run-skill-tool agent))
          (extension:all-tools)
          ;; What the organism retained, as callable tools. Loaded per call
          ;; rather than cached: a tool written during this session must be
          ;; callable in the next task without a restart, which is the whole
          ;; point of retention living in files.
          (agent-registry-tools agent)
          (agent-extra-tools agent)))

(defun agent-registry-tools (agent)
  (let ((environment (agent-resource-environment agent)))
    (multiple-value-bind (tools warnings)
        (registry:load-tools environment (registry-directories environment)
                             ;; The task's cwd at CALL time, not load time.
                             :cwd (lambda () (env:env-cwd (agent-environment agent)))
                             ;; Named so the trust gate can fire: a project's
                             ;; tools are its author's code, not the user's.
                             :project (env:env-cwd environment))
      (setf (agent-registry-warnings agent) warnings)
      tools)))

(defmethod agent:tools ((agent workspace-agent))
  (let ((tools (available-tools agent))
        (active (agent-active-tools agent)))
    (if active
        (remove-if-not (lambda (each) (member (tool:tool-name each) active :test #'string=)) tools)
        tools)))

(defun extra-prompt-text (agent)
  "EXTRA-PROMPT is a string, a function returning one, or a list of either.

A FUNCTION BECAUSE WHAT A RUN CAN SAY ABOUT ITSELF CHANGES DURING THE RUN: an
organism that promotes a capability has to be able to name it in the next
request, and a string fixed when the agent was built names what was true
before the work started. BUILD-SYSTEM-PROMPT is already called per request for
this reason. Calling a function somebody else closed over teaches this layer
nothing about what is inside it."
  (a:when-let ((parts (loop for part in (a:ensure-list (agent-extra-prompt agent))
                            for text = (if (functionp part) (funcall part) part)
                            when (and (stringp text) (plusp (length text)))
                              collect text)))
    (format nil "~{~a~^~%~%~}" parts)))

(defmethod agent:system-prompt ((agent workspace-agent))
  (workspace:with-environment ((agent-environment agent))
    (workspace:build-system-prompt
     :tools (agent:tools agent)
     :skills-block (skill:prompt-block (agent-skills agent))
     :instructions-block (memory:context-block
                          (memory:context-files (agent-resource-environment agent)))
     :extra (extra-prompt-text agent)
     :cwd (env:env-cwd (agent-environment agent)))))

(defmethod agent:should-stop-after-turn ((agent workspace-agent) message results context)
  (declare (ignore message results context))
  (or (agent-aborting agent)
      (>= (incf (agent-requests agent)) (agent-request-limit agent))))

(defmethod agent:should-abort-p ((agent workspace-agent))
  (or (agent-aborting agent) (call-next-method)))

;;; The control plane
;;;
;;; Everything here is called from a thread other than the one doing the work.
;;; The work observes it at CHECKPOINT and nowhere else, so no request, tool or
;;; write is ever interrupted part way through. SB-THREAD's own manual reserves
;;; INTERRUPT-THREAD for interactive debugging, and an unwind arriving in the
;;; middle of an edit is precisely the state no restart can reason about.

(defmethod agent:cancelled-p ((agent workspace-agent))
  (and (agent-aborting agent) t))

;;; Recovery policy
;;;
;;; The two cases that are real. Not a taxonomy: a hierarchy of conditions
;;; invented before the second genuine case is a seam with nothing behind it,
;;; and the shapes here have not repeated yet.

(defparameter +model-attempts+ 3
  "Requests to the same model before trying a different one. Small, and not a
retry budget for the run: a turn makes many requests and each gets its own.")

(defmethod agent:recover ((agent workspace-agent) (condition fault:model-unavailable))
  "A provider that failed once will usually work a moment later, and a run that
died because a socket closed threw away a conversation that was perfectly
intact. So: try again, then try somewhere else, then decline and let the turn
fail honestly rather than retry forever."
  (let ((attempt (fault:fault-attempt condition)))
    (cond ((< attempt +model-attempts+)
           ;; Cancellation still lands: the sleep is short and CHECKPOINT is
           ;; reached before the retried request goes out.
           (sleep (* 0.4 attempt))
           (fault:retry condition))
          ;; Exactly once, and only at this attempt. Falling back whenever the
          ;; count is high enough looks the same and is not: switching models
          ;; makes the previous one the fallback, so two dead providers hand
          ;; the run back and forth forever, retrying without end and without
          ;; ever saying so.
          ((= attempt +model-attempts+)
           (a:when-let ((fallback (fallback-model agent)))
             (fault:use-model fallback condition)))
          ;; Declining is an answer. The turn fails, honestly and soon.
          (t nil))))

(defun fallback-model (agent)
  "Another configured model to try, or NIL. Never the one that just failed."
  (a:when-let ((other (find-if (lambda (choice)
                                 (not (equal (models:choice-model choice)
                                             (agent:agent-model agent))))
                               (ignore-errors (models:available-models)))))
    (models:choice-model other)))

(defmethod agent:checkpoint ((agent workspace-agent) phase)
  (declare (ignore phase))
  ;; Held first, then cancelled: a run suspended and then cancelled must not sit
  ;; at the gate waiting for a resume that is never coming, so CANCEL opens the
  ;; gate and this sees the abort on the way through.
  (sb-concurrency:wait-on-gate (agent-gate agent))
  (when (agent-aborting agent)
    (error 'agent:cancelled)))

(defun suspend-agent (agent)
  "Hold the run at its next safe point. Returns immediately; the run stops when
it reaches a checkpoint, which is what makes the stopping place coherent."
  (sb-concurrency:close-gate (agent-gate agent))
  t)

(defun resume-agent (agent)
  (sb-concurrency:open-gate (agent-gate agent))
  t)

(defun agent-suspended-p (agent)
  (not (sb-concurrency:gate-open-p (agent-gate agent))))

(defun cancel-agent (agent)
  "Stop the run cooperatively. Opens the gate too: a suspended run has to be
able to hear this."
  (setf (agent-aborting agent) t)
  ;; A CANCEL ENDS THE LOOP, not merely the turn inside it. Stopping a turn
  ;; that is going to be followed by another turn saying the same thing is not
  ;; stopping anything, and the person pressing the key has said plainly which
  ;; of the two they meant.
  (clear-continuation agent)
  (sb-concurrency:open-gate (agent-gate agent))
  t)

;;; Continuing on purpose
;;;
;;; The agent says what it would want asked next; the thing that owns turns
;;; asks it once this turn has ended. Kept here rather than in the daemon
;;; because it is a property of the agent -- the shell and the IPC server reach
;;; it through the same accessors -- and read under a lock because the tool
;;; that sets it runs on the worker thread while cancel arrives on another.

(defun set-continuation (agent text &key limit)
  "Arrange for TEXT to be asked once the current turn ends.

LIMIT bounds how many further turns it may cause; NIL leaves it unbounded,
which is what a loop meant to run until it is stopped needs."
  (bt:with-lock-held ((agent-continuation-lock agent))
    (setf (agent-continuation agent) text
          (agent-continuation-left agent) limit))
  text)

(defun clear-continuation (agent)
  (bt:with-lock-held ((agent-continuation-lock agent))
    (setf (agent-continuation agent) nil
          (agent-continuation-left agent) nil))
  t)

(defun continuation-of (agent)
  "(values TEXT REMAINING) without consuming it, for anything that reports."
  (bt:with-lock-held ((agent-continuation-lock agent))
    (values (agent-continuation agent) (agent-continuation-left agent))))

(defun take-continuation (agent)
  "The next prompt this loop owes, consuming one of its permitted turns.

NIL when there is none, when the budget is spent, or when the run was
cancelled -- the last because a cancelled turn must not be answered by
starting another one, and this is the single place that decision is made."
  (bt:with-lock-held ((agent-continuation-lock agent))
    (let ((text (agent-continuation agent))
          (left (agent-continuation-left agent)))
      (cond ((null text) nil)
            ((agent-aborting agent)
             (setf (agent-continuation agent) nil
                   (agent-continuation-left agent) nil)
             nil)
            ((null left) text)
            ((<= left 1)
             (setf (agent-continuation agent) nil
                   (agent-continuation-left agent) nil)
             text)
            (t (setf (agent-continuation-left agent) (1- left))
               text)))))

(defun reported-tokens (message)
  (a:when-let ((usage (and message (msg:assistant-message-usage message))))
    (and (hash-table-p usage) (gethash "prompt_tokens" usage))))

;;; Did the provider actually read what we sent it?
;;;
;;; MEASURED, BECAUSE THE ALTERNATIVE WAS A DAY. A gateway between here and the
;;; model dropped every tool result carrying a double quote: the request went
;;; out with six thousand characters of command output in it, the model was
;;; handed none of them, and the only symptom was the model saying -- patiently,
;;; six times running -- that the command had printed nothing. Nothing failed.
;;; Nothing was logged. The transcript on disk held the output in full, so
;;; every place a person would look to check said the harness was fine.
;;;
;;; The provider's own prompt count is the one number that can see this, and it
;;; was already being recorded for compaction. Comparing its GROWTH against the
;;; growth of what we appended cancels out the system prompt and the tool
;;; schemas, which no estimate here can size, and leaves exactly the question
;;; worth asking: we added this much, did the bill go up?

(defparameter *accounting-alarm-floor* 1000
  "Estimated tokens a turn must have added before a shortfall is worth saying.
Small results ride inside the noise of any estimate; content loss worth
reporting is never small.")

(defparameter *accounting-alarm-ratio* 4
  "How many times smaller the real growth must be than the estimate.

A FACTOR OF FOUR, not a few percent. Four characters per token is wrong in both
directions and a tighter threshold would cry wolf at whitespace, at a language
that tokenises densely, at a provider that counts cached tokens its own way. A
quarter is not an estimate being wrong; it is content that did not arrive.")

(defun estimated-context-tokens (context)
  (reduce #'+ (mapcar #'compaction:rough-tokens (loop*:context-messages context))
          :initial-value 0))

(defun check-context-accounted (agent message results context)
  "Say so, once, if the provider billed for far less than we sent it.

Compared as growth between two consecutive requests rather than as totals: the
system prompt and the tool schemas are most of a small request and this cannot
size either, so only the difference is a number both sides agree on.

THE CONTEXT AS SENT, not as it now stands. By the time this is asked, MESSAGE
and RESULTS have already been appended -- but the count MESSAGE carries is for
the request made before either existed, and comparing a reply's bill against a
context it never saw is a whole turn out of step."
  (let ((reported (reported-tokens message))
        (estimate (- (estimated-context-tokens context)
                     (compaction:rough-tokens message)
                     (reduce #'+ (mapcar #'compaction:rough-tokens results)
                             :initial-value 0)))
        (was-reported (agent-last-tokens agent))
        (was-estimated (agent-last-estimate agent)))
    (when (and reported was-estimated (plusp was-reported))
      (let ((grew-by (- reported was-reported))
            (expected (- estimate was-estimated)))
        (when (and (>= expected *accounting-alarm-floor*)
                   (< (* (max grew-by 0) *accounting-alarm-ratio*) expected)
                   (not (agent-accounting-reported agent)))
          (setf (agent-accounting-reported agent) t)
          (let ((detail
                  (format nil "~a billed ~d more prompt tokens for about ~d ~
tokens of new tool output. Something between here and the model is discarding ~
what tools return, so it is answering without them. Try another provider or ~
endpoint for this model."
                          (agent:agent-model agent) (max grew-by 0) expected)))
            (agent:emit agent (list :type :notice :text detail))
            (a:when-let ((session (agent-session agent)))
              (ignore-errors
               (session:append-record session :accounting
                                      "reported_growth" (max grew-by 0)
                                      "estimated_growth" expected
                                      "model" (agent:agent-model agent))))))))
    (setf (agent-last-estimate agent) estimate)))

(defun system-content-of (payload)
  "The system message's text from a request payload, or NIL."
  (a:when-let ((messages (gethash "messages" payload)))
    (loop for message across messages
          when (equal "system" (gethash "role" message))
            return (gethash "content" message))))

(defun record-prompt-shape (agent payload)
  "Record what the request ACTUALLY carried, when it changes.

Read out of the payload, never off the agent. Those agree until they do not,
and the run where they differ is the run nobody can explain -- a skills loader
can be right in-process while the prompt the model receives is missing what it
just wrote. #2 asks for that verified on the wire; this is the wire.

Written only when the shape changes, because a record per request would be
one long file saying the same thing, and what anyone wants to see is the
moment a retained skill first appears in a prompt."
  ;; The hook is global and every agent goes through it, including the plain
  ;; ones tests drive. Only a workspace agent has a session to record into.
  (a:when-let ((session (and (typep agent 'workspace-agent) (agent-session agent))))
    (let* ((content (or (system-content-of payload) ""))
           (tools (a:when-let ((declared (gethash "tools" payload)))
                    (sort (loop for tool across declared
                                for function = (gethash "function" tool)
                                when function collect (gethash "name" function))
                          #'string<)))
           ;; Names found IN the sent text, not listed from the objects it was
           ;; built from. Searching the artifact is the whole point.
           (skills (sort (loop for skill in (agent-skills agent)
                               when (search (skill:skill-name skill) content)
                                 collect (skill:skill-name skill))
                         #'string<))
           (shape (format nil "~a|~{~a,~}|~{~a,~}" (length content) skills tools)))
      (unless (equal shape (agent-last-prompt-shape agent))
        (setf (agent-last-prompt-shape agent) shape)
        (ignore-errors
         (session:append-record session :prompt
                                "characters" (length content)
                                "skills" (coerce skills 'vector)
                                "tools" (coerce tools 'vector)))))))

(defun note-usage (agent message)
  "Add one reply's reported usage to this agent's running totals.

Summed per request rather than read off the last one. The prompt is re-sent
whole every turn, so what a run COST is the sum over requests -- the final
request's prompt count is the context size, which is a different question and
was the one being answered."
  (a:when-let ((usage (and message (msg:assistant-message-usage message))))
    (when (hash-table-p usage)
      (incf (agent-prompt-tokens agent) (or (gethash "prompt_tokens" usage) 0))
      (incf (agent-completion-tokens agent) (or (gethash "completion_tokens" usage) 0)))))

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
  (note-usage agent message)
  ;; Before LAST-TOKENS moves: the check reads what the previous request was
  ;; billed, and this is the line that overwrites it.
  (check-context-accounted agent message results context)
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
        (workspace:*excluded-paths* (session-paths agent))
        ;; A running command's output goes out as it arrives, through the same
        ;; event stream everything else the agent does uses. Bound HERE and not
        ;; only around the run: a parallel batch executes each call on its own
        ;; thread, where a binding the caller made is not visible -- which is
        ;; the reason this function exists. Bound around the run alone, a
        ;; command that printed for four minutes read as a hang.
        (workspace:*on-output*
          (lambda (chunk) (agent:emit agent (list :type :tool-output :text chunk)))))
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
  ;; THE LANE TRAVELS WITH THE EVENT. A delegate hands its worker the parent's
  ;; listener, so a worker's tool calls arrive on the same stream as the
  ;; parent's with nothing to tell them apart -- and a client with two workers
  ;; running has no way to say whose call it is looking at. The agent knows;
  ;; the event did not.
  (a:when-let ((listener (agent-listener agent)))
    (funcall listener (list* :lane (agent-lane agent) event))))

;;; Construction

(defun machine-resource-directory (leaf)
  "Where resources shared across every project live: ~/.viva/<leaf>."
  (env:home-path leaf))

(defun project-resource-directory (environment leaf)
  "Where THIS project's resources live: <cwd>/.viva/<leaf>."
  (env:project-path (env:env-cwd environment) leaf))

(defun resource-directories (environment leaf)
  "The machine's, then the project's. Later wins, because a project that ships a
`review` template means its own.

Named accessors beside it because the order is load order, and `(first ...)`
reads like `the obvious one` while meaning `the user's home directory`. A test
fixture that indexed by position wrote its skills into the home of whoever ran
the suite -- and passed, because it read them back from the same place."
  (list (machine-resource-directory leaf)
        (project-resource-directory environment leaf)))

(defun skill-directories (environment) (resource-directories environment "skills"))

(defun registry-directories (environment) (resource-directories environment "tools"))

(defun refresh-resources (agent)
  "Reload skills and extensions from disk. Returns any complaints, so a caller
can show them: a skill that silently failed to load looks exactly like a skill
the model chose not to use."
  (let* ((environment (agent-resource-environment agent))
         (complaints (append
                      (extension:load-extensions
                       environment
                       :directories (append (extension:extension-directories environment)
                                            (agent-extension-directories agent)))
                      ;; AFTER the directories, so a file named in config is
                      ;; loaded last and wins where both define the same thing.
                      ;; Naming one is more deliberate than dropping it in a
                      ;; directory that gets scanned whole.
                      (extension:load-declared-files
                       environment (agent-extension-files agent)))))
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
                               extra-tools extra-prompt
                               extension-files extension-directories
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
                               :extension-files extension-files
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

(defun ask (agent text &key (reset t))
  "Send TEXT and run until the agent stops. Returns (values REPLY MESSAGES).

The conversation persists on the agent, so a second ASK continues the first.
That is what makes an interactive shell and an IPC session the same object.

RESET NIL is for a worker running a fresh agent exactly once: the default
reset exists so a reused session starts each exchange clean, but it also
ERASED a cancellation that landed between the worker being rigged and this
line -- the task stayed :cancelling in its tree while its worker ran the full
budget, which a probe caught as children stuck twenty seconds past their
cancel. A cancel must not be erasable by the thing it cancels."
  (setf (agent-requests agent) 0)
  (when reset
    (setf (agent-aborting agent) nil))
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

Shares the environment, the session, every tool including the extras, and the
model; keeps its own
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
                              ;; EXTRA-TOOLS travels too. Without it a parent
                              ;; could self-modify and its workers could not,
                              ;; while the evolution table faithfully copied
                              ;; the parent's pins into a child holding no tool
                              ;; able to resolve them. Third place in this
                              ;; codebase where extra-tools had to be threaded
                              ;; by hand and the second where it was dropped.
                              ;; EXTRA-PROMPT with it, for the same reason one
                              ;; step on: a child holding the tools and told
                              ;; nothing about what they already reach would
                              ;; rebuild what its parent could see.
                              ;;
                              ;; AND THE DECLARED FILES. A capability the
                              ;; configuration asked for is a property of the
                              ;; installation, not of one agent in it -- the
                              ;; fourth thing in this list that had to be
                              ;; threaded by hand.
                              :extra-tools (agent-extra-tools parent)
                              :extra-prompt (agent-extra-prompt parent)
                              :extension-files (agent-extension-files parent)
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
         (child (sub-agent parent lane :request-limit request-limit))
         (failed t))
    ;; Announced, because a worker running for a minute is the thing a person
    ;; is waiting on. Through the PARENT: the child publishes as this session
    ;; too, but a worker that reported its own beginning and then died would
    ;; leave the pane holding something that never ends.
    (agent:emit parent (list :type :delegate-start :worker lane :text task
                             :parent (let ((above (agent-lane parent)))
                                       (unless (equal above session:+main-lane+) above))))
    (unwind-protect
         (agent:call-in-tool-context
          child
          (lambda ()
            (let ((produced (loop*:run child (list (user-message task))
                                       :context (agent-context child))))
              (setf failed nil)
              (values (or (last-assistant-text produced) "") lane))))
      (agent:emit parent (list :type :delegate-end :worker lane :failed failed)))))

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

;;; Recording what was sent is the default, not a mode. A run whose prompt
;;; nobody can inspect afterwards is a run whose result cannot be explained,
;;; and the cost is one short record per change of shape.
(setf client:*on-request* #'record-prompt-shape)
