;;;; A session as a long-lived actor: one mailbox, one thread, one conversation.
;;;;
;;;; The point is that a session outlives the client that started it. A message
;;;; is posted and returns immediately; the session works through its mailbox at
;;;; its own pace, and anyone interested subscribes to its events. Closing a
;;;; terminal takes away a subscriber, not the work.
;;;;
;;;; SB-CONCURRENCY:MAILBOX is a blocking queue over SBCL's lock-free queue --
;;;; the natural primitive here, and the reason no second async runtime is
;;;; introduced into the organism.
;;;;
;;;; Events are kept as well as published. A client that reconnects asks for
;;;; everything after the last sequence number it saw, which is what makes
;;;; reattaching different from starting again.

(in-package #:vivarium.actor)

(defstruct (cell (:conc-name cell-))
  (id "" :type string)
  (label "" :type string)
  (agent nil)
  (state :idle :type keyword)
  (mailbox (mailbox:make-mailbox))
  (thread nil)
  ;; The turn's own thread. The coordinator starts it and goes back to
  ;; receiving, which is the whole difference between a control message that
  ;; affects the running turn and one that affects the turn after it.
  (worker nil)
  ;; Prompts that arrived while a turn was running, oldest first.
  (queued '() :type list)
  (lock (bt:make-lock "vivarium.cell"))
  (sequence 0 :type integer)
  (events '() :type list)
  (subscribers '() :type list)
  (running t :type boolean))

(defvar *cells* (make-hash-table :test #'equal))
(defvar *registry-lock* (bt:make-lock "vivarium.cells"))
(defvar *counter* 0)

(defun find-cell (id)
  (bt:with-lock-held (*registry-lock*) (gethash id *cells*)))

(defun all-cells ()
  (bt:with-lock-held (*registry-lock*)
    (sort (loop for cell being the hash-values of *cells* collect cell)
          #'string< :key #'cell-id)))

;;; Events

(defun publish (cell name data)
  "Record an event and hand it to every subscriber.

Kept before published, so a subscriber that arrives during a turn can still ask
for what it missed. A subscriber that signals is dropped rather than allowed to
stop the session -- a dead terminal must not take the organism with it."
  (when (event:name-valid-p name)
    (let ((event (bt:with-lock-held ((cell-lock cell))
                   (let ((event (event:make-event :name name :session (cell-id cell)
                                                  :sequence (incf (cell-sequence cell))
                                                  :time (get-universal-time)
                                                  :data data)))
                     (push event (cell-events cell))
                     event))))
      (dolist (subscriber (bt:with-lock-held ((cell-lock cell)) (copy-list (cell-subscribers cell))))
        (handler-case (funcall (cdr subscriber) event)
          (error () (unsubscribe cell (car subscriber)))))
      event)))

(defun subscribe (cell key handler)
  (bt:with-lock-held ((cell-lock cell))
    (push (cons key handler) (cell-subscribers cell)))
  key)

(defun unsubscribe (cell key)
  (bt:with-lock-held ((cell-lock cell))
    (setf (cell-subscribers cell)
          (remove key (cell-subscribers cell) :key #'car :test #'equal))))

(defun since (cell sequence)
  "Events after SEQUENCE, oldest first. How a reattaching client catches up."
  (bt:with-lock-held ((cell-lock cell))
    (remove-if (lambda (event) (<= (event:event-sequence event) sequence))
               (reverse (cell-events cell)))))

;;; The data plane and the control plane
;;;
;;; The session owns its state and one ordered stream of control messages. It
;;; does NOT have to perform the blocking work itself, and for a long time it
;;; did: HARNESS:ASK ran on the coordinator's own thread, so nothing else could
;;; be received until the turn was over. Steer, cancel and suspend all existed,
;;; were all delivered, and all of them meant `after the thing you wanted to
;;; interrupt has finished`.
;;;
;;;     coordinator            worker
;;;     -----------            ------
;;;     :user-message  ---->   model -> tools -> model
;;;     still receiving          |
;;;     :steer  ------------> steering queue, read at the next checkpoint
;;;     :cancel ------------> abort flag, read at the next checkpoint
;;;     :suspend ----------> gate closed, waited on at the next checkpoint
;;;     :finished  <-----------'
;;;
;;; So the useful invariant is not one thread per session. It is one
;;; authoritative serialization point per session: every state change happens
;;; here, on this thread, including the ones the worker asks for by posting
;;; :FINISHED back rather than mutating the cell from underneath.

(defparameter +terminal-events+
  '("turn.completed" "turn.cancelled" "turn.failed")
  "One of these follows each TURN.STARTED. Exactly one.")

(defun turn-outcome (agent)
  "What became of the work, asked once the work has stopped.

Not which mechanism noticed. A run ends through a checkpoint, an aborted stream
or a turn declining to take another, and only the agent knows whether any of
that was what someone asked for."
  (if (agent:cancelled-p agent) :cancelled :completed))

(defun start-turn (cell text)
  (setf (cell-state cell) :working)
  (publish cell "turn.started" nil)
  (setf (cell-worker cell)
        (bt:make-thread
         (lambda ()
           (multiple-value-bind (outcome detail)
               (handler-case (progn (harness:ask (cell-agent cell) text)
                                    (turn-outcome (cell-agent cell)))
                 ;; A failed turn ends the turn, not the session. The organism
                 ;; has to survive its own bad requests or it is not long-lived
                 ;; in any sense that matters.
                 (error (condition) (values :failed (princ-to-string condition))))
             ;; Back through the mailbox rather than publishing here: the
             ;; terminal event belongs to the one thread that owns this cell's
             ;; state, and two threads writing it is the race this design
             ;; exists to avoid.
             (mailbox:send-message (cell-mailbox cell) (list :finished outcome detail))))
         :name (format nil "vivarium-turn-~a" (cell-id cell)))))

(defun finish-turn (cell outcome detail)
  (setf (cell-worker cell) nil
        (cell-state cell) :idle)
  (publish cell (ecase outcome
                  (:completed "turn.completed")
                  (:cancelled "turn.cancelled")
                  (:failed "turn.failed"))
           (and detail (event::object "detail" detail)))
  ;; A prompt that arrived mid-turn waited rather than being lost or running
  ;; concurrently with the turn it arrived during.
  (a:when-let ((next (pop (cell-queued cell))))
    (start-turn cell next)))

(defun busy-p (cell)
  (let ((worker (cell-worker cell)))
    (and worker (bt:thread-alive-p worker))))

(defun handle (cell message)
  (ecase (first message)
    (:user-message
     (if (busy-p cell)
         (setf (cell-queued cell) (append (cell-queued cell) (list (second message))))
         (start-turn cell (second message))))
    (:finished (finish-turn cell (second message) (third message)))

    ;; Control. Each of these now reaches a turn that is still running, which is
    ;; the entire point of the split above.
    (:steer (agent:queue-steering (cell-agent cell)
                                  (msg:make-user-message
                                   :content (list (msg:make-text (second message))))))
    ;; No event here. The loop emits one when the cancellation actually takes
    ;; effect, and publishing from both places would put TURN.CANCELLED on the
    ;; wire twice -- the same duplication that once made a single question look
    ;; like two exchanges. The coordinator requests; the loop reports.
    (:cancel (harness:cancel-agent (cell-agent cell)))
    (:suspend
     (harness:suspend-agent (cell-agent cell))
     (setf (cell-state cell) :suspended)
     (publish cell "task.suspended" nil))
    (:resume
     (harness:resume-agent (cell-agent cell))
     (setf (cell-state cell) (if (busy-p cell) :working :idle))
     (publish cell "task.resumed" nil))
    (:shutdown
     ;; Let a running turn go, so its thread is not left parked at a gate that
     ;; nobody will ever open again.
     (harness:cancel-agent (cell-agent cell))
     (setf (cell-running cell) nil))))

(defun quiesce (cell &key (timeout 60))
  "Wait until nothing this session owns is still executing.

SESSION.COMPLETED is a claim about the world, not a note about this thread:
after it, no work belonging to the session can still write a file, call a
provider or publish an event. Announcing it while a worker was still unwinding
made the lifecycle model false, and it becomes false in a way that matters the
moment a session's own work can install code."
  (loop repeat (ceiling timeout 0.01)
        while (busy-p cell)
        do (sleep 0.01))
  (not (busy-p cell)))

(defun run-cell (cell)
  (publish cell "session.started" (event::object "label" (cell-label cell)))
  (loop while (cell-running cell)
        for message = (mailbox:receive-message (cell-mailbox cell))
        do (handler-case (handle cell message)
             ;; Nothing a message can do may kill the session's thread. A cell
             ;; whose thread died looks exactly like one that is merely quiet.
             (error (condition)
               (publish cell "session.error"
                        (event::object "detail" (princ-to-string condition))))))
  (let ((quiet (quiesce cell)))
    ;; Deregistered only once it is true that there is nothing to find. Removing
    ;; the cell when SHUTDOWN was *posted* left a session that was unreachable
    ;; and still working, which is the worst way to be wrong about this.
    (bt:with-lock-held (*registry-lock*) (remhash (cell-id cell) *cells*))
    (publish cell "session.completed"
             ;; Said out loud rather than assumed. If work outlived the wait,
             ;; the claim above is untrue and a reader must be able to see that.
             ;; Present-when-wrong rather than a boolean: jzon writes the
             ;; keyword :FALSE as the string "FALSE", and OBJECT omits NIL.
             (unless quiet (event::object "unquiesced" t)))))

(defun spawn (&key (label "") agent)
  "Start a session that outlives whoever started it."
  (let* ((id (bt:with-lock-held (*registry-lock*) (format nil "s~d" (incf *counter*))))
         (cell (make-cell :id id :label label :agent agent)))
    ;; The agent publishes through the cell, so every frontend sees the same
    ;; stream and none of them has to understand the agent loop's own events.
    (setf (harness:agent-listener agent)
          (lambda (loop-event)
            (multiple-value-bind (name data) (event:from-loop loop-event)
              (when name (publish cell name data)))))
    (bt:with-lock-held (*registry-lock*) (setf (gethash id *cells*) cell))
    (setf (cell-thread cell)
          (bt:make-thread (lambda () (run-cell cell)) :name (format nil "vivarium-~a" id)))
    cell))

(defun tell (cell &rest message)
  "Post a message and return at once. The session works at its own pace."
  (let ((cell (if (stringp cell) (find-cell cell) cell)))
    (when cell (mailbox:send-message (cell-mailbox cell) message) t)))

(defun ask-now (cell text &key (timeout 300))
  "Post a prompt and wait for the turn to finish. For callers that are a
one-shot script rather than an interface."
  (let ((cell (if (stringp cell) (find-cell cell) cell))
        (done (bt:make-semaphore :count 0))
        (key (gensym "WAIT")))
    (when cell
      (subscribe cell key (lambda (event)
                            (when (string= "turn.completed" (event:event-name event))
                              (bt:signal-semaphore done :count 100))))
      (unwind-protect
           (progn (tell cell :user-message text)
                  (bt:wait-on-semaphore done :timeout timeout)
                  (harness:agent-context (cell-agent cell)))
        (unsubscribe cell key)))))

(defun shutdown (cell)
  "Ask the session to end. It deregisters itself once its work has stopped.

Deregistering here removed the cell the moment SHUTDOWN was posted, so a
session that was still running a turn had already vanished from the registry --
unreachable and working, which is a worse state than either."
  (let ((cell (if (stringp cell) (find-cell cell) cell)))
    (when cell (tell cell :shutdown) t)))
