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
  ;; Status metadata, cell-owned. SNAPSHOT used to read these off the live
  ;; agent under the cell lock -- but the cell lock does not serialize the
  ;; agent, whose model the worker rewrites when a fallback fires. The worker
  ;; reports the model it ended with in :FINISHED and the coordinator records
  ;; it here; the snapshot never touches the agent at all.
  (model "" :type string)
  (cwd "" :type string)
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
  ;; When a stopping session gives up waiting. Absolute, not a per-receive
  ;; timeout: a timeout renewed on every message means any passing traffic --
  ;; a steer, a status request, a child's result -- postpones the deadline
  ;; indefinitely, and a broken worker is held in :STOPPING forever by a
  ;; mailbox that merely happens to be busy.
  (stop-deadline nil)
  ;; Prompts that arrived while a turn was running, oldest first.
  (queued '() :type list)
  (lock (bt:make-lock "vivarium.cell"))
  (sequence 0 :type integer)
  ;; The hot tail: a RING of the last +TAIL-LIMIT+ events, indexed by sequence
  ;; modulo the limit. A ring rather than a list because the list version
  ;; copied 4096 elements under the cell lock for every streamed delta past
  ;; the limit -- sustained allocation exactly in the long sessions this
  ;; design exists for. Anything older is served from the journal.
  (tail (make-array +tail-limit+ :initial-element nil) :type simple-vector)
  ;; The highest sequence the journal owner has confirmed on disk. Owned by
  ;; the journal owner, stored here for locality, read under the cell lock.
  ;; An event may leave everyone's hands only once its sequence is committed;
  ;; evicting first opened a window where a fast producer and a slow disk left
  ;; an event in neither memory nor the file.
  (committed 0 :type integer)
  ;; :NIL healthy; :UNREPORTED the ring overwrote an uncommitted event and the
  ;; loss has not been announced; :REPORTED it has. Degradation is a state the
  ;; session is allowed to be in and required to say out loud.
  (degraded nil)
  (flush-declared nil :type boolean)
  (journal-path "" :type string)
  (subscribers '() :type list)
  (running t :type boolean))

(defvar *cells* (make-hash-table :test #'equal))
(defvar *registry-lock* (bt:make-lock "vivarium.cells"))
(defvar *counter* 0)

(defparameter +tail-limit+ 4096
  "Events kept in memory per session. Older ones are read back from the journal.")

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

;;; The journal: an identified service, supervised
;;;
;;;     cells --(:append)--> JOURNAL SERVICE ----> one JSONL file per session
;;;                              |        \------> commits the watermark
;;;                         exit boundary
;;;                              |
;;;                        supervisor: restart as a new generation,
;;;                        re-post whatever was not yet committed
;;;
;;; ONE owner for the whole image, not one per session. Whether the service
;;; exists is a STATE it owns, never a THREAD-ALIVE-P answer -- SBCL says that
;;; answer can be stale before it returns, and deciding service truth from it
;;; is the exact pattern BUSY-P was cured of. The owner's thread exits through
;;; a boundary that reports to the supervisor; the supervisor verifies the
;;; generation, restarts, and re-posts every cell's uncommitted ring events to
;;; the new generation, so an owner death loses nothing that was still in
;;; memory. Appends offered while no generation is available are dropped and
;;; the ring's no-evict-before-commit machinery declares the degradation.

(defvar *journal-root*
  (namestring (merge-pathnames ".vivarium/journal/" (user-homedir-pathname)))
  "Where session journals live. Tests point this at a temporary directory;
they wrote 26MB into the real home before it was configurable.")

(defstruct (journal-service (:conc-name journal-))
  (id 0 :type integer)
  (mailbox (mailbox:make-mailbox))
  (thread nil)
  ;; :available | :failed  -- owned state, written under *JOURNAL-LOCK*.
  (state :available))

(defvar *journal-service* nil "The current generation, or NIL.")
(defvar *journal-lock* (bt:make-lock "vivarium.journal"))
(defvar *journal-generation* 0)

(defparameter *flush-grace* 30
  "Seconds one flush attempt waits for the journal's confirmation.")

(defparameter +journal-high-water+ 100000
  "Appends the journal may fall behind by before new ones are refused.

An unbounded queue in front of a disk is an allocation with a delay on it: a
publisher that outruns the writer for long enough exhausts the heap -- found
empirically, as a GC crash under a flat-out publisher, not imagined. Refused
appends stay in the ring uncommitted, and the ring declares the degradation
if it is ever forced to evict them.")

(defun journal-path-for (id)
  (format nil "~a~a-~d.jsonl" *journal-root* id (get-universal-time)))

(defun journal-post (message)
  "Offer MESSAGE to the current journal generation. Returns T if accepted.

No lock: a single special read and a lock-free send, because PUBLISH calls
this while holding a cell's lock and must not nest another. A message offered
to a generation that is failed or mid-restart is refused, and refusal is an
answer the caller can act on."
  (let ((service *journal-service*))
    (when (and service
               (eq :available (journal-state service))
               (< (mailbox:mailbox-count (journal-mailbox service))
                  +journal-high-water+))
      (mailbox:send-message (journal-mailbox service) message)
      t)))

(defun run-journal-owner (service)
  (let ((streams (make-hash-table :test #'equal))
        (troubled (make-hash-table :test #'equal)))
    (unwind-protect
         ;; HANDLER-CASE as well as UNWIND-PROTECT: unwinding cleans up but
         ;; does not CATCH, and under `sbcl --script` an unhandled condition in
         ;; any thread quits the whole process -- the first owner-death test
         ;; did not fail, it took the organism with it.
         (handler-case
         (flet ((stream-for (cell)
                  (or (gethash (cell-id cell) streams)
                      (setf (gethash (cell-id cell) streams)
                            (open (cell-journal-path cell) :direction :output
                                  :if-exists :append :if-does-not-exist :create
                                  :external-format :utf-8)))))
           (loop for message = (mailbox:receive-message (journal-mailbox service))
                 until (eq message :shutdown)
                 do (destructuring-bind (verb cell &optional extra) message
                      (ecase verb
                        (:append
                         (handler-case
                             (let ((out (stream-for cell)))
                               (write-line (jzon:stringify (event:as-json extra)) out)
                               (force-output out)
                               ;; The acknowledgement. Only now may the ring
                               ;; let this event go. The committed watermark is
                               ;; journal-owned state stored on the cell for
                               ;; locality; only this thread writes it.
                               (owning (cell)
                                 (setf (cell-committed cell)
                                       (max (cell-committed cell)
                                            (event:event-sequence extra)))))
                           (error (condition)
                             ;; Announced through the cell's coordinator, once
                             ;; per episode -- not swallowed, and not a message
                             ;; per failed write when a full disk fails
                             ;; thousands.
                             (unless (gethash (cell-id cell) troubled)
                               (setf (gethash (cell-id cell) troubled) t)
                               (tell cell :journal-failed
                                     :detail (princ-to-string condition))))))
                        ;; FIFO: every :append queued before this marker has
                        ;; been processed, so signalling confirms them written.
                        ;; :SYNC confirms for a reader; :CLOSE also retires the
                        ;; session's stream.
                        (:sync (when extra (bt:signal-semaphore extra :count 1000)))
                        (:close
                         (a:when-let ((out (gethash (cell-id cell) streams)))
                           (ignore-errors (close out))
                           (remhash (cell-id cell) streams))
                         (remhash (cell-id cell) troubled)
                         (when extra (bt:signal-semaphore extra :count 1000)))))))
           (error () nil))
      ;; However this thread ends -- :shutdown or a condition -- the streams
      ;; are closed and the supervisor hears about it with the generation
      ;; attached, so it can never confuse this death with a successor's.
      (loop for out being the hash-values of streams
            do (ignore-errors (close out)))
      (journal-owner-exited service))))

(defun journal-owner-exited (service)
  "The exit boundary: verify the generation, then decide.

Policy is restart -- the failure that killed one write burst is rarely
permanent -- and the restart heals: every cell's ring events above its
committed watermark are re-posted to the new generation, so nothing still in
memory is lost to the death. What the ring has already evicted uncommitted
was declared degraded when it happened."
  (bt:with-lock-held (*journal-lock*)
    (when (eq service *journal-service*)
      (setf (journal-state service) :failed
            *journal-service* nil)))
  ;; Outside the journal lock: restarting takes it again, and re-posting
  ;; takes cell locks, which must never nest inside it the other way.
  (when (eq :failed (journal-state service))
    (ensure-journal)
    (dolist (cell (all-cells))
      (dolist (event (owning (cell) (remembered-since cell (cell-committed cell))))
        (journal-post (list :append cell event))))))

(defun ensure-journal ()
  "The current generation, starting one if none is available."
  (bt:with-lock-held (*journal-lock*)
    (or *journal-service*
        (let ((service (make-journal-service :id (incf *journal-generation*))))
          (ensure-directories-exist *journal-root*)
          (setf (journal-thread service)
                (bt:make-thread (lambda () (run-journal-owner service))
                                :name (format nil "vivarium-journal-~d"
                                              (journal-id service))))
          (setf *journal-service* service)))))

(defun journal-sync (&key (timeout 15))
  "Wait until everything posted so far is on disk. Returns T when confirmed."
  (let ((semaphore (bt:make-semaphore :count 0)))
    (and (journal-post (list :sync nil semaphore))
         (bt:wait-on-semaphore semaphore :timeout timeout)
         t)))

(defun read-journal (cell from through)
  "Journalled events with sequence in (FROM, THROUGH], oldest first.

Sorted rather than trusted: a restart re-posts uncommitted events, so a file
can hold a healed gap out of order."
  (let ((path (cell-journal-path cell)))
    (when (probe-file path)
      (sort (with-open-file (in path :external-format :utf-8)
              (loop for line = (read-line in nil nil)
                    while line
                    for event = (ignore-errors (event:from-json line))
                    when (and event
                              (< from (event:event-sequence event))
                              (<= (event:event-sequence event) through))
                      collect event))
            #'< :key #'event:event-sequence))))

(defun remember-event (cell event)
  "Ring the event in and post it for the journal. Under the cell lock."
  (let* ((sequence (event:event-sequence event))
         (slot (mod sequence +tail-limit+))
         (displaced (svref (cell-tail cell) slot)))
    ;; Overwriting an event the journal has not confirmed is data loss, and
    ;; data loss is a state to declare, never a silence. The write is not
    ;; blocked -- holding the organism hostage to a slow disk is worse -- but
    ;; the session is degraded from here until it says so.
    (when (and displaced
               (> (event:event-sequence displaced) (cell-committed cell))
               (null (cell-degraded cell)))
      (setf (cell-degraded cell) :unreported))
    (setf (svref (cell-tail cell) slot) event))
  (journal-post (list :append cell event)))

(defun remembered-since (cell sequence)
  "Ring events after SEQUENCE, oldest first. Under the cell lock."
  (loop for n from (max (1+ sequence)
                        (- (cell-sequence cell) (1- +tail-limit+))
                        1)
          to (cell-sequence cell)
        for event = (svref (cell-tail cell) (mod n +tail-limit+))
        when (and event (= (event:event-sequence event) n))
          collect event))

;;; Events
;;;
;;; One linearization point. The sequence number, the stored event and the set
;;; of subscribers that will receive it are decided together, so there is a
;;; single instant before which an event belongs to history and after which it
;;; belongs to the live stream.

(defun publish (cell name data)
  "Record an event and hand it to every subscriber, in sequence order.

Delivery happens inside the critical section that assigns the sequence, so the
order subscribers see IS the order of the journal. The alternative -- snapshot
the subscribers, release, then deliver -- lets two events assigned 104 and 105
be handed over as 105 then 104, and exports an ordering problem to every
frontend that then has to buffer, sort and detect gaps.

A subscriber is a MAILBOX, never a function. This ran arbitrary handlers here
under the rule that a handler must not block, which is a convention: the daemon
happened to obey it, and the next plugin, evaluator or debugging hook to call
SUBSCRIBE with something that waits would have frozen the session that
published to it. SEND-MESSAGE is the only thing that runs under this lock now,
and it is a known non-blocking primitive."
  (when (event:name-valid-p name)
    (let ((event nil) (declare-loss nil))
      (owning (cell)
        (setf event (event:make-event :name name :session (cell-id cell)
                                      :sequence (incf (cell-sequence cell))
                                      :time (get-universal-time)
                                      :data data))
        (remember-event cell event)
        (when (eq :unreported (cell-degraded cell))
          (setf (cell-degraded cell) :reported
                declare-loss t))
        (dolist (subscriber (cell-subscribers cell))
          (mailbox:send-message (cdr subscriber) event)))
      ;; Outside the lock: this is itself a publish.
      (when declare-loss
        (publish cell "session.error"
                 (event::object "detail" "journal lagging: unsynced events overwritten; history has a gap")))
      event)))

(defun subscribe (cell key mailbox)
  "Receive events published from now on, into MAILBOX."
  (owning (cell) (push (cons key mailbox) (cell-subscribers cell)))
  key)

(defun unsubscribe (cell key)
  (owning (cell)
    (setf (cell-subscribers cell)
          (remove key (cell-subscribers cell) :key #'car :test #'equal))))

(defun ring-covers-p (cell sequence)
  "Is everything after SEQUENCE still within the ring? Under the cell lock."
  (< (- (cell-sequence cell) sequence) +tail-limit+))

(defun subscribe-since (cell key sequence mailbox)
  "Catch up and start listening: every event after SEQUENCE exactly once, in
order, however fast the session is publishing meanwhile. Returns (VALUES KEY
BARRIER), where BARRIER is the newest sequence the catch-up covers.

When everything after SEQUENCE is still in the ring, replay and subscription
happen in one critical section and there is nothing to race. Otherwise the old
composition -- snapshot a boundary, read the disk, then read the ring -- lost
whatever crossed from ring to disk DURING the read: with a 4096 ring, a
subscriber replaying 1..1000 while the session published 5000 more found
events 1001..1904 in neither half. Its comment claimed the halves meet; under
concurrent publication that was false.

So the slow path stages:

    1  under the lock: BARRIER = current sequence, subscribe a STAGING mailbox
    2  journal sync -- FIFO means everything <= BARRIER is then on disk
    3  read the file through BARRIER into the destination
    4  under the lock: drain staging into the destination, then swap the
       registration to the destination

Everything <= BARRIER arrives from disk; everything after arrives through
staging or live; the swap happens with the publisher excluded, so no event
falls between the two registrations. If the sync cannot be confirmed -- the
journal owner is dead or restarting -- the ring supplements what the file is
missing, and whatever fell out of the ring uncommitted was declared degraded
when it happened."
  (let ((staging (mailbox:make-mailbox))
        (barrier nil)
        (fast nil))
    (owning (cell)
      (cond ((ring-covers-p cell sequence)
             (dolist (event (remembered-since cell sequence))
               (mailbox:send-message mailbox event))
             (push (cons key mailbox) (cell-subscribers cell))
             (setf fast t barrier (cell-sequence cell)))
            (t
             (setf barrier (cell-sequence cell))
             (push (cons key staging) (cell-subscribers cell)))))
    (unless fast
      (let* ((synced (journal-sync))
             (from-disk (read-journal cell sequence barrier))
             (reached sequence))
        (dolist (event from-disk)
          (mailbox:send-message mailbox event)
          (setf reached (event:event-sequence event)))
        (owning (cell)
          ;; The ring's contribution: empty when the sync was confirmed, the
          ;; best available truth when it was not.
          (unless synced
            (dolist (event (remembered-since cell reached))
              (when (<= (event:event-sequence event) barrier)
                (mailbox:send-message mailbox event))))
          (loop for event = (mailbox:receive-message-no-hang staging)
                while event
                do (mailbox:send-message mailbox event))
          (setf (cell-subscribers cell)
                (mapcar (lambda (subscriber)
                          (if (eq (cdr subscriber) staging) (cons key mailbox) subscriber))
                        (cell-subscribers cell))))))
    (values key barrier)))

(defun since (cell sequence &key (timeout 30))
  "Events after SEQUENCE, oldest first, as of the moment of asking.

Through the subscription barrier rather than a private composition: the old
one had the same replay gap SUBSCRIBE-SINCE had, and one correct mechanism
beats two half-correct ones. Subscribes a scratch mailbox, drains it until the
barrier event arrives, unsubscribes."
  (a:when-let ((cell (resolve cell)))
    (let ((mailbox (mailbox:make-mailbox))
          (key (gensym "SINCE")))
      (multiple-value-bind (key barrier) (subscribe-since cell key sequence mailbox)
        (unwind-protect
             (let ((events '())
                   (deadline (+ (get-internal-real-time)
                                (* timeout internal-time-units-per-second))))
               (loop while (< (if events (event:event-sequence (first events)) sequence)
                              barrier)
                     do (let ((left (/ (- deadline (get-internal-real-time))
                                       internal-time-units-per-second)))
                          (unless (plusp left) (return))
                          (a:if-let ((event (mailbox:receive-message mailbox :timeout left)))
                            (push event events)
                            (return))))
               (nreverse events))
          (unsubscribe cell key))))))

(defun snapshot (cell)
  "A coherent description of the cell, taken at one instant.

Reading the fields one at a time from another thread produced status output
whose state, sequence and queue length came from three different moments.

Plain values only. This used to return the live agent, so a caller that had
`taken a snapshot` went on to read that agent's slots from its own thread --
outside the very ownership boundary the snapshot exists to respect."
  (owning (cell)
    (list :id (cell-id cell) :label (cell-label cell) :state (cell-state cell)
          :sequence (cell-sequence cell) :turn (cell-turn cell)
          :queued (length (cell-queued cell))
          :model (cell-model cell)
          :cwd (cell-cwd cell))))

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
                   (multiple-value-bind (outcome detail reply)
                       (handler-case (let ((reply (harness:ask (cell-agent cell) text)))
                                       (values (turn-outcome (cell-agent cell)) nil reply))
                         ;; A failed turn ends the turn, not the session. The
                         ;; organism has to survive its own bad requests or it
                         ;; is not long-lived in any sense that matters.
                         (error (condition) (values :failed (princ-to-string condition) nil)))
                     ;; Back through the mailbox rather than publishing here:
                     ;; the terminal event belongs to the one thread that owns
                     ;; this cell's state. The reply and the model travel WITH
                     ;; the completion: a caller that waited for turn N and
                     ;; then read the live agent could read state already
                     ;; being rewritten by turn N+1, started from the queue.
                     (mailbox:send-message (cell-mailbox cell)
                                           (list :finished :turn turn
                                                           :outcome outcome
                                                           :detail detail
                                                           :reply reply
                                                           :model (agent:agent-model (cell-agent cell))))))
                 :name (format nil "vivarium-turn-~a" turn))))
    (owning (cell) (setf (cell-worker cell) worker)))
  turn)

(defun finish-turn (cell outcome detail reply)
  (let ((turn (cell-turn cell))
        (next nil))
    (owning (cell)
      (setf (cell-turn cell) nil
            (cell-worker cell) nil
            (cell-state cell) (if (eq :stopping (cell-state cell)) :stopping :idle)
            next (pop (cell-queued cell))))
    ;; Carrying the turn it ended and the reply it produced. The event is the
    ;; immutable record of the turn; reading the live agent after waiting for
    ;; this event reads whatever turn is running by then.
    (publish cell (ecase outcome
                    (:completed "turn.completed")
                    (:cancelled "turn.cancelled")
                    (:failed "turn.failed"))
             (event::object "turn" turn "detail" detail "text" reply))
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
        (progn
          (a:when-let ((model (getf options :model)))
            (owning (cell) (setf (cell-model cell) (string model))))
          (finish-turn cell (getf options :outcome) (getf options :detail)
                       (getf options :reply)))
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
          (cell-queued cell) '()
          (cell-stop-deadline cell) (+ (get-internal-real-time)
                                       (* +stopping-grace+
                                          internal-time-units-per-second))))
  (harness:cancel-agent (cell-agent cell))
  ;; Nothing running, so nothing to wait for.
  (unless (cell-turn cell)
    (owning (cell) (setf (cell-running cell) nil))))

(defun stopping-p (cell)
  (member (cell-state cell) '(:stopping :stuck)))

(defun handle (cell message)
  (destructuring-bind (verb &rest options) message
    ;; A stopping session is waiting for one thing. Control that arrives now is
    ;; about a session that is going away, and :RESUME in particular used to set
    ;; the state back to :WORKING or :IDLE -- so one late resume resurrected a
    ;; shutting-down session and put its coordinator back on an unbounded wait,
    ;; which is exactly the hang the stop deadline exists to prevent.
    (when (and (stopping-p cell)
               (member verb '(:steer :cancel :suspend :resume :shutdown)))
      (return-from handle nil))
    (ecase verb
      (:user-message (accept-prompt cell options))
      (:finished (complete-turn cell options))
      ;; The journal owner cannot publish -- publishing appends to the journal
      ;; -- so it reports here and the coordinator says it out loud.
      (:journal-failed
       (owning (cell) (setf (cell-degraded cell) :reported))
       (publish cell "session.error"
                (event::object "detail" (format nil "journal write failed: ~a; continuing non-durable"
                                                (getf options :detail)))))

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

(defun seconds-left (cell)
  (/ (- (cell-stop-deadline cell) (get-internal-real-time))
     internal-time-units-per-second))

(defun next-message (cell)
  "The next message, or NIL once a stopping session has run out of time.

A stopping session is waiting for exactly one thing -- its turn's completion --
so it is the only state in which waiting forever is a distinguishable failure
rather than an idle session behaving correctly.

The wait is what remains of one absolute deadline, recomputed each time. Passing
the grace period to each RECEIVE-MESSAGE instead gives every arriving message a
fresh 120 seconds, so a session with any traffic at all never times out."
  (cond ((not (eq :stopping (cell-state cell)))
         (mailbox:receive-message (cell-mailbox cell)))
        ((plusp (seconds-left cell))
         (mailbox:receive-message (cell-mailbox cell) :timeout (seconds-left cell)))
        (t nil)))

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
        (t
         ;; Completion is published, then PROVEN durable, and only then does
         ;; the session leave the registry -- so AWAIT-SHUTDOWN cannot report
         ;; success while the terminal record is unresolved. It used to
         ;; deregister first and warn to stderr if the flush never confirmed:
         ;; externally complete, durably unknown, inspectable by nobody.
         (publish cell "session.completed" nil)
         (if (flush-session cell)
             (deregister cell)
             ;; Inspectable, announced, and still trying: the flush loop below
             ;; keeps offering as long as the session exists, so a healed
             ;; journal completes the shutdown late rather than never.
             (loop until (flush-session cell)
                   do (sleep 1)
                   finally (deregister cell))))))

(defun flush-session (cell)
  "Ask the journal to write everything pending for CELL and close its stream.
Returns T on confirmation. Declares the failure -- once -- if it cannot."
  (let ((flushed (bt:make-semaphore :count 0)))
    (cond ((and (journal-post (list :close cell flushed))
                (bt:wait-on-semaphore flushed :timeout *flush-grace*))
           t)
          (t
           (let ((first-time nil))
             (owning (cell)
               (unless (cell-flush-declared cell)
                 (setf (cell-flush-declared cell) t
                       first-time t)))
             (when first-time
               (publish cell "session.error"
                        (event::object "detail" "journal close unconfirmed; session retained until it is"))))
           nil))))

(defun spawn (&key (label "") agent)
  "Start a session that outlives whoever started it."
  (let* ((id (bt:with-lock-held (*registry-lock*) (format nil "s~d" (incf *counter*))))
         (cell (make-cell :id id :label label :agent agent
                          :model (string (or (agent:agent-model agent) ""))
                          :cwd (env:env-cwd (harness:agent-environment agent)))))
    ;; The agent publishes through the cell, so every frontend sees the same
    ;; stream and none of them has to understand the agent loop's own events.
    (setf (harness:agent-listener agent)
          (lambda (loop-event)
            (multiple-value-bind (name data) (event:from-loop loop-event)
              (when name (publish cell name data)))))
    (ensure-journal)
    (setf (cell-journal-path cell) (journal-path-for id))
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

(defun drain-for-terminal (cell mailbox turn timeout)
  "Take events until THIS turn ends, or time runs out. Outside every lock.
Returns the terminal EVENT, which is the turn's immutable record."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    ;; It may already have ended between minting the id and subscribing.
    (dolist (event (since cell 0))
      (when (terminal-for-p event turn)
        (return-from drain-for-terminal event)))
    (loop
      (let ((left (/ (- deadline (get-internal-real-time))
                     internal-time-units-per-second)))
        (unless (plusp left) (return nil))
        (let ((event (mailbox:receive-message mailbox :timeout left)))
          (unless event (return nil))
          (when (terminal-for-p event turn)
            (return event)))))))

(defun await-turn (cell turn &key (timeout 300))
  "Wait for THIS turn to reach a terminal outcome. Returns its event name."
  (a:when-let ((cell (resolve cell)))
    (let ((mailbox (mailbox:make-mailbox))
          (key (gensym "WAIT")))
      (subscribe cell key mailbox)
      (unwind-protect
           (a:when-let ((event (drain-for-terminal cell mailbox turn timeout)))
             (event:event-name event))
        (unsubscribe cell key)))))

(defun ask-now (cell text &key (timeout 300))
  "Post a prompt and wait for THAT prompt's turn to finish. For callers that
are a one-shot script rather than an interface."
  (let ((cell (resolve cell)))
    (when cell
      (let ((turn (mint-turn cell))
            (mailbox (mailbox:make-mailbox))
            (key (gensym "WAIT")))
        (subscribe cell key mailbox)
        (unwind-protect
             (progn (tell cell :user-message :text text :turn turn)
                    ;; The event, not the live agent. Reading the agent after
                    ;; waiting for turn N reads whatever turn N+1 -- already
                    ;; started from the queue by FINISH-TURN -- is doing to it.
                    (a:when-let ((event (drain-for-terminal cell mailbox turn timeout)))
                      (gethash "text" (or (event:event-data event)
                                          (make-hash-table :test #'equal)))))
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
