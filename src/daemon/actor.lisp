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

;;; The loop

(defun handle (cell message)
  (ecase (first message)
    (:user-message
     (setf (cell-state cell) :working)
     (publish cell "turn.started" nil)
     (handler-case
         (harness:ask (cell-agent cell) (second message))
       ;; A failed turn ends the turn, not the session. The organism has to
       ;; survive its own bad requests or it is not long-lived in any sense
       ;; that matters.
       (error (condition)
         (publish cell "tool.failed" (event::object "output" (princ-to-string condition)))))
     (setf (cell-state cell) :idle)
     (publish cell "turn.completed" nil))
    (:steer (agent:queue-steering (cell-agent cell)
                                  (msg:make-user-message
                                   :content (list (msg:make-text (second message))))))
    (:cancel (setf (harness:agent-aborting (cell-agent cell)) t))
    (:suspend (setf (cell-state cell) :suspended)
              (publish cell "task.suspended" nil))
    (:resume (setf (cell-state cell) :idle)
             (publish cell "task.resumed" nil))
    (:shutdown (setf (cell-running cell) nil))))

(defun run-cell (cell)
  (publish cell "session.started" (event::object "label" (cell-label cell)))
  (loop while (cell-running cell)
        for message = (mailbox:receive-message (cell-mailbox cell))
        do (handler-case (handle cell message)
             ;; Nothing a message can do may kill the session's thread. A cell
             ;; whose thread died looks exactly like one that is merely quiet.
             (error (condition)
               (publish cell "tool.failed"
                        (event::object "output" (princ-to-string condition))))))
  (publish cell "session.completed" nil))

(defun spawn (&key (label "") agent)
  "Start a session that outlives whoever started it."
  (let* ((id (bt:with-lock-held (*registry-lock*) (format nil "s~d" (incf *counter*))))
         (cell (make-cell :id id :label label :agent agent)))
    ;; The agent publishes through the cell, so every frontend sees the same
    ;; stream and none of them has to understand the agent loop's own events.
    (setf (harness:agent-listener agent)
          (lambda (loop-event)
            (multiple-value-bind (name data) (event:from-loop loop-event)
              ;; SESSION.COMPLETED belongs to the cell, not to one run of the
              ;; loop: a session that answered once is still open.
              (when (and name (not (string= name "session.completed")))
                (publish cell name data)))))
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
  (let ((cell (if (stringp cell) (find-cell cell) cell)))
    (when cell
      (tell cell :shutdown)
      (bt:with-lock-held (*registry-lock*) (remhash (cell-id cell) *cells*))
      t)))
