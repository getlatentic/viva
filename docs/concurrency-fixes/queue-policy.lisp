;;;; queue-policy.lisp -- the two capacities actor.lisp leaves open, closed.
;;;;
;;;; Drop-in replacements for PUBLISH and ACCEPT-PROMPT in vivarium.actor,
;;;; plus two constants. Everything else in actor.lisp is untouched. The
;;;; kernel's law (kernel.lisp): every asynchronous boundary has a declared
;;;; capacity and a declared overload action, the way +JOURNAL-HIGH-WATER+
;;;; already declares one for the journal. These are the remaining two.

(in-package #:vivarium.actor)

(defparameter +queue-limit+ 64
  "Prompts a cell will hold while a turn runs. Overflow is refused, declared.

Unbounded, a client looping SUBMIT against a slow turn allocates forever
inside the coordinator -- the same shape as the GC crash the journal's high
water was added for, one boundary over.")

(defparameter +subscriber-capacity+ 8192
  "Events a subscriber mailbox may fall behind by before it is dropped.

The daemon happens to disconnect slow clients; that is the daemon's manners,
not the kernel's law, and the next subscriber -- an evaluator, a plugin, a
Phase 1.5 parent link -- does not inherit manners. Dropped is a defined
outcome announced on the stream; a heap exhaustion three hours later is not.")

(defun publish (cell name data)
  "Record an event and hand it to every subscriber, in sequence order.

Delivery happens inside the critical section that assigns the sequence, so the
order subscribers see IS the order of the journal. A subscriber is a MAILBOX,
never a function; SEND-MESSAGE is the only thing that runs under this lock,
and it is a known non-blocking primitive.

A subscriber over +SUBSCRIBER-CAPACITY+ is unsubscribed rather than sent to:
delivery stays non-blocking either way, and overload now has one outcome the
stream announces instead of an allocation with a delay on it. MAILBOX-COUNT
is a lock-free O(1) read on sb-concurrency's queue."
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
          (if (< (mailbox:mailbox-count (cdr subscriber)) +subscriber-capacity+)
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
                 (event::object "detail"
                                (format nil "subscriber ~a dropped: ~d events behind"
                                        key +subscriber-capacity+))))
      event)))

(defun accept-prompt (cell options)
  (let ((turn (or (getf options :turn) (mint-turn cell)))
        (text (getf options :text)))
    (cond ((eq :stopping (cell-state cell))
           (publish cell "session.error"
                    (event::object "detail" "prompt refused: the session is stopping")))
          ((busy-p cell)
           ;; Bounded, like every other queue the organism owns. The refusal
           ;; carries the turn id it refuses, so a waiting caller learns its
           ;; turn will never start rather than timing out against silence.
           (if (< (length (cell-queued cell)) +queue-limit+)
               (owning (cell)
                 (setf (cell-queued cell)
                       (append (cell-queued cell) (list (cons turn text)))))
               (publish cell "session.error"
                        (event::object "detail" "prompt refused: queue full"
                                       "turn" turn))))
          (t (start-turn cell turn text)))))
