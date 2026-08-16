;;;; The task supervisor: the tree's single writer, performing what the
;;;; checked table decides.
;;;;
;;;; Phase 1.5's law, inherited from the cell one level down: the DECISION is
;;;; TASKTREE-TRANSITION in src/daemon/tasktree.lisp, mirrored clause for
;;;; clause by spec/TaskTree.tla and verified there; this file is MECHANICS.
;;;; One supervisor for the image, like the journal owner. Workers are
;;;; sub-agents of the owning session's agent -- shared world, isolated
;;;; conversation, their own lane in the same transcript -- reporting through
;;;; the supervisor's mailbox with the identity of the task they finished.
;;;;
;;;; A task publishes through the SESSION that owns its root, so a client
;;;; watching a session sees its task tree without a second protocol.

(in-package #:vivarium.actor)

(defstruct (supervisor (:conc-name supervisor-))
  (tree (tasktree:empty-tree))
  (mailbox (mailbox:make-mailbox))
  (thread nil)
  (lock (bt:make-lock "vivarium.supervisor"))
  ;; id -> (:agent AGENT :cell CELL), the runtime riggings of each task. The
  ;; tree holds identity and lifecycle; this holds what threads need.
  (rigging (make-hash-table)))

(defvar *supervisor* nil)
(defvar *supervisor-lock* (bt:make-lock "vivarium.supervisor-start"))

(defun ensure-supervisor ()
  (bt:with-lock-held (*supervisor-lock*)
    (or *supervisor*
        (let ((supervisor (make-supervisor)))
          (setf (supervisor-thread supervisor)
                (bt:make-thread (lambda () (run-supervisor supervisor))
                                :name "vivarium-tasks"))
          (setf *supervisor* supervisor)))))

(defun task-tell (&rest message)
  (mailbox:send-message (supervisor-mailbox (ensure-supervisor)) message))

(defun task-tree-snapshot ()
  "The tree as plain values, one coherent instant."
  (let ((supervisor (ensure-supervisor)))
    (bt:with-lock-held ((supervisor-lock supervisor))
      (mapcar #'copy-list (tasktree:tree-tasks (supervisor-tree supervisor))))))

(defun rig (supervisor id)
  (gethash id (supervisor-rigging supervisor)))

(defun task-cell (supervisor id)
  (getf (rig supervisor id) :cell))

(defun task-publish (supervisor id name data)
  "Through the owning session's stream, so watching the session is watching
its tasks."
  (a:when-let ((cell (task-cell supervisor id)))
    (publish cell name data)))

;;; The verbs. SPAWN-TASK is the only entry that needs more than the alphabet:
;;; the goal text and, for a root, the owning session ride the mailbox message
;;; the way a prompt's text rides :USER-MESSAGE past the cell's kernel.

(defun spawn-task (cell text &key parent (scoped t) (timeout 15))
  "Ask for a task and return the identity the TREE minted for it, or NIL if
the spawn was refused (a full, draining or absent parent -- the refusal is
also published with the parent named).

The identity comes back from the transition that minted it, through a reply
mailbox riding the message. The first version predicted the id by reading
MINTED under the lock before sending -- and three rapid spawns each read the
same MINTED before the supervisor processed any of them, so a caller's handle
for its detached child pointed at somebody's scoped one. An identity is
minted by the owner or it is not an identity."
  (let ((reply (mailbox:make-mailbox)))
    (apply #'task-tell
           (append (if parent
                       (list (if scoped :spawn-scoped :spawn-detached) parent)
                       (list :spawn-root))
                   (list :text text :cell (resolve cell) :reply reply)))
    (let ((answer (mailbox:receive-message reply :timeout timeout)))
      (and (integerp answer) answer))))

(defun cancel-task (id) (task-tell :cancel-task id))

;;; The loop: receive, transition through the checked table, perform.

(defparameter +verb-arity+
  '((:spawn-root . 0) (:spawn-scoped . 1) (:spawn-detached . 1)
    (:task-finished . 2) (:child-resolved . 1) (:cancel-task . 1)
    (:propagate-cancel . 1))
  "Positional arguments per verb, declared rather than guessed. The first
version collected positionals `until a keyword` -- and an OUTCOME is a
keyword, so (:task-finished 1 :completed) dispatched as (:task-finished 1),
matched no clause, and every task completion vanished into the unmatched
diagnostic. Silently, because the diagnostic's own destructuring then missed.")

(defun supervisor-kernel-message (message)
  (destructuring-bind (verb &rest options) message
    (a:when-let ((arity (cdr (assoc verb +verb-arity+))))
      (cons verb (subseq options 0 arity)))))

(defun run-supervisor (supervisor)
  (loop
    (let ((message (mailbox:receive-message (supervisor-mailbox supervisor))))
      (when (eq (first message) :shutdown) (return))
      (handler-case
          (a:when-let ((translated (supervisor-kernel-message message)))
            (handler-bind ((kernel:unmatched-transition
                             (lambda (condition)
                               (declare (ignore condition))
                               (invoke-restart 'kernel:ignore-message))))
              (multiple-value-bind (next effects)
                  (tasktree:tasktree-transition
                   (bt:with-lock-held ((supervisor-lock supervisor))
                     (supervisor-tree supervisor))
                   translated)
                (bt:with-lock-held ((supervisor-lock supervisor))
                  (setf (supervisor-tree supervisor) next))
                ;; The plist tail after the declared positionals: GETF over a
                ;; list still carrying them is a malformed property list.
                (let ((options (nthcdr (cdr (assoc (first message) +verb-arity+))
                                       (rest message))))
                  (dolist (effect effects)
                    (run-task-effect supervisor effect options))))))
        ;; Nothing a message can do may kill the supervisor: a dead tree
        ;; owner would strand every running task's completion. Printed SMALL:
        ;; a condition's report can embed a whole cell, ring and all, and one
        ;; diagnostic once printed a megabyte.
        (error (condition)
          (let ((*print-level* 3) (*print-length* 8))
            (format *error-output* "~&vivarium tasks: ~a: ~a~%"
                    (type-of condition) condition)))))))

(defun task-state (supervisor id)
  (getf (tasktree:task (supervisor-tree supervisor) id) :state))

(defun terminal-event-name (state)
  (ecase state
    (:completed "task.completed")
    (:failed "task.failed")
    (:cancelled "task.cancelled")))

(defun run-task-effect (supervisor effect options)
  (destructuring-bind (op &rest arguments) effect
    (ecase op
      (:start-task-worker
       ;; Worker first, reply second: SPAWN-TASK returning must imply the
       ;; whole chain ran -- inheritance posted and applied, worker started.
       ;; With the reply first, the caller could read the child's box in the
       ;; gap, and the ordering attack was not caught because the race
       ;; happened to go the lucky way.
       (start-task-worker supervisor (first arguments) options)
       (a:when-let ((reply (getf options :reply)))
         (mailbox:send-message reply (first arguments))))
      (:publish
       ;; Destructured per name: the shapes differ, and reading (:task.error
       ;; :spawn-refused parent) as (name id ...) published the refusal to
       ;; task :SPAWN-REFUSED -- nowhere, silently.
       (destructuring-bind (name &rest detail) arguments
         (case name
           (:task.started
            (let ((id (first detail)))
              (task-publish supervisor id "task.started"
                            (event::object "task" id
                                           "parent" (getf (rest detail) :scoped-under)
                                           "detached-under" (getf (rest detail) :detached-under)))))
           (:task.error
            ;; The refusal names the parent it refused under; publish through
            ;; that parent's session so the asker can see it, and answer the
            ;; reply mailbox so a waiting spawner learns NIL now rather than
            ;; at its timeout.
            (a:when-let ((reply (getf options :reply)))
              (mailbox:send-message reply :refused))
            (destructuring-bind (reason parent) detail
              (task-publish supervisor parent "task.error"
                            (event::object "detail" (format nil "~(~a~)" reason)
                                           "parent" parent)))))))
      (:publish-task-terminal-or-draining
       (destructuring-bind (id outcome) arguments
         (declare (ignore outcome))
         (let ((state (task-state supervisor id)))
           (cond ((eq :draining state)
                  (task-publish supervisor id "task.draining" (event::object "task" id)))
                 (t
                  (task-publish supervisor id (terminal-event-name state)
                                (event::object "task" id))
                  (evolution-tell :task-ended id))))))
      (:publish-task-terminal
       (let* ((id (first arguments))
              (state (task-state supervisor id)))
         (task-publish supervisor id (terminal-event-name state)
                       (event::object "task" id))
         (evolution-tell :task-ended id)))
      (:notify-parent-if-resolved
       (let* ((id (first arguments))
              (task (tasktree:task (supervisor-tree supervisor) id)))
         (when (and (tasktree:terminal-p task)
                    (getf task :parent)
                    (getf task :scoped))
           (task-tell :child-resolved (getf task :parent)))))
      (:request-worker-cancel
       (a:when-let ((agent (getf (rig supervisor (first arguments)) :agent)))
         (harness:cancel-agent agent)))
      (:propagate-cancel (task-tell :propagate-cancel (first arguments)))
      (:diagnostic
       ;; KIND then whatever the clause attached -- an id, or for the
       ;; unmatched case the whole message. Publish through the named task's
       ;; session when there is one, and never fail to say SOMETHING: a
       ;; diagnostic that itself misfires is a silence wearing a report.
       (let* ((kind (first arguments))
              (subject (second arguments))
              (cell (and (integerp subject) (task-cell supervisor subject))))
         (let ((*print-level* 3) (*print-length* 8))
           (if cell
               (publish cell "task.error"
                        (event::object "detail" (format nil "~(~a~): task ~a" kind subject)
                                       "task" subject))
               (format *error-output* "~&vivarium tasks: ~(~a~) ~a~%" kind subject))))))))

(defvar *task-lanes* 0)

(defun task-terminal-p (supervisor id)
  (vivarium.tasktree:terminal-p
   (vivarium.tasktree:task (supervisor-tree supervisor) id)))

(defun start-task-worker (supervisor id options)
  "The mechanics of a task: a sub-agent of the owning session's agent -- for a
child, of its parent task's agent -- run on its own thread, reporting the
outcome with the identity of the task it finished. Law 9 applies: the
sub-agent's dynamic context is established by CALL-IN-TOOL-CONTEXT inside the
thread, never inherited ambiently."
  (let* ((parent-id (getf (tasktree:task (supervisor-tree supervisor) id) :parent))
         (cell (or (getf options :cell)
                   (task-cell supervisor parent-id)))
         (seed (if parent-id
                   (getf (rig supervisor parent-id) :agent)
                   (cell-agent cell)))
         ;; The seed's own request budget, not SUB-AGENT's default of 20: a
         ;; task worker on the default silently completed after twenty paced
         ;; requests, so every `enduring` test agent endured about 1.6
         ;; seconds -- roots completed mid-test, the tree correctly refused
         ;; spawns under the completed parent, and the refusals were chased
         ;; as three different phantom bugs before a probe printed the state.
         (agent (harness:sub-agent seed (format nil "task-~d-~d" id (incf *task-lanes*))
                                   :request-limit (harness:agent-request-limit seed)))
         (text (getf options :text)))
    (setf (gethash id (supervisor-rigging supervisor)) (list :agent agent :cell cell))
    ;; THE ORDERING OBLIGATION, as a mechanism: this thread -- the tree's one
    ;; writer -- posts the spawn to the evolution owner and WAITS for the
    ;; inheritance to be applied before the child's worker exists, so the
    ;; child's first resolution already sees its parent's pins, and the
    ;; registry can see through spawns when a discard asks who runs what.
    (when parent-id
      (evolution-ask :task-spawned id parent-id))
    (let ((box (task-context-box id cell)))
      (bt:make-thread
       (lambda ()
         (let ((*activation-box* box))
           (let ((outcome
                   (handler-case
                       (progn (agent:call-in-tool-context
                               agent (lambda () (harness:ask agent text :reset nil)))
                              (if (agent:cancelled-p agent) :cancelled :completed))
                     (error () :failed))))
             (task-tell :task-finished id outcome))))
       :name (format nil "vivarium-task-~d" id)))))
