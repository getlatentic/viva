;;;; The evolution owner: the registry's single writer, performing what the
;;;; checked table decides.
;;;;
;;;; The DECISION is EVOLUTION-TRANSITION (src/daemon/evolution.lisp),
;;;; mirrored by spec/Evolution.tla and verified there with both witnesses.
;;;; This file is MECHANICS, and it carries the five sharp edges of this
;;;; wiring as mechanisms rather than conventions:
;;;;
;;;; ORDERING. Task lifecycle reaches this owner through the TASKTREE
;;;; SUPERVISOR ALONE -- one sender, so mailbox FIFO is the ordering proof,
;;;; the same argument JOURNAL-SYNC rests on. The supervisor posts
;;;; (:task-spawned child parent) before the child's worker starts and
;;;; (:task-ended id) when the tree lands a terminal; nothing else may.
;;;;
;;;; TWO REPRESENTATIONS, ONE LAW. The REGISTRY (the pure value the table
;;;; rewrites) is what lifecycle decisions consult. The SNAPSHOT (an
;;;; immutable alist in a per-task box) is what workers resolve against.
;;;; They may diverge within a turn; the box's only writer is the
;;;; :REBIND-TASK-CONTEXT effect, executed here.
;;;;
;;;; VISIBILITY IS A SEMANTICS, NOT A SURPRISE. SBCL cannot rebind another
;;;; thread's specials, so an activation cannot take effect instantly.
;;;; The worker's special holds a stable BOX whose contents this owner
;;;; replaces: an activation is visible from the task's NEXT component
;;;; resolution, never retroactively, and never by magic mid-call.
;;;;
;;;; COMPILE RUNS IN THE CALLER, never here: no external effect executes
;;;; under authority. A candidate arrives as a function object; a caller
;;;; whose source would not compile has a rejected candidate carrying its
;;;; condition, and this owner never hears of it.
;;;;
;;;; NO BACK DOOR. Components are not fbound symbols: resolution consults
;;;; the snapshot and the registry's function table, so SETF of
;;;; SYMBOL-FUNCTION changes nothing the organism resolves through --
;;;; promotion has one door, and the attack for this lives in the suite.

(in-package #:viva.actor)

(defstruct (evolver (:conc-name evolver-))
  (registry (viva.evolution:empty-registry))
  (mailbox (mailbox:make-mailbox))
  (thread nil)
  (lock (bt:make-lock "viva.evolver"))
  ;; version id -> function object. The registry holds identity and
  ;; lifecycle; this holds what a resolution can actually call.
  (functions (make-hash-table))
  ;; version id -> the form it was compiled from, where there was one.
  ;;
  ;; COMPILE keeps nothing of its argument, so a capability was a callable and
  ;; no more: unreadable, unwritable, and gone with the process. Keeping the
  ;; form is what lets a promoted capability be written down, read back by a
  ;; person, and compiled again by the next daemon.
  (sources (make-hash-table))
  ;; task -> (:box BOX :cell CELL). BOX is a one-cell cons whose CAR is the
  ;; task's immutable snapshot; this owner is its only writer.
  (rigging (make-hash-table :test #'equal))
  ;; The run's arm. Bound onto *DOOR* by this owner's thread and by nobody
  ;; else, because SBCL threads inherit no dynamic context -- the same law
  ;; that makes the box a box.
  (door :open))

(defvar *evolver* nil)
(defvar *evolver-lock* (bt:make-lock "viva.evolver-start"))

(defvar *default-door* :open
  "The arm a fresh evolver is born into. Configuration reads it once, before
any owner exists; KC6's arm B sets it to :CLOSED and never moves it.")

(defun ensure-evolver ()
  (bt:with-lock-held (*evolver-lock*)
    (or *evolver*
        (let ((evolver (make-evolver :door *default-door*)))
          (restore-capabilities evolver)
          (setf (evolver-thread evolver)
                (bt:make-thread (lambda () (run-evolver evolver))
                                :name "viva-evolution"))
          (setf *evolver* evolver)))))

(defun evolution-tell (&rest message)
  (mailbox:send-message (evolver-mailbox (ensure-evolver)) message))

(defun evolution-ask (&rest message)
  "Post and wait for the transition's answer. The reply rides the message."
  (let ((reply (mailbox:make-mailbox)))
    (apply #'evolution-tell (append message (list :reply reply)))
    (mailbox:receive-message reply :timeout 15)))

(defun evolution-registry ()
  (let ((evolver (ensure-evolver)))
    (bt:with-lock-held ((evolver-lock evolver)) (evolver-registry evolver))))

;;; The public verbs. CREATE-CANDIDATE compiles HERE -- in the caller's
;;; thread, a worker -- so a source that will not compile is the caller's
;;; rejected candidate, never the owner's death.

(defun capability-form (form)
  "The model's lambda, in the world a capability runs in.

ONE THING A LAMBDA CANNOT SAY: how to reach another capability. Resolution
goes through the door -- the task's pin, else the promoted default -- so a
capability that reached another by symbol would be calling a function instead
of resolving a component, and the isolation law would end at the first
composition. This binds the verb inside the lambda\'s own body, where the
model can write it without naming a package it should not have to know.

Applied at compile time and not before, so what the store holds is what the
model wrote. A form that is not a lambda passes through untouched: its
rejection belongs to the compiler, which words it better than a guess here."
  (if (and (consp form) (eq 'lambda (first form)))
      (destructuring-bind (head arguments &rest body) form
        (declare (ignore head))
        `(lambda ,arguments
           (flet ((viva.capabilities::call-capability (name input)
                    (call-component name input)))
             (declare (ignorable #'viva.capabilities::call-capability))
             ,@body)))
      form))

(defun compile-capability (component form)
  "FORM as a callable, or (values NIL CONDITION).

COMPILE does not signal on a malformed lambda: it returns a callable that
fails at runtime, with FAILURE-P true -- probed, not assumed. Accepting that
callable would ship the failure to every future caller of the component.

One judge for both doors into the image: a form arriving from a model now, and
the same form read back off disk at the next daemon start."
  (handler-case
      (multiple-value-bind (compiled warnings-p failure-p)
          (compile nil (capability-form form))
        (declare (ignore warnings-p))
        (if (or failure-p (null compiled))
            (values nil (make-condition
                         'simple-error
                         :format-control "candidate for ~a did not compile"
                         :format-arguments (list component)))
            (values compiled nil)))
    (error (c) (values nil c))))

(defun create-candidate (component function-or-source &key cell)
  "Returns (values VERSION-ID nil) or (values NIL CONDITION).

The SOURCE rides along with the function when there was one. A candidate is
never written down -- it is task-local by law and dies with its task -- but
promotion cannot write what creation threw away."
  (multiple-value-bind (function condition)
      (etypecase function-or-source
        (function (values function-or-source nil))
        (cons (compile-capability component function-or-source)))
    (if function
        (values (evolution-ask :create-candidate component
                               :function function
                               :source (and (consp function-or-source)
                                            function-or-source)
                               :cell cell)
                nil)
        (values nil condition))))

(defun activate-candidate (task id &key cell)
  (evolution-ask :activate task id :cell cell))

(defun promote-candidate (id &key cell) (evolution-ask :promote id :cell cell))

(defun register-file-tool (name &key cell)
  "Mint and promote a version for a FILE-BACKED tool. Returns the version id.

NOT CREATE-CANDIDATE, which compiles its argument. A registry tool is a script
on disk and there is nothing to compile -- and compiling is the in-image door
KC6 parked, which must stay unreachable from here. The owner stores a NIL
function against the version, which is correct: resolution for these goes
through the file registry, never through EVOLVER-FUNCTIONS.

Created and promoted together because a registry tool has no candidate phase.
It is written, checked against its script by #41, and then it is there --
there is no task-local trial for a file every later task can already see.
Promotion is what makes the lineage reconstructible after a restart, which is
the point: the registry is disk state and the ledger is the account of how it
got that way."
  (let ((id (evolution-ask :create-candidate name :function nil :cell cell)))
    (when (integerp id)
      (promote-candidate id :cell cell)
      id)))

(defun ledger-registrations ()
  "Send registry registrations to the evolution ledger.

Installed by the daemon rather than at load time: the ledger is the daemon's,
so registering without one registers without a ledger -- which is what a plain
`viva run` should do, and what keeps the registry's own tests from starting
an owner thread each."
  (setf registry:*on-register*
        (lambda (name) (register-file-tool name))))
(defun revert-component (component &key cell) (evolution-ask :revert component :cell cell))
(defun discard-candidate (id &key cell) (evolution-ask :discard id :cell cell))

;;; Resolution: the worker-facing surface.

(defvar *activation-box* nil
  "Bound per worker to the task's box; NIL outside any task, where only the
promoted defaults resolve.")

(defvar *resolutions-seen* nil
  "The worker's own table of (component . version) it has already reported
using. Thread-local by dynamic binding, never shared, never the box: the box
has one writer and a worker is not it.")

(defvar *resolution-task* nil
  "The task a worker's resolutions belong to.")

(defun snapshot-in-force ()
  (if *activation-box* (car *activation-box*) '()))

(defun note-resolution (component id)
  "Report a task's FIRST use of a version, once per (task, component, version).
Without this the ledger records what the organism decided and never what it
ran, and KC6's instrumentality pre-check -- does a created version actually
get used? -- has no relation to compute. Bounded by activations rather than
by calls, so the hot path costs a hash lookup and the journal costs nothing.
Sent to the owner rather than journalled here, because the owner is mid-step
when it replies to an activation: its own improvement.activated must land
first, and the mailbox is what orders the two."
  (when (and id *resolutions-seen*
             (not (gethash (cons component id) *resolutions-seen*)))
    (setf (gethash (cons component id) *resolutions-seen*) t)
    (evolution-tell :resolved *resolution-task* component id)))

(defun resolve-component (component)
  "The version id the current dynamic context resolves COMPONENT to, or NIL."
  (let ((id (or (cdr (assoc component (snapshot-in-force) :test #'equal))
                (viva.evolution:current-promoted (evolution-registry) component))))
    (note-resolution component id)
    id))

(defun component-function (id)
  (let ((evolver (ensure-evolver)))
    (bt:with-lock-held ((evolver-lock evolver))
      (gethash id (evolver-functions evolver)))))

(defun call-component (component &rest arguments)
  "The one door. Not SYMBOL-FUNCTION: components are not fbound, so a SETF of
somebody's symbol changes nothing that resolves through here."
  (let ((id (resolve-component component)))
    (unless id
      (error "No promoted version and no pin for component ~s." component))
    (apply (or (component-function id)
               (error "Version ~a of ~s has no function." id component))
           arguments)))

;;; The loop: receive, transition through the checked table, perform.

(defparameter +evolution-arity+
  '((:create-candidate . 1) (:activate . 2) (:task-spawned . 2)
    (:task-ended . 1) (:promote . 1) (:revert . 1) (:discard . 1)))

(defun run-evolver (evolver)
  ;; Law 9, explicitly: the arm is dynamic context, and a thread that did not
  ;; bind it would run the open-door table while believing it was arm B.
  ;; The arm is announced into the ledger before the first message, so a run's
  ;; own journal proves which arm it was rather than its directory name.
  (let ((viva.evolution:*door* (evolver-door evolver)))
    (journal-evolution "improvement.door"
                       (event::object "door" (string-downcase (evolver-door evolver))))
    (loop
      (let ((message (mailbox:receive-message (evolver-mailbox evolver))))
        (when (eq (first message) :shutdown) (return))
        (handler-case (evolver-step evolver message)
          (error (condition)
            (let ((*print-level* 3) (*print-length* 8))
              (format *error-output* "~&viva evolution: ~a: ~a~%"
                      (type-of condition) condition))))))))

(defun evolver-step (evolver message)
  ;; :RESOLVED is telemetry, and telemetry does not enter the table. An action
  ;; that leaves every variable unchanged is already what [][Next]_vars permits
  ;; by stuttering, so a clause for it would prove nothing and would put a
  ;; non-decision where the decisions live. It is handled here, ahead of the
  ;; transition, where it can touch no state: the test for that asserts the
  ;; registry is EQ across one.
  (when (eq (first message) :resolved)
    (destructuring-bind (task component id) (rest message)
      (evolution-publish evolver task "improvement.resolved"
                         (event::object "version" id
                                        "component" component
                                        "task" (princ-to-string task))))
    (return-from evolver-step nil))
  (destructuring-bind (verb &rest all) message
    (let* ((arity (or (cdr (assoc verb +evolution-arity+))
                      (return-from evolver-step nil)))
           (translated (cons verb (subseq all 0 arity)))
           (options (nthcdr arity all))
           ;; Pins BEFORE the transition, for the deactivation announcements:
           ;; the new registry has already forgotten them.
           (before (bt:with-lock-held ((evolver-lock evolver))
                     (evolver-registry evolver))))
      (handler-bind ((kernel:unmatched-transition
                       (lambda (condition)
                         (declare (ignore condition))
                         (invoke-restart 'kernel:ignore-message))))
        (multiple-value-bind (next effects)
            (viva.evolution:evolution-transition before translated)
          (bt:with-lock-held ((evolver-lock evolver))
            (setf (evolver-registry evolver) next))
          ;; THE REPLY GOES LAST, after every effect of this message has run.
          ;; It used to be sent inside whichever effect produced it, which put
          ;; :ACTIVATE's answer on the wire BEFORE :REBIND-TASK-CONTEXT wrote
          ;; the task's box: a worker could activate a candidate and then fail
          ;; to resolve it, because its own activation was not visible yet.
          ;; The inherit branch was correct only by accident -- it happened to
          ;; refresh before replying -- and the suite never lost the race that
          ;; KC6's preflight lost on its second run. An answer means the whole
          ;; transition is done, and now it cannot mean anything else.
          (let ((answer :none))
            (dolist (effect effects)
              (let ((value (run-evolution-effect evolver effect options
                                                 before translated)))
                (unless (eq value :none) (setf answer value))))
            (a:when-let ((reply (getf options :reply)))
              (unless (eq answer :none)
                (mailbox:send-message reply answer)))))))))

(defun evolution-cell (evolver task)
  (getf (gethash task (evolver-rigging evolver)) :cell))

(defun evolution-publish (evolver task name data &key cell)
  "The session sees the event -- the task's rigged one, or the CELL that rode
the message for taskless verbs like create and promote -- and the evolution
ledger always does: lineage must survive a restart, and the ledger is what
reconstructs it. The first wiring looked up a cell by a task that was NIL, so
improvement.created reached the ledger and no living stream."
  (a:when-let ((destination (or (and task (evolution-cell evolver task)) cell)))
    (publish destination name data))
  (journal-evolution name data))

(defun refresh-box (evolver task)
  "The :REBIND-TASK-CONTEXT effect: the box's one writer replaces the
snapshot. Visible from the task's next resolution -- SBCL cannot rebind
another thread's specials, and does not need to."
  (let* ((rig (or (gethash task (evolver-rigging evolver))
                  (setf (gethash task (evolver-rigging evolver))
                        (list :box (list '()) :cell nil))))
         (box (getf rig :box)))
    (setf (car box)
          (copy-alist (viva.evolution:pins-of (evolver-registry evolver) task)))))

(defun task-context-box (task cell)
  "The supervisor fetches the child's box when starting its worker. Created
here if the task has never touched evolution, recorded with its owning cell."
  (let ((evolver (ensure-evolver)))
    (bt:with-lock-held ((evolver-lock evolver))
      (let ((rig (or (gethash task (evolver-rigging evolver))
                     (setf (gethash task (evolver-rigging evolver))
                           (list :box (list '()) :cell nil)))))
        (when cell (setf (getf rig :cell) cell
                         (gethash task (evolver-rigging evolver)) rig))
        (getf rig :box)))))

(defun run-evolution-effect (evolver effect options before translated)
  (destructuring-bind (op &rest arguments) effect
    (ecase op
      (:publish
       (destructuring-bind (name &rest detail) arguments
         (case name
           (:improvement.created
            (let ((id (first detail)))
              (bt:with-lock-held ((evolver-lock evolver))
                (setf (gethash id (evolver-functions evolver))
                      (getf options :function))
                (a:when-let ((source (getf options :source)))
                  (setf (gethash id (evolver-sources evolver)) source)))
              (evolution-publish evolver nil "improvement.created"
                                 (event::object "version" id
                                                "component" (second detail))
                                 :cell (getf options :cell))
              id))
           (:improvement.activated
            (evolution-publish evolver (second detail) "improvement.activated"
                               (event::object "version" (first detail)
                                              "task" (princ-to-string (second detail)))
                               :cell (getf options :cell))
            (first detail))
           (:improvement.inherited
            (bt:with-lock-held ((evolver-lock evolver))
              (refresh-box evolver (first detail)))
            (evolution-publish evolver (first detail) "improvement.inherited"
                               (event::object "task" (princ-to-string (first detail))
                                              "parent" (princ-to-string (second detail))))
            (first detail))
           (:improvement.promoted
            (let* ((id (first detail))
                   (component (viva.evolution:version-component before id))
                   (kept (keep-promotion evolver id component)))
              (evolution-publish evolver nil "improvement.promoted"
                                 (event::object "version" id
                                                "component" component
                                                ;; A word, never a boolean:
                                                ;; EVENT::OBJECT drops a NIL
                                                ;; value, and an absent field
                                                ;; would read as an old ledger
                                                ;; line rather than as a
                                                ;; promotion that kept nothing.
                                                "kept" (kept-word kept))
                                 :cell (getf options :cell))
              (announce-reconciliation evolver options)
              id))
           (:improvement.reverted
            (let ((component (first detail)))
              ;; From BEFORE: the new registry has already dropped the version
              ;; this reverted, and that id is exactly what stops being restored.
              (a:when-let ((withdrawn (viva.evolution:current-promoted before component)))
                (retract-capability withdrawn))
              (evolution-publish evolver nil "improvement.reverted"
                                 (event::object "component" component)
                                 :cell (getf options :cell))
              (announce-reconciliation evolver options)
              component))
           (:improvement.discarded
            (evolution-publish evolver nil "improvement.discarded"
                               (event::object "version" (first detail))
                               :cell (getf options :cell))
            (first detail))
           ;; Arm B's refusal is an EVENT, not a diagnostic: the analysis has
           ;; to count what the frozen organism tried to do, and a line on
           ;; *ERROR-OUTPUT* is not data. The caller still gets its answer --
           ;; a refusal that left ASK waiting fifteen seconds would make the
           ;; arm slower in a way that had nothing to do with the door.
           (:improvement.door-refused
            (evolution-publish evolver (second detail) "improvement.door-refused"
                               (event::object "version" (first detail)
                                              "verb" (string-downcase (third detail)))
                               :cell (getf options :cell))
            (list :refused :door))
           (t :none))))
      ;; :NONE, explicitly. These two effects carry no answer, and returning
      ;; whatever their last form happened to produce would let a box refresh
      ;; overwrite the reply the caller is waiting on.
      (:rebind-task-context
       (bt:with-lock-held ((evolver-lock evolver))
         (refresh-box evolver (first arguments)))
       :none)
      (:publish-deactivations
       ;; From the registry BEFORE the transition: the new one has already
       ;; forgotten what this task held.
       (let ((task (first arguments)))
         (dolist (pin (viva.evolution:pins-of before task))
           (evolution-publish evolver task "improvement.deactivated"
                              (event::object "version" (cdr pin)
                                             "task" (princ-to-string task))))
         (bt:with-lock-held ((evolver-lock evolver))
           (a:when-let ((rig (gethash task (evolver-rigging evolver))))
             (setf (car (getf rig :box)) '())))
         :none))
      (:diagnostic
       ;; FIRST, not second. DESTRUCTURING-BIND already took the op off, so
       ;; (second arguments) was the version id: every refusal answered
       ;; (:refused 4) instead of naming its reason, and the log line printed
       ;; an id where the reason belongs. A caller cannot tell "already
       ;; promoted" from "no such candidate" by an id, and KC6's arm A needs
       ;; exactly that distinction.
       (let ((reason (first arguments)))
         (let ((*print-level* 3) (*print-length* 8))
           (format *error-output* "~&viva evolution: ~(~a~) ~s~%"
                   reason (rest translated)))
         (list :refused reason))))))

;;; Reconstruction: the ledger is the account, the store is a cache
;;;
;;; WHICH VERSIONS A COMPONENT WAS PROMOTED THROUGH, AND WHICH OF THOSE IT
;;; TOOK BACK, ARE DECISIONS -- and a decision lives where it was recorded,
;;; not where its side effect landed. A restart that read the store alone
;;; trusted a side effect twice over: a reversion whose rename did not take
;;; came back as the promoted default, and a file written into the directory
;;; by hand became a capability every future task resolved, with no line in
;;; the ledger saying where it came from. That is the second door the
;;; no-back-door law forbids, opened by the durability work rather than by an
;;; attack.
;;;
;;; So a restart brings back the ledger's lineage, narrowed to what the store
;;; can supply. The store may lose a file, gain a file, or hold a stale one,
;;; and none of those changes what the organism promotes.

(defstruct (account (:conc-name account-))
  ;; component -> the ids it was promoted through, newest first. Reversion
  ;; pops, so a version the organism took back is not in it.
  (lineages '())
  ;; The versions whose promotion had a source to keep, whether or not keeping
  ;; it worked. A promotion COMPILE kept nothing of -- a file-backed registry
  ;; tool, a version minted from a live function -- is not one, and reporting
  ;; its absence from the store would drown the case that matters: a promoted
  ;; default with no code behind it.
  (sourced '())
  ;; version id -> component, for the older ledger lines whose promotion
  ;; recorded only a number.
  (components '())
  (high-water 0))

(defun fold-ledger-line (account name data)
  (let ((id (gethash "version" data)))
    (when (and (realp id) (> id (account-high-water account)))
      (setf (account-high-water account) (floor id))))
  (cond ((equal name "improvement.created")
         (push (cons (gethash "version" data) (gethash "component" data))
               (account-components account)))
        ((equal name "improvement.promoted")
         (let* ((id (gethash "version" data))
                (component (or (gethash "component" data)
                               (cdr (assoc id (account-components account)
                                           :test #'equal)))))
           (when (member (gethash "kept" data) '("yes" "failed") :test #'equal)
             (push id (account-sourced account)))
           (push id (cdr (or (assoc component (account-lineages account) :test #'equal)
                             (first (push (cons component '())
                                          (account-lineages account))))))))
        ((equal name "improvement.reverted")
         (a:when-let ((entry (assoc (gethash "component" data)
                                    (account-lineages account) :test #'equal)))
           (pop (cdr entry))))))

(defun ledger-account (&optional (path (evolution-ledger-path)))
  "The improvement ledger, folded once.

Pins are not reconstructed: after a restart every task is dead, and pins are
bounded by task lifetime by proven law."
  (let ((account (make-account)))
    (when (probe-file path)
      (with-open-file (in path :external-format :utf-8)
        (loop for line = (read-line in nil nil)
              while line
              do (let* ((table (ignore-errors (jzon:parse line)))
                        (name (and (hash-table-p table) (gethash "event" table)))
                        (data (and name (gethash "data" table))))
                   (when (hash-table-p data) (fold-ledger-line account name data))))))
    account))

(defun reconstruct-lineage (&optional (path (evolution-ledger-path)))
  "The promoted lineage per component, folded from the improvement.* ledger."
  (account-lineages (ledger-account path)))

(defun ledger-high-water (&optional (path (evolution-ledger-path)))
  "The largest version id the ledger has ever recorded.

Identity comes from the ledger and code comes from the store, and the two
never disagree because they answer different questions. The store holds
promoted versions only; the ledger holds every one that was ever minted, which
is what an id has to clear to be new."
  (account-high-water (ledger-account path)))

(defun source-for (id stored)
  (third (find id stored :key #'first)))

(defun restorable-promotion (component registry stored)
  "The version a restart would resolve COMPONENT to: the newest one still in
this process's lineage that the store can also supply.

THE LINEAGE, not the highest id in the directory. A version the organism
reverted is out of the lineage and must never be what a restart resolves,
however its file came to still be there."
  (find-if (lambda (id) (source-for id stored))
           (viva.evolution:lineage-of registry component)))

(defun reconcile-capabilities (evolver &optional (stored (stored-capabilities)))
  "Every disagreement between what this process resolves and what a restart
would restore. Empty means the two accounts agree. Each finding names a
component and either what the two accounts say, or a version the store holds
that no lineage accounts for.

B12 IS WHY THIS EXISTS. Cordis reported a clean unload for every failure mode
viva actually has, because what it reported was what it had asked for. A
withdrawal that says it happened and did not is the one failure a
self-modifying system cannot notice from the inside, so this looks at the
disk instead of trusting the transition that fired.

A promoted version COMPILE kept nothing of has no source to write and is not
a disagreement -- there was never anything for the store to hold."
  (let ((registry (evolver-registry evolver)))
    (append (unaccounted-findings registry stored)
            (resolution-findings evolver registry stored))))

(defun unaccounted-findings (registry stored)
  "Stored versions no lineage names: a reverted version whose file survived,
or a file somebody wrote in. Neither is restored, and both are said out loud
-- promotion has one door, and a store that quietly held a second one would
be exactly the back door the table exists to close."
  (loop for entry in stored
        for id = (first entry)
        for component = (second entry)
        unless (member id (viva.evolution:lineage-of registry component))
          collect (list :component component :unaccounted id)))

(defun resolution-findings (evolver registry stored)
  (let ((components '())
        (findings '()))
    (maphash (lambda (id source)
               (declare (ignore source))
               (a:when-let ((component (viva.evolution:version-component registry id)))
                 (pushnew component components :test #'equal)))
             (evolver-sources evolver))
    (dolist (entry stored) (pushnew (second entry) components :test #'equal))
    (dolist (component components findings)
      (let ((resolves (viva.evolution:current-promoted registry component))
            (restores (restorable-promotion component registry stored)))
        (unless (or (eql resolves restores)
                    (and (null restores)
                         (null (gethash resolves (evolver-sources evolver)))))
          (push (list :component component :resolves resolves :restores restores)
                findings))))))

(defun finding-text (finding)
  (a:if-let ((unaccounted (getf finding :unaccounted)))
    (format nil "~a has version ~a in the store and in no lineage"
            (getf finding :component) unaccounted)
    (format nil "~a resolves ~a, a restart restores ~a"
            (getf finding :component)
            (or (getf finding :resolves) "nothing")
            (or (getf finding :restores) "nothing"))))

(defun announce-reconciliation (evolver options)
  "Look after the organism moves its own default, and say what was found.

Every lifecycle verb before this published what it DECIDED. This publishes
what is TRUE afterwards, which is the only one of the two an audit can use."
  (let ((findings (reconcile-capabilities evolver)))
    (evolution-publish
     evolver nil "improvement.reconciled"
     (event::object "agree" (if findings "no" "yes")
                    "disagreements" (length findings)
                    "detail" (when findings
                               (format nil "~{~a~^; ~}" (mapcar #'finding-text findings))))
     :cell (getf options :cell))
    findings))

(defun keep-promotion (evolver id component)
  "Write the promoted version's source beside its ledger entry. Returns the
path, :FAILED, or :NONE.

THREE OUTCOMES, NOT TWO. A version created from a live function object has no
source and gets no file -- COMPILE kept nothing, so there is nothing to write.
A version whose write fails has a source and no file, and that is a promoted
default with no code behind it. Both leave the store empty and one of them is
a fault; a single word for the pair would put the fault where nobody could
find it, which is the shape of the failure B12 named."
  (a:if-let ((source (bt:with-lock-held ((evolver-lock evolver))
                       (gethash id (evolver-sources evolver)))))
    (or (write-capability id component source) :failed)
    :none))

(defun kept-word (outcome)
  (case outcome (:none "no source") (:failed "failed") (t "yes")))

(defun restore-version (evolver registry id component source)
  "Compile SOURCE and place it at ID. Returns the new registry, or NIL.

A source that will not compile any more -- a macro that moved, an SBCL that
changed under it -- costs the organism that one capability and is said out
loud. The file stays where it is, because the next thing a person does is
read it."
  (multiple-value-bind (function condition) (compile-capability component source)
    (let ((next (and function (viva.evolution:rehydrate-promoted registry id component))))
      (cond (next (setf (gethash id (evolver-functions evolver)) function
                        (gethash id (evolver-sources evolver)) source)
                  next)
            (t (format *error-output*
                       "~&viva capability: version ~d (~a) not restored: ~a~%"
                       id component (or condition "the registry would not place it"))
               nil)))))

(defun restore-lineage (evolver registry component lineage stored)
  "Bring COMPONENT's lineage back, oldest promotion first, so the same
promotions land in the same order and leave the same head.

THE WHOLE LINEAGE, not only the head: reversion steps back to the version
before, and a version restored without its predecessors has nothing to step
back to."
  (let ((count 0) (missing '()))
    (dolist (id (reverse lineage))
      (a:if-let ((source (source-for id stored)))
        (a:when-let ((next (restore-version evolver registry id component source)))
          (setf registry next)
          (incf count))
        (push id missing)))
    (values registry count missing)))

(defun report-missing (missing sourced)
  "Name the promotions that had a source and whose source the store cannot
supply. A promoted default with no code behind it steps silently back to its
predecessor at a restart, and this is the line that says it did."
  (a:when-let ((lost (remove-if-not (lambda (each) (member (second each) sourced)) missing)))
    (format *error-output*
            "~&viva capability: the ledger promotes ~d version~:p the store cannot ~
supply: ~{~{~a ~a~}~^, ~}~%" (length lost) lost)))

(defun restore-capabilities (evolver)
  "Bring back the ledger's account of what this organism promoted, compiled
from the store. Returns how many came back.

BEFORE THE OWNER THREAD STARTS, and before this evolver is reachable through
*EVOLVER*: nothing can observe a half-restored registry, so nothing here takes
a lock."
  (let* ((account (ledger-account))
         (stored (stored-capabilities))
         (registry (evolver-registry evolver))
         (restored 0)
         (missing '()))
    (loop for (component . lineage) in (account-lineages account)
          when (stringp component)
            do (multiple-value-bind (next count lost)
                   (restore-lineage evolver registry component lineage stored)
                 (setf registry next)
                 (incf restored count)
                 (dolist (id lost) (push (list component id) missing))))
    (report-missing missing (account-sourced account))
    (report-unaccounted registry stored)
    (setf (evolver-registry evolver)
          (viva.evolution:reserve-identities registry (account-high-water account)))
    restored))

(defun report-unaccounted (registry stored)
  (a:when-let ((findings (unaccounted-findings registry stored)))
    (format *error-output* "~&viva capability: not restored -- ~{~a~^; ~}~%"
            (mapcar #'finding-text findings))))
