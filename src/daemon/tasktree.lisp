;;;; tasktree.lisp -- Phase 1.5's task tree, born inside the proof.
;;;;
;;;; Mirrors TaskTree.tla clause for clause, the way DEFINE-OWNER CELL mirrors
;;;; CellLifecycle.tla. Loads after kernel.lisp; pure CL, no dependencies. The
;;;; supervisor owner holds the whole tree as its state and remains the single
;;;; writer; workers and child coordinators report through messages, exactly
;;;; the cell's law one level up.
;;;;
;;;; The tree is a list of task plists, immutable across the boundary: every
;;;; transition builds a new list. Identities are minted monotonically and
;;;; never reused, which is what makes a late completion for a finished task
;;;; decidable forever. Task states:
;;;;
;;;;   :running      own work in flight
;;;;   :cancelling   cancel delivered, own work still reporting
;;;;   :draining     own outcome decided and PARKED, live scoped children
;;;;                 remain -- terminal would claim completion while owning
;;;;                 running work, the lie :flushing exists to prevent one
;;;;                 level down
;;;;   :completed :failed :cancelled   terminal, forever
;;;;
;;;; A child is :scoped (lifetime bounded by its parent's) or :detached
;;;; (genealogy recorded, lifecycle independent). Cancel propagates to live
;;;; scoped children only, one delivery per message, so the interleavings TLC
;;;; explored are the interleavings the runtime will produce.

(defpackage #:viva.tasktree
  (:use #:cl #:viva.kernel)
  (:export #:tasktree-transition #:empty-tree #:task #:live-p #:terminal-p
           #:live-scoped-children #:live-children #:+child-limit+
           #:tree-minted #:tree-tasks
           #:run-tasktree-self-test))

(in-package #:viva.tasktree)

(defparameter +child-limit+ 16
  "Live children a parent may own at once. Overflow is refused with its
reason; a spawn queue would hide fan-out pressure the tree should feel.")

;;; ---------------------------------------------------------------------------
;;; The tree: pure operations, prose names
;;; ---------------------------------------------------------------------------

(defun empty-tree () '(:tree 0 ()))

(defun tree-minted (tree) (second tree))
(defun tree-tasks (tree) (third tree))

(defun task (tree id) (find id (tree-tasks tree) :key (lambda (task) (getf task :id))))

(defun terminal-p (task) (member (getf task :state) '(:completed :failed :cancelled)))
(defun live-p (task) (member (getf task :state) '(:running :cancelling :draining)))

(defun live-children (tree parent)
  (remove-if-not (lambda (task) (and (eql (getf task :parent) parent) (live-p task)))
                 (tree-tasks tree)))

(defun live-scoped-children (tree parent)
  (remove-if-not (lambda (task) (getf task :scoped)) (live-children tree parent)))

(defun may-spawn-under-p (tree parent)
  (let ((task (task tree parent)))
    (and task
         (eq :running (getf task :state))
         (< (length (live-children tree parent)) +child-limit+))))

(defun adjoin-task (tree &key parent scoped)
  "A new tree with the next identity minted and running under PARENT."
  (let ((id (1+ (tree-minted tree))))
    (values (list :tree id
                  (cons (list :id id :state :running :parent parent
                              :scoped scoped :pending nil :cancelled nil)
                        (tree-tasks tree)))
            id)))

(defun rewrite-task (tree id &rest changes)
  "A new tree with ID's plist updated by CHANGES. Everything else is shared."
  (list :tree (tree-minted tree)
        (mapcar (lambda (task)
                  (if (eql (getf task :id) id)
                      (let ((new (copy-list task)))
                        (loop for (key value) on changes by #'cddr
                              do (setf (getf new key) value))
                        new)
                      task))
                (tree-tasks tree))))

(defun outcome-lands (tree id outcome)
  "Finish ID's own work: park in :DRAINING while live scoped children remain,
land terminal otherwise. The one rule the whole tree turns on."
  (if (live-scoped-children tree id)
      (rewrite-task tree id :state :draining :pending outcome)
      (rewrite-task tree id :state outcome)))

(defun next-cancel-target (tree parent)
  "One live scoped child that has not heard the cancel yet, or NIL. One
delivery per message: propagation is asynchronous on purpose, and the
supervisor sends itself (:propagate-cancel parent) again while targets remain."
  (find-if (lambda (task) (not (getf task :cancelled)))
           (live-scoped-children tree parent)))

;;; ---------------------------------------------------------------------------
;;; The supervisor owner
;;; ---------------------------------------------------------------------------

(define-owner tasktree
  (:states (:tree ?minted ?tasks))

  ;; --- spawning: identity minted here, never reused -----------------------
  (:transition ((:tree ?minted ?tasks) (:spawn-root))
    => (multiple-value-bind (tree id) (adjoin-task `(:tree ,?minted ,?tasks)
                                                   :parent nil :scoped nil)
         (declare (ignore id)) tree)
    (list :start-task-worker (1+ ?minted))
    (list :publish :task.started (1+ ?minted)))

  (:transition ((:tree ?minted ?tasks) (:spawn-scoped ?parent))
    :when (may-spawn-under-p `(:tree ,?minted ,?tasks) ?parent)
    => (multiple-value-bind (tree id) (adjoin-task `(:tree ,?minted ,?tasks)
                                                   :parent ?parent :scoped t)
         (declare (ignore id)) tree)
    (list :start-task-worker (1+ ?minted))
    (list :publish :task.started (1+ ?minted) :scoped-under ?parent))

  (:transition ((:tree ?minted ?tasks) (:spawn-detached ?parent))
    :when (may-spawn-under-p `(:tree ,?minted ,?tasks) ?parent)
    => (multiple-value-bind (tree id) (adjoin-task `(:tree ,?minted ,?tasks)
                                                   :parent ?parent :scoped nil)
         (declare (ignore id)) tree)
    (list :start-task-worker (1+ ?minted))
    (list :publish :task.started (1+ ?minted) :detached-under ?parent))

  ;; Refusal names its reason: a full parent, a draining or cancelling parent
  ;; that has already decided its lifetime, or no such parent at all.
  (:transition ((:tree ?minted ?tasks) (:spawn-scoped ?parent))
    => :same (list :publish :task.error :spawn-refused ?parent))
  (:transition ((:tree ?minted ?tasks) (:spawn-detached ?parent))
    => :same (list :publish :task.error :spawn-refused ?parent))

  ;; --- a task's own work reports -------------------------------------------
  ;; Identity first: live task, then the late case. Terminal is forever, so a
  ;; completion for a finished task is consumed as a diagnostic, changing
  ;; nothing -- TerminalIsForever in the spec, this clause in the runtime.
  (:transition ((:tree ?minted ?tasks) (:task-finished ?id ?outcome))
    :when (let ((task (task `(:tree ,?minted ,?tasks) ?id)))
            (and task (member (getf task :state) '(:running :cancelling))))
    => (outcome-lands `(:tree ,?minted ,?tasks) ?id ?outcome)
    (list :publish-task-terminal-or-draining ?id ?outcome)
    (list :notify-parent-if-resolved ?id))

  (:transition ((:tree ?minted ?tasks) (:task-finished ?id ?outcome))
    => :same (list :diagnostic :late-task-completion ?id))

  ;; --- the last scoped child resolved: the parked outcome lands ------------
  (:transition ((:tree ?minted ?tasks) (:child-resolved ?parent))
    :when (let ((tree `(:tree ,?minted ,?tasks)))
            (let ((task (task tree ?parent)))
              (and task (eq :draining (getf task :state))
                   (null (live-scoped-children tree ?parent)))))
    => (let ((tree `(:tree ,?minted ,?tasks)))
         (rewrite-task tree ?parent :state (getf (task tree ?parent) :pending)))
    (list :publish-task-terminal ?parent)
    (list :notify-parent-if-resolved ?parent))

  ;; Children remain, or the parent is not draining: bookkeeping only.
  (:transition ((:tree ?minted ?tasks) (:child-resolved ?parent))
    => :same)

  ;; --- cancellation: a request, propagated across scoped edges only --------
  (:transition ((:tree ?minted ?tasks) (:cancel-task ?id))
    :when (let ((task (task `(:tree ,?minted ,?tasks) ?id)))
            (and task (member (getf task :state) '(:running :draining))))
    => (let* ((tree `(:tree ,?minted ,?tasks))
              (task (task tree ?id)))
         (rewrite-task tree ?id :cancelled t
                       :state (if (eq :running (getf task :state))
                                  :cancelling
                                  (getf task :state))))
    (list :request-worker-cancel ?id)
    (list :propagate-cancel ?id))

  (:transition ((:tree ?minted ?tasks) (:cancel-task ?id))
    => :same (list :diagnostic :cancel-ignored ?id))

  ;; One delivery per message; the effect re-posts (:propagate-cancel ?parent)
  ;; while targets remain, so every interleaving TLC explored between a
  ;; child's terminal step and the next delivery exists here too. Detached
  ;; children are structurally unreachable: NEXT-CANCEL-TARGET walks live
  ;; SCOPED children only.
  (:transition ((:tree ?minted ?tasks) (:propagate-cancel ?parent))
    :when (next-cancel-target `(:tree ,?minted ,?tasks) ?parent)
    => (let* ((tree `(:tree ,?minted ,?tasks))
              (child (next-cancel-target tree ?parent)))
         (rewrite-task tree (getf child :id) :cancelled t
                       :state (if (eq :running (getf child :state))
                                  :cancelling
                                  (getf child :state))))
    (list :request-worker-cancel (getf (next-cancel-target
                                        `(:tree ,?minted ,?tasks) ?parent)
                                       :id))
    (list :propagate-cancel ?parent))

  (:transition ((:tree ?minted ?tasks) (:propagate-cancel ?parent))
    => :same))

;;; ---------------------------------------------------------------------------
;;; Self-test: the invariants as traces
;;; ---------------------------------------------------------------------------

(defun state-of (tree id) (getf (task tree id) :state))

(defun run-tasktree-self-test ()
  (let ((tree (empty-tree)))
    ;; Root, one scoped child, one detached child.
    (setf tree (replay-trace #'tasktree-transition tree
                             '(((:spawn-root))
                               ((:spawn-scoped 1))
                               ((:spawn-detached 1)))))
    (assert (eql 3 (tree-minted tree)))
    ;; The parent finishes first: outcome PARKS, scoped child holds it live.
    (setf tree (replay-trace #'tasktree-transition tree
                             '(((:task-finished 1 :completed)))))
    (assert (eq :draining (state-of tree 1)))
    ;; Scoped child resolves; the parked outcome lands. The detached child
    ;; survives its parent's completion: the first witness, as a trace.
    (setf tree (replay-trace #'tasktree-transition tree
                             '(((:task-finished 2 :completed))
                               ((:child-resolved 1)))))
    (assert (eq :completed (state-of tree 1)))
    (assert (eq :running (state-of tree 3)))
    ;; Late completion for a finished task changes nothing.
    (multiple-value-bind (next effects)
        (tasktree-transition tree '(:task-finished 1 :failed))
      (assert (equal next tree))
      (assert (eq :late-task-completion (second (first effects)))))
    ;; Cancellation crosses scoped edges only: the second witness, as a trace.
    (let ((tree (empty-tree)))
      (setf tree (replay-trace #'tasktree-transition tree
                               '(((:spawn-root))
                                 ((:spawn-scoped 1))
                                 ((:spawn-detached 1))
                                 ((:cancel-task 1))
                                 ((:propagate-cancel 1)))))
      (assert (eq :cancelling (state-of tree 1)))
      (assert (eq :cancelling (state-of tree 2)))
      (assert (getf (task tree 2) :cancelled))
      (assert (eq :running (state-of tree 3)))
      (assert (not (getf (task tree 3) :cancelled)))
      ;; The cancelled pair report; the parent drains, then lands.
      (setf tree (replay-trace #'tasktree-transition tree
                               '(((:task-finished 1 :cancelled)))))
      (assert (eq :draining (state-of tree 1)))
      (setf tree (replay-trace #'tasktree-transition tree
                               '(((:task-finished 2 :cancelled))
                                 ((:child-resolved 1)))))
      (assert (eq :cancelled (state-of tree 1)))
      (assert (eq :running (state-of tree 3))))
    ;; Fan-out past the limit is refused with its reason.
    (let ((tree (empty-tree))
          (limit +child-limit+))
      (setf tree (replay-trace #'tasktree-transition tree '(((:spawn-root)))))
      (dotimes (i limit)
        (setf tree (nth-value 0 (tasktree-transition tree '(:spawn-scoped 1)))))
      (multiple-value-bind (next effects)
          (tasktree-transition tree '(:spawn-scoped 1))
        (assert (equal next tree))
        (assert (eq :spawn-refused (third (first effects))))))
    ;; A draining parent may not take on new scoped work.
    (let ((tree (empty-tree)))
      (setf tree (replay-trace #'tasktree-transition tree
                               '(((:spawn-root))
                                 ((:spawn-scoped 1))
                                 ((:task-finished 1 :completed)))))
      (multiple-value-bind (next effects)
          (tasktree-transition tree '(:spawn-scoped 1))
        (assert (equal next tree))
        (assert (eq :spawn-refused (third (first effects)))))))
  (format t "~&tasktree self-test: all traces passed~%")
  t)
