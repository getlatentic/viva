;;;; evolution.lisp -- Phase 2's evolution lifecycle, born inside the proof.
;;;;
;;;; Mirrors spec/Evolution.tla clause for clause through the same DEFINE-OWNER
;;;; as the session kernel and the task tree. Pure CL, no dependencies; the
;;;; decision layer only. What is decided here is the LIFECYCLE of
;;;; self-modification -- who may change which authority when -- never what an
;;;; evolved function does: that is validated and capability-bounded at
;;;; runtime, outside any proof this file carries.
;;;;
;;;; The registry is one immutable value, rebuilt by every transition:
;;;;
;;;;   (:evolution MINTED VERSIONS LINEAGES PINS)
;;;;
;;;;   VERSIONS   alist id -> (:component NAME :status KEYWORD)
;;;;   LINEAGES   alist component -> list of promoted ids, newest first
;;;;   PINS       alist task -> alist component -> version id
;;;;
;;;; The laws, from the spec and from this project's own vocabulary, which has
;;;; insisted since before Phase 2 existed that DEACTIVATED and REVERTED are
;;;; different words: deactivation ends one task's local pin and is bounded by
;;;; that task's lifetime; reversion moves the promoted lineage back for
;;;; everyone. An unpromoted candidate reaches a task's resolution only
;;;; through that task's own pin.

(defpackage #:vivarium.evolution
  (:use #:cl #:vivarium.kernel)
  (:export #:evolution-transition #:empty-registry #:resolve
           #:registry-minted #:version-status #:current-promoted #:pins-of
           #:run-evolution-self-test))

(in-package #:vivarium.evolution)

;;; ---------------------------------------------------------------------------
;;; The registry: pure operations, prose names
;;; ---------------------------------------------------------------------------

(defun empty-registry () '(:evolution 0 () () ()))

(defun registry-minted (registry) (second registry))
(defun registry-versions (registry) (third registry))
(defun registry-lineages (registry) (fourth registry))
(defun registry-pins (registry) (fifth registry))

(defun rebuild (registry &key minted versions lineages pins)
  (list :evolution
        (or minted (registry-minted registry))
        (or versions (registry-versions registry))
        (or lineages (registry-lineages registry))
        (or pins (registry-pins registry))))

(defun version (registry id) (cdr (assoc id (registry-versions registry))))
(defun version-status (registry id) (getf (version registry id) :status))
(defun version-component (registry id) (getf (version registry id) :component))

(defun set-status (registry id status)
  (rebuild registry
           :versions (mapcar (lambda (entry)
                               (if (eql (car entry) id)
                                   (cons id (list :component (getf (cdr entry) :component)
                                                  :status status))
                                   entry))
                             (registry-versions registry))))

(defun lineage-of (registry component)
  (cdr (assoc component (registry-lineages registry) :test #'equal)))

(defun set-lineage (registry component lineage)
  (rebuild registry
           :lineages (cons (cons component lineage)
                           (remove component (registry-lineages registry)
                                   :key #'car :test #'equal))))

(defun current-promoted (registry component)
  (first (lineage-of registry component)))

(defun pins-of (registry task)
  (cdr (assoc task (registry-pins registry) :test #'equal)))

(defun set-pin (registry task component id)
  (let ((pins (cons (cons component id)
                    (remove component (pins-of registry task)
                            :key #'car :test #'equal))))
    (rebuild registry
             :pins (cons (cons task pins)
                         (remove task (registry-pins registry)
                                 :key #'car :test #'equal)))))

(defun drop-pins (registry task)
  (rebuild registry
           :pins (remove task (registry-pins registry) :key #'car :test #'equal)))

(defun resolve (registry task component)
  "THE isolation law as a definition: the task's own pin, else the promoted
default, else NIL. An unpromoted candidate reaches a task only through that
task's own pin -- the spec's CandidateOnlyByOwnPin, checked by TLC and
demonstrated violable by its witness config."
  (or (cdr (assoc component (pins-of registry task) :test #'equal))
      (current-promoted registry component)))

;;; ---------------------------------------------------------------------------
;;; The owner
;;; ---------------------------------------------------------------------------

(define-owner evolution
  (:states (:evolution ?minted ?versions ?lineages ?pins))

  ;; --- a candidate is created: identity minted here, never reused ---------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:create-candidate ?component))
    => (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins)))
         (rebuild registry
                  :minted (1+ ?minted)
                  :versions (cons (cons (1+ ?minted)
                                        (list :component ?component :status :candidate))
                                  ?versions)))
    (list :publish :improvement.created (1+ ?minted) ?component))

  ;; --- task-local activation: a pin, invisible outside the task -----------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:activate ?task ?id))
    :when (eq :candidate (version-status
                          `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?id))
    => (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins)))
         (set-pin registry ?task (version-component registry ?id) ?id))
    (list :publish :improvement.activated ?id ?task)
    (list :rebind-task-context ?task))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:activate ?task ?id))
    => :same (list :diagnostic :activate-refused ?id))

  ;; --- deactivation, bounded by task lifetime: the pins die with the task,
  ;; and only the pins -- the lineage does not move ---------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:task-ended ?task))
    => (drop-pins `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?task)
    (list :publish-deactivations ?task))

  ;; --- promotion: the single owner moves the default forward --------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:promote ?id))
    :when (eq :candidate (version-status
                          `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?id))
    => (let* ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins))
              (component (version-component registry ?id))
              (previous (current-promoted registry component))
              (registry (if previous (set-status registry previous :retired) registry))
              (registry (set-status registry ?id :promoted)))
         (set-lineage registry component (cons ?id (lineage-of registry component))))
    (list :publish :improvement.promoted ?id))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:promote ?id))
    => :same (list :diagnostic :promote-refused ?id))

  ;; --- reversion: the lineage steps BACK, for everyone. Not deactivation:
  ;; no task's pin is touched ------------------------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:revert ?component))
    :when (> (length (lineage-of
                      `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?component))
             1)
    => (let* ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins))
              (lineage (lineage-of registry ?component))
              (registry (set-status registry (first lineage) :retired))
              (registry (set-status registry (second lineage) :promoted)))
         (set-lineage registry ?component (rest lineage)))
    (list :publish :improvement.reverted ?component))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:revert ?component))
    => :same (list :diagnostic :revert-refused ?component))

  ;; --- a candidate that will not be kept -----------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:discard ?id))
    :when (eq :candidate (version-status
                          `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?id))
    => (set-status `(:evolution ,?minted ,?versions ,?lineages ,?pins) ?id :discarded))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins)
                (:discard ?id))
    => :same (list :diagnostic :discard-refused ?id)))

;;; ---------------------------------------------------------------------------
;;; Self-test: the invariants as traces
;;; ---------------------------------------------------------------------------

(defun run-evolution-self-test ()
  (let ((registry (empty-registry)))
    ;; A candidate exists; nobody resolves to it.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:create-candidate "search")))))
    (assert (eq :candidate (version-status registry 1)))
    (assert (null (resolve registry "task-a" "search")))
    ;; Task A pins it; task B still sees nothing. The isolation law as a trace.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:activate "task-a" 1)))))
    (assert (eql 1 (resolve registry "task-a" "search")))
    (assert (null (resolve registry "task-b" "search")))
    ;; Promotion changes the default for everyone; a second candidate pinned
    ;; by B is B's alone.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:promote 1))
                                   ((:create-candidate "search"))
                                   ((:activate "task-b" 2)))))
    (assert (eql 1 (current-promoted registry "search")))
    (assert (eql 2 (resolve registry "task-b" "search")))
    (assert (eql 1 (resolve registry "task-c" "search")))
    ;; DEACTIVATION: B ends; its pin dies; the lineage does not move.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:task-ended "task-b")))))
    (assert (null (pins-of registry "task-b")))
    (assert (eql 1 (current-promoted registry "search")))
    ;; Promote 2, then REVERSION: the lineage steps back to 1 for everyone.
    ;; Different word, different effect, and the machine keeps them different.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:promote 2))
                                   ((:revert "search")))))
    (assert (eql 1 (current-promoted registry "search")))
    (assert (eq :retired (version-status registry 2)))
    (assert (eq :promoted (version-status registry 1)))
    ;; Refusals refuse: promote a retired version, revert past the root,
    ;; activate something that is not a candidate.
    (multiple-value-bind (next effects) (evolution-transition registry '(:promote 2))
      (assert (equal next registry))
      (assert (eq :promote-refused (second (first effects)))))
    (multiple-value-bind (next effects) (evolution-transition registry '(:revert "search"))
      (assert (equal next registry))
      (assert (eq :revert-refused (second (first effects)))))
    (multiple-value-bind (next effects) (evolution-transition registry '(:activate "task-c" 2))
      (assert (equal next registry))
      (assert (eq :activate-refused (second (first effects))))))
  (format t "~&evolution self-test: all traces passed~%")
  t)
