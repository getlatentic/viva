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

(defparameter +tail-limit+ 4096
  "Events kept in memory per session. Older ones are read back from the journal.
Above the struct because a slot initform is compiled, and below it this was a
live undefined-variable warning that every later warning would have hidden in.")

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
  ;; The kernel state: the DECISION lives here, in the alphabet CELL-TRANSITION
  ;; is checked over. The slots around it are mechanics -- threads, queues of
  ;; actual text, gates -- that the coordinator maintains as the effects say.
  (machine '(:idle) :type list)
  ;; Prompts that arrived while a turn was running, oldest first, as
  ;; (turn . text). The machine tracks the COUNT; this holds the content.
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

(defun evolution-ledger-path ()
  (format nil "~aevolution.jsonl" *journal-root*))

(defun journal-evolution (name data)
  "Promotions and reversions are durable facts about the organism: the
lineage must be reconstructible from the improvement.* ledger after a
restart, because the registry is image state and the image is mortal.

ENSURE-JOURNAL first, because JOURNAL-POST refuses when no generation exists
and this caller has nowhere to put a refusal. The ledger used to depend on
some session having spawned earlier: evolution driven from the CLI or a
preflight wrote its whole genealogy into a dropped message and reported
nothing wrong. Safe from here -- this runs on the evolution owner's thread,
which holds no cell lock."
  (ensure-journal)
  (journal-post (list :evolution nil (cons name data))))

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
                        (:evolution
                         (handler-case
                             (let ((out (or (gethash :evolution streams)
                                            (setf (gethash :evolution streams)
                                                  (open (evolution-ledger-path)
                                                        :direction :output
                                                        :if-exists :append
                                                        :if-does-not-exist :create
                                                        :external-format :utf-8)))))
                               (jzon:with-writer* (:stream out)
                                 (jzon:write-value*
                                  (let ((table (make-hash-table :test #'equal)))
                                    (setf (gethash "event" table) (car extra)
                                          (gethash "data" table)
                                          (or (cdr extra) (make-hash-table :test #'equal)))
                                    table)))
                               (terpri out)
                               (force-output out))
                           (error () nil)))
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

(defvar *journal-machine* nil
  "The journal owner's kernel state, (:available ?gen) or (:restarting ?gen).
Owned by *JOURNAL-LOCK*. Decisions about generation death and restart go
through KERNEL:JOURNAL-TRANSITION -- the table that was, until now, the one
authority whose runtime did not consult it. Hardening item one, retired.")

(defun journal-dispatch (message)
  "Translate, transition, perform -- for the journal owner's own lifecycle.
Callers hold *JOURNAL-LOCK*; the effects that must not run under it are
returned to the caller instead of performed."
  (multiple-value-bind (next effects)
      (handler-bind ((kernel:unmatched-transition
                       (lambda (condition)
                         (declare (ignore condition))
                         (invoke-restart 'kernel:ignore-message))))
        (kernel:journal-transition *journal-machine* message))
    (setf *journal-machine* next)
    effects))

(defun journal-owner-exited (service)
  "The exit boundary: the GENERATION reports its death, and the checked table
decides. A predecessor's late death is the table's stale clause -- diagnosed,
restarting nothing -- which is the identity law this supervisor used to
enforce by hand and now cannot get wrong differently from the spec."
  (let ((effects (bt:with-lock-held (*journal-lock*)
                   (when (eq service *journal-service*)
                     (setf (journal-state service) :failed
                           *journal-service* nil))
                   (journal-dispatch (list :owner-exited (journal-id service))))))
    ;; Outside the journal lock: spawning takes it again, and re-posting
    ;; takes cell locks, which must never nest inside it the other way.
    (dolist (effect effects)
      (destructuring-bind (op &rest arguments) effect
        (ecase op
          (:spawn-owner (journal-spawn-generation (first arguments)))
          (:diagnostic
           (format *error-output* "~&vivarium journal: ~(~a~) generation ~a~%"
                   (first arguments) (second arguments))))))))

(defun journal-spawn-generation (generation)
  "The :SPAWN-OWNER effect, then :OWNER-STARTED back through the table, whose
:REPOST-UNCOMMITTED effect heals what the corpse left unconfirmed."
  (let ((service (make-journal-service :id generation)))
    (ensure-directories-exist *journal-root*)
    (setf (journal-thread service)
          (bt:make-thread (lambda () (run-journal-owner service))
                          :name (format nil "vivarium-journal-~d" generation)))
    (let ((effects (bt:with-lock-held (*journal-lock*)
                     (setf *journal-service* service)
                     (journal-dispatch (list :owner-started generation)))))
      (dolist (effect effects)
        (when (eq (first effect) :repost-uncommitted)
          (dolist (cell (all-cells))
            (dolist (event (owning (cell) (remembered-since cell (cell-committed cell))))
              (journal-post (list :append cell event)))))))))

(defun ensure-journal ()
  "The current generation, bootstrapping the machine and generation one if
none is available."
  (let ((bootstrap nil))
    (bt:with-lock-held (*journal-lock*)
      (unless *journal-machine*
        (setf *journal-machine* (list :available (incf *journal-generation*))
              bootstrap *journal-generation*)))
    (when bootstrap
      (let ((service (make-journal-service :id bootstrap)))
        (ensure-directories-exist *journal-root*)
        (setf (journal-thread service)
              (bt:make-thread (lambda () (run-journal-owner service))
                              :name (format nil "vivarium-journal-~d" bootstrap)))
        (bt:with-lock-held (*journal-lock*)
          (setf *journal-service* service)))))
  *journal-service*)

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
    (let ((event nil) (declare-loss nil) (dropped '()))
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
          ;; The kernel's law: every asynchronous boundary has a declared
          ;; capacity and overload action. A subscriber that stops draining is
          ;; DROPPED, not accumulated -- the daemon happens to disconnect slow
          ;; clients, but that is the daemon's manners, and the next subscriber
          ;; (an evaluator, a Phase 1.5 parent link) does not inherit manners.
          ;; Delivery stays non-blocking either way; what changes is that
          ;; overload has one announced outcome instead of a heap exhaustion
          ;; with a delay on it.
          (if (< (mailbox:mailbox-count (cdr subscriber)) kernel:+subscriber-capacity+)
              (mailbox:send-message (cdr subscriber) event)
              (push (car subscriber) dropped)))
        (when dropped
          (setf (cell-subscribers cell)
                (remove-if (lambda (subscriber) (member (car subscriber) dropped))
                           (cell-subscribers cell)))))
      ;; Outside the lock: these are themselves publishes.
      (when declare-loss
        (publish cell "session.error"
                 (event::object "detail" "journal lagging: unsynced events overwritten; history has a gap")))
      (dolist (key dropped)
        (publish cell "session.error"
                 (event::object "detail" (format nil "subscriber ~a dropped: ~d events behind"
                                                 key kernel:+subscriber-capacity+))))
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
          :cwd (cell-cwd cell)
          ;; What the last request actually cost, and what this model will
          ;; take. MEASURED, not estimated -- it is the number the provider
          ;; reported, and the same one compaction decides on. A client cannot
          ;; say how full a context is without being told, and guessing from
          ;; the transcript it happens to hold would be wrong by whatever it
          ;; has not been sent.
          :tokens (harness:agent-last-tokens (cell-agent cell))
          :limit (vivarium.compaction:settings-context-limit
                  (harness:agent-compaction (cell-agent cell)))
          :effort (string-downcase
                   (princ-to-string
                    (or (agent:agent-reasoning-effort (cell-agent cell)) ""))))))

(defun busy-p (cell)
  "Is there a turn whose outcome the coordinator has not yet consumed?

Not THREAD-ALIVE-P. A worker that has posted its completion and exited leaves
no turn running as far as the OS is concerned, while the turn is very much
unfinished as far as this session is concerned -- and a prompt arriving in that
window used to start a second turn whose identity the first turn's late
completion then destroyed."
  (a:when-let ((cell (resolve cell)))
    (and (current-turn cell) t)))

(defun current-turn (cell)
  "The identity of the running turn, from the machine, or NIL."
  (let ((designated (second (cell-machine cell))))
    (and (stringp designated) designated)))

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

(defun start-worker (cell turn options)
  "The mechanics of a turn: one thread around the work, reporting back through
the mailbox with the identity of the turn it finished.

OPTIONS rather than a bare string, because a turn is not always a prompt. A
RETENTION turn runs the policy instead -- on THIS thread, because reflection
uses the same agent and the same conversation the worker owns, and running it
from the client's thread would put two threads in one agent's turn."
  (let ((worker (bt:make-thread
                 (lambda ()
                   (multiple-value-bind (outcome detail reply)
                       (handler-case (let ((reply (progn
                                                    (if (getf options :retain)
                                                      (harness:reflect (cell-agent cell))
                                                      (harness:ask (cell-agent cell)
                                                                   (getf options :text))))))
                                       (values (turn-outcome (cell-agent cell)) nil reply))
                         ;; A failed turn ends the turn, not the session. The
                         ;; organism has to survive its own bad requests or it
                         ;; is not long-lived in any sense that matters.
                         (error (condition) (values :failed (princ-to-string condition) nil)))
                     ;; Back through the mailbox rather than publishing here:
                     ;; the terminal event belongs to the one thread that owns
                     ;; this cell's state. The reply and the model travel WITH
                     ;; the completion -- a caller that waited for turn N and
                     ;; then read the live agent could read state already
                     ;; being rewritten by turn N+1, started from the queue.
                     (mailbox:send-message (cell-mailbox cell)
                                           (list :finished :turn turn
                                                           :outcome outcome
                                                           :detail detail
                                                           :reply reply
                                                           :model (agent:agent-model (cell-agent cell))))))
                 :name (format nil "vivarium-turn-~a" turn))))
    (owning (cell) (setf (cell-worker cell) worker))))

;;; Translation: the mailbox protocol into the kernel's alphabet
;;;
;;; The kernel (src/daemon/kernel.lisp) owns the DECISION: cell states,
;;; messages and transitions as one checked table, mirrored action for action
;;; by spec/CellLifecycle.tla. The coordinator here owns the MECHANICS. Each
;;; mailbox message is translated to a kernel message, CELL-TRANSITION says
;;; what happens, and the effects are performed below. A state/message pair
;;; the table does not know SIGNALS, and the policy here turns that into a
;;; published diagnostic -- a lifecycle hole is a condition, never a silence.

(defun kernel-message (cell verb options)
  "The kernel message for a mailbox message, or NIL for one that is not a
lifecycle decision (or names a turn that is already gone, the old APPLIES-P)."
  (case verb
    (:user-message (list :submit (getf options :turn)))
    (:finished (list :finished (getf options :turn) (getf options :outcome)))
    (:cancel (a:when-let ((turn (or (getf options :turn) (current-turn cell))))
               (list :cancel turn)))
    (:steer (a:when-let ((turn (or (getf options :turn) (current-turn cell))))
              (list :steer turn)))
    ((:suspend :resume)
     ;; A named turn is honoured only while it is current; unnamed means now.
     (let ((named (getf options :turn)))
       (when (or (null named) (equal named (current-turn cell)))
         (list verb))))
    (:shutdown '(:shutdown))
    ((:stop-deadline :flush-confirmed :flush-failed) (list verb))
    (t nil)))

(defun refusal-detail (reason)
  (ecase reason
    (:prompt-refused-stopping "prompt refused: the session is stopping")
    (:prompt-refused-queue-full "prompt refused: queue full")
    (:shutdown-timed-out "shutdown timed out with a turn still running")))

(defun terminal-name (outcome)
  (ecase outcome
    (:completed "turn.completed")
    (:cancelled "turn.cancelled")
    (:failed "turn.failed")))

(defun run-effect (cell effect options)
  "Perform one kernel effect. OPTIONS is the original mailbox message's plist,
carrying what the alphabet abstracts away: prompt text, detail, reply, model."
  (destructuring-bind (op &rest arguments) effect
    (ecase op
      (:publish
       (destructuring-bind (name &rest detail) arguments
         (case name
           (:turn.started
            (publish cell "turn.started" (event::object "turn" (first detail))))
           (:session.error
            (publish cell "session.error"
                     (event::object "detail" (refusal-detail (first detail))
                                    "turn" (second detail))))
           (:session.completed (publish cell "session.completed" nil))
           (:task.suspended (publish cell "task.suspended" nil))
           (:task.resumed (publish cell "task.resumed" nil)))))
      (:publish-terminal
       (destructuring-bind (turn outcome) arguments
         (a:when-let ((model (getf options :model)))
           (owning (cell) (setf (cell-model cell) (string model))))
         (publish cell (terminal-name outcome)
                  (event::object "turn" turn
                                 "detail" (getf options :detail)
                                 "text" (getf options :reply)))))
      (:start-worker (start-worker cell (first arguments) options))
      (:queue-prompt
       ;; The whole message, not just its text. A queued turn that dropped
       ;; everything but the string would run a retention turn as an ordinary
       ;; prompt -- the right words with the wrong budget, and no way to tell
       ;; afterwards which it had been.
       (owning (cell)
         (setf (cell-queued cell)
               (append (cell-queued cell)
                       (list (cons (first arguments) options))))))
      (:start-next-queued
       ;; The machine designated :NEXT-QUEUED; the actual identity lives in
       ;; the mechanics. Pop it, fix the placeholder, announce, start.
       (let ((next (owning (cell) (pop (cell-queued cell)))))
         (when next
           (owning (cell)
             (setf (cell-machine cell)
                   (substitute (car next) :next-queued (cell-machine cell))))
           (publish cell "turn.started" (event::object "turn" (car next)))
           (start-worker cell (car next) (cdr next)))))
      (:request-cancel (harness:cancel-agent (cell-agent cell)))
      (:queue-steering
       (agent:queue-steering (cell-agent cell)
                             (msg:make-user-message
                              :content (list (msg:make-text (getf options :text))))))
      (:close-gate (harness:suspend-agent (cell-agent cell)))
      (:open-gate (harness:resume-agent (cell-agent cell)))
      (:cancel-agent (harness:cancel-agent (cell-agent cell)))
      (:discard-queue (owning (cell) (setf (cell-queued cell) '())))
      (:arm-stop-deadline
       (owning (cell)
         (setf (cell-stop-deadline cell)
               (+ (get-internal-real-time)
                  (* +stopping-grace+ internal-time-units-per-second)))))
      (:post-flush (attempt-flush cell))
      (:retry-flush (sleep 1) (attempt-flush cell))
      (:declare-flush-failure
       (let ((first-time nil))
         (owning (cell)
           (unless (cell-flush-declared cell)
             (setf (cell-flush-declared cell) t
                   first-time t)))
         (when first-time
           (publish cell "session.error"
                    (event::object "detail" "journal close unconfirmed; session retained until it is")))))
      (:deregister (deregister cell))
      (:diagnostic
       (destructuring-bind (kind &rest detail) arguments
         (publish cell "session.error"
                  (event::object "detail" (format nil "~(~a~): ~{~a~^ ~}" kind detail))))))))

(defun attempt-flush (cell)
  "One flush attempt, reported back into the mailbox as a kernel message: the
coordinator stays a loop of receive-transition-perform even for its own
epilogue, which is what lets the machine's :FLUSHING state absorb whatever
else arrives meanwhile."
  (let ((flushed (bt:make-semaphore :count 0)))
    (tell cell (if (and (journal-post (list :close cell flushed))
                        (bt:wait-on-semaphore flushed :timeout *flush-grace*))
                   :flush-confirmed
                   :flush-failed))))

(defun sync-mechanics (cell)
  "Mirror the machine into the display slots the rest of the system reads."
  (owning (cell)
    (setf (cell-state cell) (first (cell-machine cell))
          (cell-turn cell) (current-turn cell))))

(defun handle (cell message)
  (destructuring-bind (verb &rest options) message
    (case verb
      ;; Not a lifecycle decision: the journal owner cannot publish --
      ;; publishing appends to the journal -- so it reports here and the
      ;; coordinator says it out loud.
      (:journal-failed
       (owning (cell) (setf (cell-degraded cell) :reported))
       (publish cell "session.error"
                (event::object "detail" (format nil "journal write failed: ~a; continuing non-durable"
                                                (getf options :detail)))))
      ;; THE PROMPT IS A FACT ABOUT THE CONVERSATION, published beside the
      ;; lifecycle rather than inside it. `turn.started` carries a turn id and
      ;; nothing else, because the kernel that emits it is the proven machine
      ;; and knows only about turns -- so the text a person typed was never on
      ;; the wire at all. A client could echo its own input locally, and every
      ;; one did, which meant the conversation vanished the moment anybody
      ;; reattached: the transcript held the answers and none of the questions.
      ;;
      ;; Retention turns take the same path and are NOT a person speaking, so
      ;; they are not announced as one.
      (:user-message
       (unless (getf options :retain)
         (publish cell "user.message"
                  (event::object "text" (getf options :text)
                                 "turn" (getf options :turn))))
       (a:when-let ((translated (kernel-message cell verb options)))
         (handler-bind ((kernel:unmatched-transition
                          (lambda (condition)
                            (declare (ignore condition))
                            (invoke-restart 'kernel:ignore-message))))
           (multiple-value-bind (next effects)
               (kernel:cell-transition (cell-machine cell) translated)
             (owning (cell) (setf (cell-machine cell) next))
             (dolist (effect effects) (run-effect cell effect options))
             (sync-mechanics cell)))))
      (t
       (a:when-let ((translated (kernel-message cell verb options)))
         (handler-bind ((kernel:unmatched-transition
                          (lambda (condition)
                            (declare (ignore condition))
                            (invoke-restart 'kernel:ignore-message))))
           (multiple-value-bind (next effects)
               (kernel:cell-transition (cell-machine cell) translated)
             (owning (cell) (setf (cell-machine cell) next))
             (dolist (effect effects) (run-effect cell effect options))
             (sync-mechanics cell))))))))

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
  (cond ((not (eq :stopping (first (cell-machine cell))))
         (mailbox:receive-message (cell-mailbox cell)))
        ((plusp (seconds-left cell))
         (mailbox:receive-message (cell-mailbox cell) :timeout (seconds-left cell)))
        (t nil)))

(defun deregister (cell)
  (bt:with-lock-held (*registry-lock*) (remhash (cell-id cell) *cells*)))

(defun run-cell (cell)
  "Receive, translate, transition, perform. The lifecycle lives in the kernel
table; this loop is deliberately mechanical, including its own end: shutdown
drives the machine through :STOPPING and :FLUSHING to :COMPLETED, and the
flush's confirmation arrives as a message like everything else. A session the
deadline declared :STUCK keeps receiving -- the table absorbs late completions
as diagnostics -- and stays registered, visibly, until an operator resolves it."
  (loop until (eq :completed (first (cell-machine cell)))
        do (let ((message (next-message cell)))
             (handler-case (handle cell (or message '(:stop-deadline)))
               ;; Nothing a message can do may kill the session's thread. A cell
               ;; whose thread died looks exactly like one that is merely quiet.
               (error (condition)
                 (publish cell "session.error"
                          (event::object "detail" (princ-to-string condition))))))))

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
    ;; SESSION.STARTED BEFORE THE THREAD, so it is always sequence 1.
    ;;
    ;; It used to be the worker's first act, which was fine while the worker
    ;; was the only publisher. It no longer is: a resumed session has its
    ;; conversation published from the caller's thread the moment SPAWN
    ;; returns, and that beat the worker every time -- twenty runs out of
    ;; twenty had the transcript before the session had started.
    ;;
    ;; Nothing was lost or reordered within the log: the cell lock still
    ;; assigns sequence numbers atomically, so the stream stayed contiguous.
    ;; What broke is weaker and unstated, which is why it went unnoticed --
    ;; that a session's stream OPENS with the session opening. Publishing here,
    ;; before anything else can, makes it true by construction rather than by
    ;; whichever thread happened to win.
    (publish cell "session.started" (event::object "label" (cell-label cell)))
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

(defun submit-retention (cell)
  "Post a RETENTION turn and return its id.

The same path an ordinary prompt takes -- mint a turn, tell the cell -- so the
lifecycle machine sees one kind of turn and the spec that mirrors it does not
grow a case. What differs is only the mechanics: the worker runs the retention
policy rather than a prompt, on the thread that owns the agent."
  (let ((cell (resolve cell)))
    (when cell
      (let ((turn (mint-turn cell)))
        (tell cell :user-message :text harness:*reflection-prompt* :retain t :turn turn)
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
