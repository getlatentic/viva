;;;; The event vocabulary: one description of what happened, for every frontend.
;;;;
;;;; The core never renders. It says what happened and something else decides
;;;; how that looks, which is what keeps a terminal client, an RPC consumer, a
;;;; browser and a test from each growing their own idea of what a turn is.
;;;;
;;;; Names are dotted and closed. A typo in an event name is otherwise a silent
;;;; message nobody receives, and the frontend that would have shown it simply
;;;; stays blank -- a failure indistinguishable from nothing having happened.

(in-package #:vivarium.event)

(defparameter +names+
  '(;; a session's life. SESSION.COMPLETED asserts that nothing this session
    ;; owns can still change the world; SESSION.ERROR does not end anything.
    "session.started" "session.completed" "session.error"
    ;; One exchange within it. Exactly ONE of the three terminal names follows
    ;; each TURN.STARTED -- a turn that reported both cancelled and completed
    ;; leaves a client no way to say what became of the work.
    "turn.started" "turn.completed" "turn.cancelled" "turn.failed"
    ;; the model
    "model.started" "model.delta" "model.completed"
    ;; tools
    "tool.started" "tool.updated" "tool.completed" "tool.failed"
    ;; harness-level suspension, which is native rather than provider-supplied
    "task.suspended" "task.resumed"
    ;; things needing a person
    "question.requested" "approval.requested"
    ;; what the organism does to itself. Not emitted yet; named now so the
    ;; frontends can be written once rather than extended per phase.
    ;;
    ;; DEACTIVATED and REVERTED are different events and collapsing them would
    ;; lose the distinction that makes task-scoped modification safe:
    ;; deactivation ends a candidate's activation for one task or session,
    ;; while reversion moves the promoted lineage back to an earlier version
    ;; for everyone.
    "improvement.created" "improvement.activated" "improvement.deactivated"
    "improvement.promoted" "improvement.reverted"
    "component.version-created" "component.activated" "component.rolled-back")
  "Every event the organism may emit. Closed on purpose.")

(defun name-valid-p (name) (and (member name +names+ :test #'string=) t))

(defstruct (event (:conc-name event-))
  (name "" :type string)
  (session "" :type string)
  ;; Monotonic per session, so a client that reconnects can ask for everything
  ;; after what it already has instead of replaying a whole conversation.
  (sequence 0 :type integer)
  (time 0 :type integer)
  (data nil))

(defun object (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          unless (null value) do (setf (gethash key table) value))
    table))

(defun call-json (call)
  (object "id" (msg:tool-call-id call)
          "name" (msg:tool-call-name call)
          "arguments" (or (msg:tool-call-arguments call) (make-hash-table :test #'equal))))

(defun from-loop (loop-event)
  "The organism's own vocabulary for one of the agent loop's events, or NIL for
one that is not worth publishing."
  (case (getf loop-event :type)
    ;; MODEL.STARTED, not TURN.STARTED. The loop's turn is one model request;
    ;; the session's turn is one exchange with a person, and they are different
    ;; things that were briefly given the same name -- so a single question
    ;; published turn.started twice and turn.completed twice, and any client
    ;; counting exchanges counted wrong.
    (:turn-start (values "model.started" nil))
    (:delta (let ((text (vivarium.wire:text-field (getf loop-event :delta) "content")))
              (when (and text (plusp (length text)))
                (values "model.delta" (object "text" text)))))
    (:message (let ((message (getf loop-event :message)))
                (when (msg:assistant-message-p message)
                  (values "model.completed"
                          (object "text" (msg:text-of message)
                                  "tool_calls" (coerce (mapcar #'call-json
                                                               (msg:tool-calls-in message))
                                                       'vector))))))
    (:tool-start (values "tool.started" (object "call" (call-json (getf loop-event :call)))))
    (:tool-end (let ((result (getf loop-event :result)))
                 (values (if (tool:tool-result-error-p result) "tool.failed" "tool.completed")
                         (object "call" (call-json (getf loop-event :call))
                                 "output" (tool:tool-result-output result)))))
    ;; A turn's terminal event is the coordinator's to publish, and it publishes
    ;; exactly one. The loop reports :RUN-END and :CANCELLED about ITS OWN run --
    ;; true statements at the wrong scope. A session that answered once is still
    ;; open, and a run that was cancelled is one outcome of one turn, so mapping
    ;; either of them here put a second terminal event on the wire.
    ((:run-end :cancelled) nil)
    (t nil)))

(defun as-json (event)
  (object "event" (event-name event)
          "session" (event-session event)
          "seq" (event-sequence event)
          "time" (event-time event)
          "data" (or (event-data event) (make-hash-table :test #'equal))))
