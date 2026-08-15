;;;; Operations: work that outlives the call that started it.
;;;;
;;;; Written after a correction worth recording. This project's note said
;;;; deferred and suspended operations needed a provider with an async job API,
;;;; and that conflated two different things:
;;;;
;;;;   HARNESS-LEVEL defer, suspend, resume and await are orchestration around
;;;;   ordinary blocking requests. SBCL has threads, semaphores and condition
;;;;   variables; nothing about the provider enters into it.
;;;;
;;;;   DURABLE, PROVIDER-SIDE suspension is different. It means submitting work,
;;;;   losing the process entirely, and later asking `is job 48291 done?`. That
;;;;   needs a job identifier the provider issued and will still honour, and no
;;;;   amount of local machinery substitutes for one.
;;;;
;;;; This file is the first. The second is genuinely blocked, and saying so is
;;;; accurate; saying the first was blocked was not.
;;;;
;;;; Suspension here is COOPERATIVE. An operation stops at a point it chose --
;;;; a turn boundary, between tool calls -- rather than being frozen at an
;;;; arbitrary instruction. Freezing arbitrary execution would mean stopping a
;;;; thread mid-write to a file it holds open, and the resumed program would be
;;;; correct only by luck.

(in-package #:vivarium.operation)

(defstruct (operation (:conc-name operation-))
  (id "" :type string)
  (label "" :type string)
  ;; :PENDING -> :RUNNING -> (:DONE | :FAILED | :CANCELLED), with :SUSPENDED
  ;; reachable from :RUNNING and back again.
  (state :pending :type keyword)
  (result nil)
  (error nil)
  (thread nil)
  (lock (bt:make-lock "vivarium.operation"))
  ;; Signalled once, when the operation reaches a terminal state. A semaphore
  ;; rather than a condition variable because the wakeup must survive being sent
  ;; before anyone waits -- a waiter that arrives late on a condition variable
  ;; waits forever for a notification already delivered.
  (finished (bt:make-semaphore :count 0))
  (resume (bt:make-semaphore :count 0))
  (cancelled nil :type boolean))

(defvar *operations* (make-hash-table :test #'equal))
(defvar *registry-lock* (bt:make-lock "vivarium.operations"))
(defvar *counter* 0)

(defvar *operation* nil
  "The operation running in this thread, so a thunk can ask whether to pause.")

(defun next-id ()
  (bt:with-lock-held (*registry-lock*)
    (format nil "op-~d" (incf *counter*))))

(defun remember (operation)
  (bt:with-lock-held (*registry-lock*)
    (setf (gethash (operation-id operation) *operations*) operation)))

(defun find-operation (id)
  (bt:with-lock-held (*registry-lock*) (gethash id *operations*)))

(defun all-operations ()
  (bt:with-lock-held (*registry-lock*)
    (sort (loop for op being the hash-values of *operations* collect op)
          #'string< :key #'operation-id)))

(define-condition cancelled (error) ()
  (:report "The operation was cancelled."))

(defun settle (operation state &key result error)
  "Move to a terminal state and release everyone waiting.

The semaphore is signalled generously rather than once: several callers may be
awaiting the same operation, and one that arrives after the signal must still
find a count to take. A condition variable would lose the wakeup entirely."
  (bt:with-lock-held ((operation-lock operation))
    (setf (operation-state operation) state
          (operation-result operation) result
          (operation-error operation) error))
  (bt:signal-semaphore (operation-finished operation) :count 1000)
  operation)

(defun start (thunk &key (label "") (wrapper #'funcall))
  "Run THUNK on its own thread and return an OPERATION to ask about later.

WRAPPER is how the caller re-establishes whatever dynamic state THUNK needs. It
defaults to plain FUNCALL and is not optional in spirit: a rebinding does not
cross into a spawned thread, so a thunk that reads a special bound per run gets
the global value unless the caller says otherwise."
  (let ((operation (make-operation :id (next-id) :label label)))
    (remember operation)
    (setf (operation-thread operation)
          (bt:make-thread
           (lambda ()
             (let ((*operation* operation))
               (setf (operation-state operation) :running)
               (handler-case (settle operation :done :result (funcall wrapper thunk))
                 ;; Cancellation is not failure, and must be caught FIRST: a
                 ;; cancelled operation reported as failed tells every caller
                 ;; something went wrong when nothing did.
                 (cancelled () (settle operation :cancelled))
                 ;; Everything else caught rather than allowed to kill the
                 ;; thread: an operation that died silently is
                 ;; indistinguishable from one still running, and AWAIT would
                 ;; block until the timeout.
                 (error (condition) (settle operation :failed :error condition)))))
           :name (format nil "vivarium-~a" (operation-id operation))))
    operation))

(defun status (operation)
  (let ((operation (if (stringp operation) (find-operation operation) operation)))
    (and operation (bt:with-lock-held ((operation-lock operation))
                     (operation-state operation)))))

(defun finished-p (operation)
  (member (status operation) '(:done :failed :cancelled)))

(defun await (operation &key timeout)
  "Wait for OPERATION and return (values RESULT STATE).

Re-signals nothing: a failure is returned as a state, because a caller
collecting five operations wants the four that worked."
  (let ((operation (if (stringp operation) (find-operation operation) operation)))
    (unless operation (return-from await (values nil :unknown)))
    (unless (finished-p operation)
      (bt:wait-on-semaphore (operation-finished operation) :timeout timeout))
    (bt:with-lock-held ((operation-lock operation))
      (values (operation-result operation) (operation-state operation)))))

(defun await-all (operations &key timeout)
  "Wait for all of them. Returns a list of (values result state) pairs, in order."
  (mapcar (lambda (each)
            (multiple-value-bind (result state) (await each :timeout timeout)
              (list result state)))
          operations))

;;; Cooperative pause
;;;
;;; The thunk asks; nothing is done to it. CHECKPOINT is where an operation
;;; agrees to be paused, and a run that never calls it simply cannot be paused
;;; -- which is honest, and better than a suspension that half-worked.

(defun suspend (operation)
  (let ((operation (if (stringp operation) (find-operation operation) operation)))
    (when (and operation (eq :running (status operation)))
      (bt:with-lock-held ((operation-lock operation))
        (setf (operation-state operation) :suspended))
      t)))

(defun resume (operation)
  (let ((operation (if (stringp operation) (find-operation operation) operation)))
    (when (and operation (eq :suspended (status operation)))
      (bt:with-lock-held ((operation-lock operation))
        (setf (operation-state operation) :running))
      (bt:signal-semaphore (operation-resume operation))
      t)))

(defun cancel (operation)
  "Ask an operation to stop at its next checkpoint. Nothing is killed."
  (let ((operation (if (stringp operation) (find-operation operation) operation)))
    (when operation
      (bt:with-lock-held ((operation-lock operation))
        (setf (operation-cancelled operation) t))
      ;; A suspended operation has to be woken to notice.
      (bt:signal-semaphore (operation-resume operation))
      t)))

(defun checkpoint ()
  "Called by a running thunk at a point where pausing is safe.

Blocks while suspended and signals CANCELLED if asked to stop. A thunk running
outside an operation is unaffected, so the same code works either way."
  (a:when-let ((operation *operation*))
    (loop while (eq :suspended (status operation))
          do (bt:wait-on-semaphore (operation-resume operation) :timeout 1))
    ;; Signals only. START settles, so there is one place that decides an
    ;; operation's final state rather than two racing to write it.
    (when (operation-cancelled operation)
      (error 'cancelled))))

(defun forget-finished ()
  "Drop completed operations from the registry. Returns how many went."
  (bt:with-lock-held (*registry-lock*)
    (let ((gone 0))
      (maphash (lambda (id operation)
                 (when (member (operation-state operation) '(:done :failed :cancelled))
                   (remhash id *operations*)
                   (incf gone)))
               *operations*)
      gone)))
