;;;; kernel.lisp -- the concurrency kernel as one checkable object.
;;;;
;;;; This file contains the DECISION layer only:
;;;;
;;;;     transition : State x Message -> State x Effects
;;;;
;;;; No I/O, no locks, no threads, no mailboxes, no globals. Pure CL with no
;;;; dependencies, so the same file loads in the organism, in the test image,
;;;; and in the conformance harness. The MECHANICS stay where they are: the
;;;; coordinator in actor.lisp receives a message, calls the transition
;;;; function, applies the effects through mailboxes. Parallelism in effects,
;;;; serialization in authority.
;;;;
;;;; The state machine below is not an aspiration. It is extracted from the
;;;; behaviour actor.lisp already implements (HANDLE, FINISH-TURN, RUN-CELL,
;;;; BEGIN-STOPPING, FLUSH-SESSION), made explicit so that:
;;;;
;;;;   1. the TLA+ spec (CellLifecycle.tla) and this table say the same thing,
;;;;      action for action, and TRACE conformance can pin them together;
;;;;   2. an unmatched state/message pair SIGNALS instead of improvising,
;;;;      so a lifecycle hole is a condition, not a silence;
;;;;   3. TLC counterexample traces replay directly as Lisp tests through
;;;;      REPLAY-TRACE.
;;;;
;;;; Pattern language, chosen small on purpose:
;;;;   keyword        matches itself
;;;;   ?var           binds; a repeated ?var unifies (must be EQUAL)
;;;;   _              matches anything, binds nothing
;;;;   :when guard    arbitrary predicate over the bindings
;;;;
;;;; Clauses match top to bottom; first match wins. Order clauses from most
;;;; specific (repeated variable = identity match) to least (fresh variable =
;;;; the stale/mismatch case), the same way COMPLETE-TURN checks the current
;;;; turn before declaring a completion stale.

(defpackage #:viva.kernel
  (:use #:cl)
  ;; => is API: DEFINE-OWNER's clause assertion compares the arrow by EQ, so
  ;; an owner defined in another package -- which is exactly what Phase 1.5's
  ;; task tree is -- silently reads its own package's => and every clause
  ;; fails the malformed-clause assertion. Found by the first outside user.
  (:export #:transition #:unmatched-transition #:ignore-message
           #:unmatched-state #:unmatched-message
           #:define-owner #:owner-transitions #:owner-states #:=>
           #:replay-trace #:trace-step-failed
           #:cell-transition #:journal-transition
           #:+queue-limit+ #:+subscriber-capacity+
           #:run-self-test))

(in-package #:viva.kernel)

;;; ---------------------------------------------------------------------------
;;; Matcher
;;; ---------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)

(defun pattern-variable-p (x)
  (and (symbolp x)
       (not (keywordp x))
       (plusp (length (symbol-name x)))
       (char= #\? (char (symbol-name x) 0))))

(defun wildcard-p (x)
  (and (symbolp x) (string= (symbol-name x) "_")))

(defun match (pattern datum bindings)
  "Unify PATTERN against DATUM. Returns extended BINDINGS or :FAIL.
A repeated variable must match an EQUAL value: (:finished ?t _) against a
state carrying ?t is how `this completion is about the current turn` is said."
  (cond ((eq bindings :fail) :fail)
        ((wildcard-p pattern) bindings)
        ((pattern-variable-p pattern)
         (let ((existing (assoc pattern bindings)))
           (cond ((null existing) (acons pattern datum bindings))
                 ((equal (cdr existing) datum) bindings)
                 (t :fail))))
        ((and (consp pattern) (consp datum))
         (match (cdr pattern) (cdr datum)
                (match (car pattern) (car datum) bindings)))
        ((equal pattern datum) bindings)
        (t :fail)))

(defun binding-values (variables bindings)
  (mapcar (lambda (v) (cdr (assoc v bindings))) variables))

(defun pattern-variables (pattern)
  (let ((seen '()))
    (labels ((walk (x)
               (cond ((pattern-variable-p x) (pushnew x seen))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk pattern)
      (nreverse seen))))

) ; eval-when

;;; ---------------------------------------------------------------------------
;;; Conditions -- a lifecycle hole is a condition, never a silence
;;; ---------------------------------------------------------------------------

(define-condition unmatched-transition (error)
  ((owner   :initarg :owner   :reader unmatched-owner)
   (state   :initarg :state   :reader unmatched-state)
   (message :initarg :message :reader unmatched-message))
  (:report (lambda (c stream)
             (format stream "No transition in owner ~a for state ~s receiving ~s"
                     (unmatched-owner c) (unmatched-state c) (unmatched-message c)))))

(define-condition trace-step-failed (error)
  ((step     :initarg :step     :reader failed-step)
   (expected :initarg :expected :reader failed-expected)
   (actual   :initarg :actual   :reader failed-actual))
  (:report (lambda (c stream)
             (format stream "Trace step ~d: expected state ~s, got ~s"
                     (failed-step c) (failed-expected c) (failed-actual c)))))

;;; ---------------------------------------------------------------------------
;;; DEFINE-OWNER -- one declaration, three artifacts
;;; ---------------------------------------------------------------------------
;;;
;;; Generates:
;;;   NAME-TRANSITION        the production pure function
;;;   (OWNER-TRANSITIONS 'NAME)  the clause table, for conformance enumeration
;;;   (OWNER-STATES 'NAME)       the declared state alphabet
;;;
;;; The coordinator wraps the signal into its diagnostic policy:
;;;
;;;   (handler-bind ((unmatched-transition
;;;                    (lambda (c) (report-diagnostic c) (invoke-restart 'ignore-message))))
;;;     (multiple-value-bind (next effects) (cell-transition state message) ...))

(defvar *owners* (make-hash-table :test #'eq))

(defun owner-transitions (name) (getf (gethash name *owners*) :transitions))
(defun owner-states (name) (getf (gethash name *owners*) :states))

(defmacro define-owner (name &body clauses)
  (let ((states (cdr (assoc :states clauses)))
        (transitions (remove :transition clauses :key #'car :test-not #'eq))
        (state-var (gensym "STATE")) (message-var (gensym "MESSAGE")))
    (labels ((compile-clause (clause)
               ;; (:transition (STATE-PAT MESSAGE-PAT) [:when GUARD] => NEXT EFFECT...)
               (destructuring-bind (kw (state-pat message-pat) &rest rest) clause
                 (declare (ignore kw))
                 (let* ((guard (when (eq (first rest) :when) (second rest)))
                        (rest (if guard (cddr rest) rest))
                        (arrow (first rest))
                        (next (second rest))
                        (effects (cddr rest))
                        (vars (remove-duplicates
                               (append (pattern-variables state-pat)
                                       (pattern-variables message-pat)))))
                   (assert (eq arrow '=>) () "Malformed clause: ~s" clause)
                   `(let ((bindings (match ',message-pat ,message-var
                                           (match ',state-pat ,state-var '()))))
                      (unless (eq bindings :fail)
                        (destructuring-bind ,vars (binding-values ',vars bindings)
                          (declare (ignorable ,@vars))
                          (when ,(or guard t)
                            (return-from transition-body
                              (values ,(if (eq next :same) state-var next)
                                      (list ,@effects)))))))))))
      `(progn
         (setf (gethash ',name *owners*)
               (list :states ',states :transitions ',transitions))
         (defun ,(intern (format nil "~a-TRANSITION" name)) (,state-var ,message-var)
           ,(format nil "Pure transition for the ~(~a~) owner. Values: NEXT-STATE, EFFECTS." name)
           (block transition-body
             ,@(mapcar #'compile-clause transitions)
             (restart-case
                 (error 'unmatched-transition
                        :owner ',name :state ,state-var :message ,message-var)
               (ignore-message ()
                 :report "Keep the current state; the coordinator reports a diagnostic."
                 (values ,state-var
                         (list (list :diagnostic :unhandled ,message-var)))))))))))

;;; ---------------------------------------------------------------------------
;;; Queue policy -- the two capacities actor.lisp leaves open
;;; ---------------------------------------------------------------------------
;;;
;;; +JOURNAL-HIGH-WATER+ already exists and is right. These two do not:
;;;
;;; 1. CELL-QUEUED grows without bound: a client looping SUBMIT against a slow
;;;    turn allocates forever inside the coordinator. Overflow below refuses
;;;    with a declared reason, the same shape as the journal's refusal.
;;;
;;; 2. Subscriber mailboxes in PUBLISH are unbounded: a subscriber that stops
;;;    draining accumulates every event the session ever publishes. The daemon
;;;    happens to disconnect slow clients; that is the daemon's manners, not
;;;    the kernel's law, and the next subscriber (an evaluator, a Phase 1.5
;;;    parent link) does not inherit manners. The kernel's law: a subscriber
;;;    over capacity is DROPPED and the drop is published. Delivery to a
;;;    mailbox stays non-blocking either way; what changes is that overflow
;;;    now has a defined outcome instead of a delayed heap exhaustion.
;;;    Enforcement point: PUBLISH checks MAILBOX-COUNT against this before
;;;    SEND-MESSAGE, exactly as JOURNAL-POST already checks its high water.

(defparameter +queue-limit+ 64
  "Prompts a cell will hold while a turn runs. Overflow is refused, declared.")

(defparameter +subscriber-capacity+ 8192
  "Events a subscriber mailbox may fall behind by before it is dropped.")

;;; ---------------------------------------------------------------------------
;;; The cell owner
;;; ---------------------------------------------------------------------------
;;;
;;; States (from actor.lisp, with the two implicit end-of-life phases of
;;; RUN-CELL made explicit as :FLUSHING and :COMPLETED):
;;;
;;;   (:idle)                       no turn, accepting
;;;   (:working ?turn ?queued)      ?turn running, ?queued prompts waiting
;;;   (:suspended ?turn ?queued)    gate closed; ?turn may be :none
;;;   (:stopping ?turn)             draining one turn, queue discarded
;;;   (:flushing)                   session.completed published, awaiting
;;;                                 the journal's close confirmation
;;;   (:completed)                  durable, deregistered -- terminal
;;;   (:stuck)                      stop deadline expired with a turn still
;;;;                                out -- terminal, stays registered
;;;
;;; Messages: (:submit ?turn) (:finished ?turn ?outcome) (:cancel ?turn)
;;;           (:steer ?turn) (:suspend) (:resume) (:shutdown)
;;;           (:stop-deadline) (:flush-confirmed) (:flush-failed)
;;;
;;; Effects are DESCRIPTIONS the coordinator executes; the kernel never
;;; performs them. (:start-worker t) means BT:MAKE-THREAD around HARNESS:ASK;
;;; (:post-flush) means JOURNAL-POST of :close; and so on.

(define-owner cell
  (:states (:idle) (:working ?turn ?queued) (:suspended ?turn ?queued)
           (:stopping ?turn) (:flushing) (:completed) (:stuck))

  ;; --- accepting work ---------------------------------------------------
  (:transition ((:idle) (:submit ?turn))
    => `(:working ,?turn 0)
    (list :publish :turn.started ?turn)
    (list :start-worker ?turn))

  (:transition ((:working ?turn ?queued) (:submit ?next))
    :when (< ?queued +queue-limit+)
    => `(:working ,?turn ,(1+ ?queued))
    (list :queue-prompt ?next))

  (:transition ((:working ?turn ?queued) (:submit ?next))
    => :same
    (list :publish :session.error :prompt-refused-queue-full ?next))

  ;; Suspension holds arriving work the same way ACCEPT-PROMPT queues it.
  (:transition ((:suspended ?turn ?queued) (:submit ?next))
    :when (< ?queued +queue-limit+)
    => `(:suspended ,?turn ,(1+ ?queued))
    (list :queue-prompt ?next))
  (:transition ((:suspended ?turn ?queued) (:submit ?next))
    => :same
    (list :publish :session.error :prompt-refused-queue-full ?next))

  ;; --- the current turn ends: identity first, then the stale case --------
  (:transition ((:working ?turn 0) (:finished ?turn ?outcome))
    => '(:idle)
    (list :publish-terminal ?turn ?outcome))

  (:transition ((:working ?turn ?queued) (:finished ?turn ?outcome))
    :when (plusp ?queued)
    => `(:working :next-queued ,(1- ?queued))
    (list :publish-terminal ?turn ?outcome)
    (list :start-next-queued))

  ;; A completion for a turn that is no longer current changes nothing.
  ;; COMPLETE-TURN's law, now unforgeable: the repeated-?turn clause above
  ;; already claimed the identity match, so reaching here means ?stale differs.
  (:transition ((:working ?turn ?queued) (:finished ?stale ?outcome))
    => :same
    (list :diagnostic :stale-completion ?stale))

  ;; --- control: reaches only the current turn ----------------------------
  (:transition ((:working ?turn ?queued) (:cancel ?turn))
    => :same (list :request-cancel ?turn))
  (:transition ((:working ?turn ?queued) (:cancel ?stale))
    => :same (list :diagnostic :cancel-ignored ?stale))
  (:transition ((:working ?turn ?queued) (:steer ?turn))
    => :same (list :queue-steering ?turn))
  (:transition ((:working ?turn ?queued) (:steer ?stale))
    => :same (list :diagnostic :steer-ignored ?stale))

  ;; Control with nothing to control is absorbed silently, matching the
  ;; runtime's applies-p behaviour; a resume when nothing was suspended still
  ;; opens the gate and says so, which is what the runtime observably did.
  (:transition ((:idle) (:cancel _)) => :same)
  (:transition ((:idle) (:steer _)) => :same)
  (:transition ((:idle) (:resume))
    => :same (list :open-gate) (list :publish :task.resumed))
  (:transition ((:suspended ?turn ?queued) (:suspend)) => :same)
  (:transition ((:suspended ?turn ?queued) (:cancel ?turn))
    => :same (list :request-cancel ?turn))
  (:transition ((:suspended ?turn ?queued) (:cancel _)) => :same)
  (:transition ((:suspended ?turn ?queued) (:steer ?turn))
    => :same (list :queue-steering ?turn))
  (:transition ((:suspended ?turn ?queued) (:steer _)) => :same)
  (:transition ((:working ?turn ?queued) (:suspend))
    => `(:suspended ,?turn ,?queued)
    (list :close-gate) (list :publish :task.suspended))

  ;; --- suspend / resume ---------------------------------------------------
  (:transition ((:idle) (:suspend))
    => '(:suspended :none 0)
    (list :close-gate) (list :publish :task.suspended))
  (:transition ((:suspended :none 0) (:resume))
    => '(:idle)
    (list :open-gate) (list :publish :task.resumed))
  ;; Resume with no current turn but prompts waiting STARTS the next one.
  ;; The delivered table resumed to (:working :none q) -- a working state with
  ;; nobody working, whose queue never started -- and the spec disagreed with
  ;; it, resuming to idle with the queue equally stranded. Both wrong, found
  ;; on integration day by walking the runtime's message set against the
  ;; table: exactly the drift this discipline exists to catch.
  (:transition ((:suspended :none ?queued) (:resume))
    :when (plusp ?queued)
    => `(:working :next-queued ,(1- ?queued))
    (list :open-gate) (list :publish :task.resumed) (list :start-next-queued))
  (:transition ((:suspended ?turn ?queued) (:resume))
    => `(:working ,?turn ,?queued)
    (list :open-gate) (list :publish :task.resumed))
  ;; A suspended worker can still end (cancel raced the gate, or it finished
  ;; at a checkpoint before parking).
  (:transition ((:suspended ?turn 0) (:finished ?turn ?outcome))
    => '(:suspended :none 0)
    (list :publish-terminal ?turn ?outcome))
  ;; The queue does NOT advance while the gate is closed: starting a worker
  ;; under suspension parks it, and designating a next turn without starting
  ;; it strands the queue. Completions while suspended leave the queue for
  ;; RESUME to start.
  (:transition ((:suspended ?turn ?queued) (:finished ?turn ?outcome))
    :when (plusp ?queued)
    => `(:suspended :none ,?queued)
    (list :publish-terminal ?turn ?outcome))

  ;; --- shutdown: BEGIN-STOPPING's two shapes ------------------------------
  (:transition ((:working ?turn ?queued) (:shutdown))
    => `(:stopping ,?turn)
    (list :cancel-agent) (list :discard-queue ?queued) (list :arm-stop-deadline))

  (:transition ((:suspended :none ?queued) (:shutdown))
    => '(:flushing)
    (list :discard-queue ?queued)
    (list :publish :session.completed) (list :post-flush))

  (:transition ((:suspended ?turn ?queued) (:shutdown))
    => `(:stopping ,?turn)
    (list :cancel-agent) (list :open-gate)
    (list :discard-queue ?queued) (list :arm-stop-deadline))

  (:transition ((:idle) (:shutdown))
    => '(:flushing)
    (list :publish :session.completed) (list :post-flush))

  ;; --- stopping: waiting for exactly one thing ----------------------------
  (:transition ((:stopping ?turn) (:finished ?turn ?outcome))
    => '(:flushing)
    (list :publish-terminal ?turn ?outcome)
    (list :publish :session.completed) (list :post-flush))

  (:transition ((:stopping ?turn) (:finished ?stale ?outcome))
    => :same (list :diagnostic :stale-completion ?stale))

  (:transition ((:stopping ?turn) (:stop-deadline))
    => '(:stuck)
    (list :publish :session.error :shutdown-timed-out ?turn))

  ;; HANDLE's stopping guard: late control and repeated shutdown are about a
  ;; session that is going away. :RESUME here once resurrected a stopping
  ;; session; now the machine cannot express that transition at all.
  (:transition ((:stopping ?turn) (:submit ?next))
    => :same (list :publish :session.error :prompt-refused-stopping ?next))
  (:transition ((:stopping ?turn) (:cancel _)) => :same)
  (:transition ((:stopping ?turn) (:steer _)) => :same)
  (:transition ((:stopping ?turn) (:suspend)) => :same)
  (:transition ((:stopping ?turn) (:resume)) => :same)
  (:transition ((:stopping ?turn) (:shutdown)) => :same)

  ;; --- flushing: completion is proven durable, then the session leaves ----
  (:transition ((:flushing) (:flush-confirmed))
    => '(:completed)
    (list :deregister))

  (:transition ((:flushing) (:flush-failed))
    => :same
    (list :declare-flush-failure) (list :retry-flush))

  (:transition ((:flushing) (:submit ?next))
    => :same (list :publish :session.error :prompt-refused-stopping ?next))
  (:transition ((:flushing) (:finished ?stale _))
    => :same (list :diagnostic :stale-completion ?stale))
  (:transition ((:flushing) (:cancel _)) => :same)
  (:transition ((:flushing) (:steer _)) => :same)
  (:transition ((:flushing) (:suspend)) => :same)
  (:transition ((:flushing) (:resume)) => :same)
  (:transition ((:flushing) (:shutdown)) => :same)

  ;; --- terminal states absorb ---------------------------------------------
  (:transition ((:stuck) (:finished ?turn ?outcome))
    => :same (list :diagnostic :completion-after-stuck ?turn))
  (:transition ((:stuck) _) => :same)
  (:transition ((:completed) _)
    => :same (list :diagnostic :message-after-completed)))

;;; ---------------------------------------------------------------------------
;;; The journal owner -- generations, from actor.lisp's journal service
;;; ---------------------------------------------------------------------------
;;;
;;; (:available ?gen)  the current generation accepts appends
;;;   (:owner-exited ?gen)  the exit boundary reported THIS generation's death:
;;;                         restart as ?gen+1 and re-post uncommitted rings
;;;   (:owner-exited ?stale) a predecessor's death arriving late must not
;;;                         restart anything -- generation identity is the law
;;;                         that keeps cleanup from touching a successor

(define-owner journal
  (:states (:available ?gen) (:restarting ?gen))

  (:transition ((:available ?gen) (:owner-exited ?gen))
    => `(:restarting ,(1+ ?gen))
    (list :spawn-owner (1+ ?gen)))

  (:transition ((:available ?gen) (:owner-exited ?stale))
    => :same (list :diagnostic :stale-generation-exit ?stale))

  (:transition ((:restarting ?gen) (:owner-started ?gen))
    => `(:available ,?gen)
    (list :repost-uncommitted ?gen))

  (:transition ((:restarting ?gen) (:owner-exited ?stale))
    => :same (list :diagnostic :stale-generation-exit ?stale)))

;;; ---------------------------------------------------------------------------
;;; Trace replay -- TLC counterexamples become regression tests
;;; ---------------------------------------------------------------------------

(defun replay-trace (transition initial steps)
  "Drive TRANSITION from INITIAL through STEPS, asserting each expectation.
STEPS is a list of (MESSAGE &key EXPECT EFFECTS), where EXPECT is the state
required after the message and EFFECTS, when given, the exact effect list.
Returns the final state. A TLC error trace pastes in as one of these."
  (let ((state initial))
    (loop for step in steps
          for n from 1
          do (destructuring-bind (message &key expect effects) step
               (multiple-value-bind (next actual) (funcall transition state message)
                 (when (and expect (not (equal next expect)))
                   (error 'trace-step-failed :step n :expected expect :actual next))
                 (when (and effects (not (equal actual effects)))
                   (error 'trace-step-failed :step n :expected effects :actual actual))
                 (setf state next))))
    state))

;;; ---------------------------------------------------------------------------
;;; Self-test: the traces that were once production incidents
;;; ---------------------------------------------------------------------------

(defun run-self-test ()
  (flet ((cell (initial steps) (replay-trace #'cell-transition initial steps)))
    ;; Happy path with a queued prompt.
    (cell '(:idle)
          '(((:submit "t1") :expect (:working "t1" 0))
            ((:submit "t2") :expect (:working "t1" 1))
            ((:finished "t1" :completed) :expect (:working :next-queued 0))))
    ;; The stale completion that once destroyed the running turn's identity.
    (cell '(:working "t2" 0)
          '(((:finished "t1" :completed)
             :expect (:working "t2" 0)
             :effects ((:diagnostic :stale-completion "t1")))))
    ;; Shutdown proves durability before the session leaves.
    (cell '(:working "t3" 0)
          '(((:shutdown) :expect (:stopping "t3"))
            ((:resume) :expect (:stopping "t3"))   ; the resurrection bug, dead
            ((:finished "t3" :cancelled) :expect (:flushing))
            ((:flush-failed) :expect (:flushing))  ; retained until confirmed
            ((:flush-confirmed) :expect (:completed))))
    ;; The deadline makes STUCK a state, not a hang.
    (cell '(:stopping "t4")
          '(((:stop-deadline) :expect (:stuck))
            ((:finished "t4" :completed)
             :expect (:stuck)
             :effects ((:diagnostic :completion-after-stuck "t4")))))
    ;; The two holes integration found in the delivered table, kept failing
    ;; against any regression: resume starts the queue it was stranding, and
    ;; suspended completion leaves the queue for resume.
    (cell '(:idle)
          '(((:suspend) :expect (:suspended :none 0))
            ((:submit "q1") :expect (:suspended :none 1))
            ((:submit "q2") :expect (:suspended :none 2))
            ((:resume) :expect (:working :next-queued 1))))
    (cell '(:working "t6" 2)
          '(((:suspend) :expect (:suspended "t6" 2))
            ((:finished "t6" :completed) :expect (:suspended :none 2))
            ((:resume) :expect (:working :next-queued 1))))
    ;; Queue overload is refused, not accumulated.
    (let ((state '(:working "t5" 0)))
      (dotimes (i (1+ +queue-limit+))
        (multiple-value-bind (next effects)
            (cell-transition state (list :submit (format nil "q~d" i)))
          (when (= i +queue-limit+)
            (assert (equal next state))
            (assert (eq (second (first effects)) :session.error)))
          (setf state next))))
    ;; A hole signals; the coordinator's policy turns it into a diagnostic.
    (handler-bind ((unmatched-transition
                     (lambda (c) (declare (ignore c)) (invoke-restart 'ignore-message))))
      (multiple-value-bind (next effects)
          (cell-transition '(:idle) '(:no-such-message))
        (assert (equal next '(:idle)))
        (assert (eq (first (first effects)) :diagnostic))))
    ;; Journal generations: a predecessor's late death touches nothing.
    (replay-trace #'journal-transition '(:available 1)
                  '(((:owner-exited 1) :expect (:restarting 2))
                    ((:owner-exited 1)
                     :expect (:restarting 2)
                     :effects ((:diagnostic :stale-generation-exit 1)))
                    ((:owner-started 2) :expect (:available 2))))
    (format t "~&kernel self-test: all traces passed~%")
    t))
