;;;; A session as a long-lived actor: one mailbox, one owner, one conversation.
;;;;
;;;; The point is that a session outlives the client that started it. A message
;;;; is posted and returns immediately; the session works through its mailbox at
;;;; its own pace, and anyone interested subscribes to its events. Closing a
;;;; terminal takes away a subscriber, not the work.
;;;;
;;;; The concurrency discipline, which every actor added later must also follow:
;;;;
;;;;   ONE OWNER PER MUTABLE AUTHORITY.  The coordinator transitions state.
;;;;   Workers compute and report; they never set a field of the cell.
;;;;
;;;;   EVERY ASYNCHRONOUS OPERATION HAS AN IDENTITY.  A turn has an id, its
;;;;   completion carries that id, and control messages may name it.
;;;;
;;;;   STALE MESSAGES ARE HARMLESS.  A message about a turn that is no longer
;;;;   current is recorded and ignored rather than applied to its successor.
;;;;
;;;;   THREAD LIVENESS IS DIAGNOSTIC, NEVER BUSINESS STATE.  SBCL says
;;;;   THREAD-ALIVE-P may be stale before it returns, and a lifecycle should
;;;;   not depend on whether an OS thread has finished exiting yet.
;;;;
;;;; SB-CONCURRENCY:MAILBOX is a blocking queue over SBCL's lock-free queue --
;;;; the natural primitive here, and the reason no second async runtime is
;;;; introduced into the organism. Messages from independent producers may race;
;;;; the coordinator consuming them is what assigns authoritative order.
;;;;
;;;; Events are kept as well as published. A client that reconnects asks for
;;;; everything after the last sequence number it saw, which is what makes
;;;; reattaching different from starting again.

(in-package #:vivarium.actor)

(defstruct (cell (:conc-name cell-))
  (id "" :type string)
  (label "" :type string)
  (agent nil)
  ;; :idle :working :suspended :stopping :stuck
  (state :idle :type keyword)
  (mailbox (mailbox:make-mailbox))
  (thread nil)
  ;; THE definition of busy: the id of the turn now running, or NIL. A turn is
  ;; over when the coordinator has consumed its completion, not when its thread
  ;; happens to have exited.
  (turn nil)
  (turns 0 :type integer)
  ;; The turn's thread. A handle for diagnostics; nothing decides anything by
  ;; asking whether it is alive.
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

(defparameter +stopping-grace+ 120
  "Seconds a shutting-down session waits for its turn to report. After this the
session is STUCK, which is a state it is allowed to be in and not allowed to
describe as completed.")

(defun find-cell (id)
  (bt:with-lock-held (*registry-lock*) (gethash id *cells*)))

(defun all-cells ()
  (bt:with-lock-held (*registry-lock*)
    (sort (loop for cell being the hash-values of *cells* collect cell)
          #'string< :key #'cell-id)))

(defun resolve (cell)
  (if (stringp cell) (find-cell cell) cell))

(defmacro owning ((cell) &body body)
  "Change the cell's externally visible state under its lock.

Not mutual exclusion between writers -- there is only one writer. It is so that
a status read never catches state, turn and queue describing three different
instants. Never PUBLISH inside: publishing takes the same lock."
  `(bt:with-lock-held ((cell-lock ,cell)) ,@body))

;;; Events
;;;
;;; One linearization point. The sequence number, the stored event and the set
;;; of subscribers that will receive it are decided together, so there is a
;;; single instant before which an event belongs to history and after which it
;;; belongs to the live stream.

(defun publish (cell name data)
  "Record an event and hand it to every subscriber."
  (when (event:name-valid-p name)
    (let (event subscribers)
      (owning (cell)
        (setf event (event:make-event :name name :session (cell-id cell)
                                      :sequence (incf (cell-sequence cell))
                                      :time (get-universal-time)
                                      :data data))
        (push event (cell-events cell))
        ;; Snapshotted with the sequence rather than in a second acquisition:
        ;; between two lock takings a subscriber could arrive, replay a history
        ;; that already held this event, and then be handed it again.
        (setf subscribers (copy-list (cell-subscribers cell))))
      ;; Callbacks outside the lock. A subscriber writes to a socket, which can
      ;; block on a peer that has stopped reading, and holding a session's lock
      ;; while that happens would let one stalled terminal stop the organism.
      ;; A subscriber that signals is dropped rather than allowed to stop the
      ;; session -- a dead terminal must not take the work with it.
      (dolist (subscriber subscribers)
        (handler-case (funcall (cdr subscriber) event)
          (error () (unsubscribe cell (car subscriber)))))
      event)))

(defun subscribe (cell key handler)
  "Receive events published from now on."
  (owning (cell) (push (cons key handler) (cell-subscribers cell)))
  key)

(defun unsubscribe (cell key)
  (owning (cell)
    (setf (cell-subscribers cell)
          (remove key (cell-subscribers cell) :key #'car :test #'equal))))

(defun since (cell sequence)
  "Events after SEQUENCE, oldest first."
  (owning (cell)
    (remove-if (lambda (event) (<= (event:event-sequence event) sequence))
               (reverse (cell-events cell)))))

(defun subscribe-since (cell key sequence handler)
  "Catch up and start listening, with nothing missed and nothing repeated.

Taking the history and then subscribing loses whatever was published in
between; subscribing and then taking the history delivers those twice. Both
decisions happen in one critical section here, so SEQUENCE is a barrier: at or
below it an event is replayed, above it an event is delivered live, and no
event is on both sides or neither.

Delivery order across that barrier is not guaranteed -- the replay runs on the
subscribing thread and live events on the publishing one -- which is what
EVENT-SEQUENCE is for. Ordering by number is the reader's job; the alternative
was replaying while holding the lock, and a client that stopped reading its
socket would then stall the session."
  (let ((missed (owning (cell)
                  (push (cons key handler) (cell-subscribers cell))
                  (remove-if (lambda (event) (<= (event:event-sequence event) sequence))
                             (reverse (cell-events cell))))))
    (dolist (event missed) (funcall handler event))
    key))

(defun snapshot (cell)
  "A coherent description of the cell, taken at one instant.

Reading the fields one at a time from another thread produced status output
whose state, sequence and queue length came from three different moments."
  (owning (cell)
    (list :id (cell-id cell) :label (cell-label cell) :state (cell-state cell)
          :sequence (cell-sequence cell) :turn (cell-turn cell)
          :queued (length (cell-queued cell)) :agent (cell-agent cell))))

(defun busy-p (cell)
  "Is there a turn whose outcome the coordinator has not yet consumed?

Not THREAD-ALIVE-P. A worker that has posted its completion and exited leaves
no turn running as far as the OS is concerned, while the turn is very much
unfinished as far as this session is concerned -- and a prompt arriving in that
window used to start a second turn whose identity the first turn's late
completion then destroyed."
  (a:when-let ((cell (resolve cell)))
    (and (cell-turn cell) t)))

;;; The data plane and the control plane
;;;
;;;     coordinator            worker
;;;     -----------            ------
;;;     :user-message  ---->   model -> tools -> model
;;;     still receiving          |
;;;     :steer  ------------> steering queue, read at the next checkpoint
;;;     :cancel ------------> abort flag, read at the next checkpoint
;;;     :suspend ----------> gate closed, waited on at the next checkpoint
;;;     :finished  <-----------'  carrying the id of the turn it finished

(defparameter +terminal-events+
  '("turn.completed" "turn.cancelled" "turn.failed")
  "One of these follows each TURN.STARTED. Exactly one.")

(defun mint-turn (cell)
  "An id for a turn that has not been posted yet, so a caller can wait for its
own turn rather than for whichever turn ends first."
  (owning (cell) (format nil "~a-t~d" (cell-id cell) (incf (cell-turns cell)))))

(defun turn-outcome (agent)
  "What became of the work, asked once the work has stopped.

Not which mechanism noticed. A run ends through a checkpoint, an aborted stream
or a turn declining to take another, and only the agent knows whether any of
that was what someone asked for."
  (if (agent:cancelled-p agent) :cancelled :completed))

(defun start-turn (cell turn text)
  (owning (cell)
    (setf (cell-turn cell) turn
          (cell-state cell) :working))
  (publish cell "turn.started" (event::object "turn" turn))
  (let ((worker (bt:make-thread
                 (lambda ()
                   (multiple-value-bind (outcome detail)
                       (handler-case (progn (harness:ask (cell-agent cell) text)
                                            (turn-outcome (cell-agent cell)))
                         ;; A failed turn ends the turn, not the session. The
                         ;; organism has to survive its own bad requests or it
                         ;; is not long-lived in any sense that matters.
                         (error (condition) (values :failed (princ-to-string condition))))
                     ;; Back through the mailbox rather than publishing here:
                     ;; the terminal event belongs to the one thread that owns
                     ;; this cell's state.
                     (mailbox:send-message (cell-mailbox cell)
                                           (list :finished :turn turn
                                                           :outcome outcome
                                                           :detail detail))))
                 :name (format nil "vivarium-turn-~a" turn))))
    (owning (cell) (setf (cell-worker cell) worker)))
  turn)

(defun finish-turn (cell outcome detail)
  (let ((turn (cell-turn cell))
        (next nil))
    (owning (cell)
      (setf (cell-turn cell) nil
            (cell-worker cell) nil
            (cell-state cell) (if (eq :stopping (cell-state cell)) :stopping :idle)
            next (pop (cell-queued cell))))
    ;; Carrying the turn it ended, so a caller can wait for its own turn rather
    ;; than for whichever one finishes first.
    (publish cell (ecase outcome
                    (:completed "turn.completed")
                    (:cancelled "turn.cancelled")
                    (:failed "turn.failed"))
             (event::object "turn" turn "detail" detail))
    (cond ((eq :stopping (cell-state cell))
           ;; The last turn has reported. Nothing this session owns is running,
           ;; which is the only condition under which the session may end.
           (owning (cell) (setf (cell-running cell) nil)))
          ;; A prompt that arrived mid-turn waited rather than being lost or
          ;; running beside the turn it arrived during.
          (next (start-turn cell (car next) (cdr next))))))

(defun complete-turn (cell options)
  (let ((turn (getf options :turn)))
    (if (equal turn (cell-turn cell))
        (finish-turn cell (getf options :outcome) (getf options :detail))
        ;; A completion for a turn that is no longer current. Applying it would
        ;; clear the identity of the turn now running and publish a terminal
        ;; event for work that is still going.
        (publish cell "session.error"
                 (event::object "detail" (format nil "stale completion for turn ~a" turn))))))

(defun applies-p (cell options)
  "Whether a control message is about the present.

No :TURN means `whatever is going on now`, which is what a person at a terminal
means. A named turn is honoured only while it is current: a cancel for turn 17
arriving after 17 ended would otherwise cancel turn 18, which nobody asked for."
  (let ((turn (getf options :turn)))
    (or (null turn) (equal turn (cell-turn cell)))))

(defun current-turn-p (cell options)
  "APPLIES-P, and there is a turn to apply it to. For control that is
meaningless without running work -- steering nothing, cancelling nothing."
  (and (cell-turn cell) (applies-p cell options)))

(defun accept-prompt (cell options)
  (let ((turn (or (getf options :turn) (mint-turn cell)))
        (text (getf options :text)))
    (cond ((eq :stopping (cell-state cell))
           (publish cell "session.error"
                    (event::object "detail" "prompt refused: the session is stopping")))
          ((busy-p cell)
           (owning (cell)
             (setf (cell-queued cell) (append (cell-queued cell) (list (cons turn text))))))
          (t (start-turn cell turn text)))))

(defun begin-stopping (cell)
  "Stop accepting work and let the running turn end.

The coordinator keeps receiving. It used to leave the mailbox loop here, so the
worker's completion arrived at nobody: the session reported completed with its
last turn having published no terminal event at all."
  (owning (cell)
    (setf (cell-state cell) :stopping
          (cell-queued cell) '()))
  (harness:cancel-agent (cell-agent cell))
  ;; Nothing running, so nothing to wait for.
  (unless (cell-turn cell)
    (owning (cell) (setf (cell-running cell) nil))))

(defun handle (cell message)
  (destructuring-bind (verb &rest options) message
    (ecase verb
      (:user-message (accept-prompt cell options))
      (:finished (complete-turn cell options))

      ;; Control. Each of these reaches a turn that is still running, which is
      ;; the point of the coordinator/worker split, and each is ignored if the
      ;; turn it names has already ended.
      (:steer (when (current-turn-p cell options)
                (agent:queue-steering (cell-agent cell)
                                      (msg:make-user-message
                                       :content (list (msg:make-text (getf options :text)))))))
      ;; No event here. The loop reports the cancellation when it takes effect,
      ;; and publishing from both places would put a second terminal event on
      ;; the wire. The coordinator requests; the loop reports.
      (:cancel (when (current-turn-p cell options)
                 (harness:cancel-agent (cell-agent cell))))
      ;; Suspension outlives a turn: closing the gate with nothing running holds
      ;; whatever runs next, which is what someone stopping a session to look
      ;; at something means.
      (:suspend (when (applies-p cell options)
                  (harness:suspend-agent (cell-agent cell))
                  (owning (cell) (setf (cell-state cell) :suspended))
                  (publish cell "task.suspended" nil)))
      (:resume (when (applies-p cell options)
                 (harness:resume-agent (cell-agent cell))
                 (owning (cell)
                   (setf (cell-state cell) (if (cell-turn cell) :working :idle)))
                 (publish cell "task.resumed" nil)))
      (:shutdown (begin-stopping cell)))))

(defun next-message (cell)
  "The next message, or NIL if a stopping session waited too long for one.

A stopping session is waiting for exactly one thing -- its turn's completion --
so it is the only state in which waiting forever is a distinguishable failure
rather than an idle session behaving correctly."
  (if (eq :stopping (cell-state cell))
      (mailbox:receive-message (cell-mailbox cell) :timeout +stopping-grace+)
      (mailbox:receive-message (cell-mailbox cell))))

(defun deregister (cell)
  (bt:with-lock-held (*registry-lock*) (remhash (cell-id cell) *cells*)))

(defun run-cell (cell)
  (publish cell "session.started" (event::object "label" (cell-label cell)))
  (loop while (cell-running cell)
        do (a:if-let ((message (next-message cell)))
             (handler-case (handle cell message)
               ;; Nothing a message can do may kill the session's thread. A cell
               ;; whose thread died looks exactly like one that is merely quiet.
               (error (condition)
                 (publish cell "session.error"
                          (event::object "detail" (princ-to-string condition)))))
             (owning (cell) (setf (cell-state cell) :stuck
                                  (cell-running cell) nil))))
  (cond ((eq :stuck (cell-state cell))
         ;; Left in the registry on purpose. The session did not finish: a
         ;; worker is still out there, and SESSION.COMPLETED would be a claim
         ;; about the world that is untrue. An event name must not need a flag
         ;; saying it does not mean what it says.
         (publish cell "session.error"
                  (event::object "detail" "shutdown timed out with a turn still running")))
        (t (deregister cell)
           (publish cell "session.completed" nil))))

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
  (let ((cell (resolve cell)))
    (when cell (mailbox:send-message (cell-mailbox cell) message) t)))

(defun submit (cell text)
  "Post a prompt and return the id of the turn it will become.

Minted here rather than by the coordinator so a caller can wait for its own
turn. Waiting for `the next turn to finish` waits for somebody else's when one
is already running, and waits for the timeout when the turn fails or is
cancelled."
  (let ((cell (resolve cell)))
    (when cell
      (let ((turn (mint-turn cell)))
        (tell cell :user-message :text text :turn turn)
        turn))))

(defun terminal-for-p (event turn)
  (and (member (event:event-name event) +terminal-events+ :test #'string=)
       (equal turn (gethash "turn" (or (event:event-data event)
                                       (make-hash-table :test #'equal))))))

(defun await-turn (cell turn &key (timeout 300))
  "Wait for THIS turn to reach a terminal outcome. Returns its event name."
  (let ((cell (resolve cell))
        (done (bt:make-semaphore :count 0))
        (key (gensym "WAIT"))
        (outcome nil))
    (when cell
      (subscribe cell key (lambda (event)
                            (when (terminal-for-p event turn)
                              (setf outcome (event:event-name event))
                              (bt:signal-semaphore done :count 100))))
      (unwind-protect
           (progn
             ;; The turn may already have ended between minting and subscribing.
             (dolist (event (since cell 0))
               (when (terminal-for-p event turn)
                 (setf outcome (event:event-name event))
                 (bt:signal-semaphore done :count 100)))
             (bt:wait-on-semaphore done :timeout timeout)
             outcome)
        (unsubscribe cell key)))))

(defun ask-now (cell text &key (timeout 300))
  "Post a prompt and wait for THAT prompt's turn to finish. For callers that
are a one-shot script rather than an interface."
  (let ((cell (resolve cell)))
    (when cell
      (let ((turn (mint-turn cell))
            (done (bt:make-semaphore :count 0))
            (key (gensym "WAIT")))
        (subscribe cell key (lambda (event)
                              (when (terminal-for-p event turn)
                                (bt:signal-semaphore done :count 100))))
        (unwind-protect
             (progn (tell cell :user-message :text text :turn turn)
                    (bt:wait-on-semaphore done :timeout timeout)
                    (harness:agent-context (cell-agent cell)))
          (unsubscribe cell key))))))

(defun shutdown (cell)
  "Ask the session to end. It stops accepting work, lets its turn finish
reporting, then deregisters itself and completes."
  (let ((cell (resolve cell)))
    (when cell (tell cell :shutdown) t)))

(defun await-shutdown (cell &key (timeout 60))
  "SHUTDOWN, and wait for the session to actually be gone. For a caller that
needs the session's work to have stopped before it continues."
  (let* ((cell (resolve cell))
         (id (and cell (cell-id cell))))
    (when cell
      (shutdown cell)
      (loop repeat (ceiling timeout 0.01)
            while (find-cell id)
            do (sleep 0.01))
      (null (find-cell id)))))
