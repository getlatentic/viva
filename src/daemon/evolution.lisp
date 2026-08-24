;;;; evolution.lisp -- Phase 2's evolution lifecycle, born inside the proof
;;;; and revised through it: independent verification proved three holes
;;;; against the tagged v1 before any wiring existed, which is the discipline
;;;; doing what it was built for. The three repairs:
;;;;
;;;;   FINDING 1  :discard is REFUSED while any task pins the version. A
;;;;              candidate somebody is running may not become "will not be
;;;;              kept" out from under them. NoResolutionToDiscarded is the
;;;;              invariant v1 was blind to; TLC violates it against v1's
;;;;              semantics in five states.
;;;;
;;;;   FINDING 2  the registry now remembers ENDED tasks, because the spec's
;;;;              live-task guard on Activate had no mirror: a stale :activate
;;;;              arriving after :task-ended recreated pins that no future
;;;;              :task-ended would ever drop. Ended is forever; identities
;;;;              are never reused; a posthumous activate is refused by name.
;;;;
;;;;   FINDING 3  (:task-spawned child parent) makes law 9's inheritance
;;;;              REGISTRY-VISIBLE: the child's snapshot is copied into the
;;;;              registry at spawn, so the discard guard can see what a
;;;;              child still runs after its parent dies. Wiring consequence:
;;;;              the task tree's spawn effect posts this message BEFORE the
;;;;              child's worker starts.
;;;;
;;;; The registry is one immutable value, rebuilt by every transition:
;;;;
;;;;   (:evolution MINTED VERSIONS LINEAGES PINS ENDED)
;;;;
;;;; THE DOOR is the one input that is not the state or the message. KC6's
;;;; arm B is this organism with self-modification refused, so the refusal
;;;; has to be somewhere -- and putting it at the tool boundary would be the
;;;; second door the no-back-door law forbids, reachable around by any
;;;; sub-agent, extension or console that talks to the owner directly. It
;;;; belongs with the other guards. It is not registry state: nothing in a
;;;; lifecycle ever moves it, and a run-level constant that no transition
;;;; rewrites would only be a seventh slot to carry correctly ten times.
;;;; It is *DOOR*, a dynamic constant, mirroring spec/Evolution.tla's CONSTANT
;;;; Door: fixed for a run's extent, bound by the owner thread from its own
;;;; slot -- law 9 doing visible work -- and by a LET in any test that wants
;;;; the other arm.

(defpackage #:viva.evolution
  (:use #:cl #:viva.kernel)
  (:export #:evolution-transition #:empty-registry #:resolve
           #:registry-minted #:version-status #:current-promoted #:pins-of
           #:*door* #:door-open-p #:run-evolution-self-test))

(in-package #:viva.evolution)

;;; ---------------------------------------------------------------------------
;;; The registry: pure operations, prose names
;;; ---------------------------------------------------------------------------

(defvar *door* :open
  "Whether this run may change what it runs. :OPEN or :CLOSED, fixed for a
run. Mirrors CONSTANT Door; ClosedDoorIsInert is the law it buys.")

(defun door-open-p () (eq *door* :open))

(defun empty-registry () '(:evolution 0 () () () ()))

(defun registry-minted (registry) (second registry))
(defun registry-versions (registry) (third registry))
(defun registry-lineages (registry) (fourth registry))
(defun registry-pins (registry) (fifth registry))
(defun registry-ended (registry) (sixth registry))

(defun rebuild (registry &key minted versions lineages pins ended)
  (list :evolution
        (or minted (registry-minted registry))
        (or versions (registry-versions registry))
        (or lineages (registry-lineages registry))
        (or pins (registry-pins registry))
        (or ended (registry-ended registry))))

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

(defun set-pins (registry task pins)
  (rebuild registry
           :pins (cons (cons task pins)
                       (remove task (registry-pins registry)
                               :key #'car :test #'equal))))

(defun set-pin (registry task component id)
  (set-pins registry task
            (cons (cons component id)
                  (remove component (pins-of registry task)
                          :key #'car :test #'equal))))

(defun drop-pins (registry task)
  (rebuild registry
           :pins (remove task (registry-pins registry) :key #'car :test #'equal)))

(defun ended-p (registry task)
  (member task (registry-ended registry) :test #'equal))

(defun mark-ended (registry task)
  (rebuild registry :ended (cons task (registry-ended registry))))

(defun pinned-anywhere-p (registry id)
  "Does ANY task pin ID? Ended tasks have no pins; a live child's inherited
pin counts, which is the whole reason inheritance is registry-visible."
  (loop for (task . pins) in (registry-pins registry)
        thereis (rassoc id pins)))

(defun resolve (registry task component)
  "THE isolation law as a definition: the task's own pin, else the promoted
default, else NIL."
  (or (cdr (assoc component (pins-of registry task) :test #'equal))
      (current-promoted registry component)))

;;; ---------------------------------------------------------------------------
;;; The owner
;;; ---------------------------------------------------------------------------

(define-owner evolution
  (:states (:evolution ?minted ?versions ?lineages ?pins ?ended))

  ;; --- a candidate is created: identity minted here, never reused ---------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:create-candidate ?component))
    => (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
         (rebuild registry
                  :minted (1+ ?minted)
                  :versions (cons (cons (1+ ?minted)
                                        (list :component ?component :status :candidate))
                                  ?versions)))
    (list :publish :improvement.created (1+ ?minted) ?component))

  ;; --- task-local activation: a pin, invisible outside the task, and only
  ;; within a lifetime -- a posthumous activate is the stale-message class
  ;; and is refused by name ---------------------------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:activate ?task ?id))
    :when (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
            (and (door-open-p)
                 (not (ended-p registry ?task))
                 (eq :candidate (version-status registry ?id))))
    => (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
         (set-pin registry ?task (version-component registry ?id) ?id))
    (list :publish :improvement.activated ?id ?task)
    (list :rebind-task-context ?task))

  ;; A door refusal is NOT an ordinary refusal and must never look like one:
  ;; the arm-B analysis has to tell "the agent tried and the arm refused it"
  ;; from "the candidate was already spent", and one shared diagnostic would
  ;; have merged the treatment with the noise.
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:activate ?task ?id))
    :when (not (door-open-p))
    => :same (list :publish :improvement.door-refused ?id ?task :activate))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:activate ?task ?id))
    => :same (list :diagnostic :activate-refused ?id ?task))

  ;; --- law 9's inheritance, registry-visible: the child is born holding its
  ;; parent's snapshot, and the registry knows it ------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:task-spawned ?child ?parent))
    :when (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
            (and (not (ended-p registry ?child))
                 (not (ended-p registry ?parent))
                 (null (pins-of registry ?child))))
    => (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
         (set-pins registry ?child (pins-of registry ?parent)))
    (list :publish :improvement.inherited ?child ?parent))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:task-spawned ?child ?parent))
    => :same (list :diagnostic :inherit-refused ?child ?parent))

  ;; --- deactivation, bounded by task lifetime: the pins die with the task,
  ;; only the pins, and ENDED is forever ---------------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:task-ended ?task))
    => (mark-ended
        (drop-pins `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended) ?task)
        ?task)
    (list :publish-deactivations ?task))

  ;; --- promotion: the single owner moves the default forward --------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:promote ?id))
    :when (and (door-open-p)
               (eq :candidate (version-status
                               `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)
                               ?id)))
    => (let* ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended))
              (component (version-component registry ?id))
              (previous (current-promoted registry component))
              (registry (if previous (set-status registry previous :retired) registry))
              (registry (set-status registry ?id :promoted)))
         (set-lineage registry component (cons ?id (lineage-of registry component))))
    (list :publish :improvement.promoted ?id))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:promote ?id))
    :when (not (door-open-p))
    => :same (list :publish :improvement.door-refused ?id nil :promote))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:promote ?id))
    => :same (list :diagnostic :promote-refused ?id))

  ;; --- reversion: the lineage steps BACK, for everyone. Not deactivation:
  ;; no task's pin is touched ------------------------------------------------
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:revert ?component))
    :when (> (length (lineage-of
                      `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)
                      ?component))
             1)
    => (let* ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended))
              (lineage (lineage-of registry ?component))
              (registry (set-status registry (first lineage) :retired))
              (registry (set-status registry (second lineage) :promoted)))
         (set-lineage registry ?component (rest lineage)))
    (list :publish :improvement.reverted ?component))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:revert ?component))
    => :same (list :diagnostic :revert-refused ?component))

  ;; --- a candidate that will not be kept: refused while ANYBODY runs it ----
  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:discard ?id))
    :when (let ((registry `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)))
            (and (eq :candidate (version-status registry ?id))
                 (not (pinned-anywhere-p registry ?id))))
    => (set-status `(:evolution ,?minted ,?versions ,?lineages ,?pins ,?ended)
                   ?id :discarded)
    (list :publish :improvement.discarded ?id))

  (:transition ((:evolution ?minted ?versions ?lineages ?pins ?ended)
                (:discard ?id))
    => :same (list :diagnostic :discard-refused ?id)))

;;; ---------------------------------------------------------------------------
;;; Self-test: the original traces plus the three findings as traces
;;; ---------------------------------------------------------------------------

(defun run-evolution-self-test ()
  (let ((registry (empty-registry)))
    ;; A candidate exists; nobody resolves to it.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:create-candidate "search")))))
    (assert (eq :candidate (version-status registry 1)))
    (assert (null (resolve registry "task-a" "search")))
    ;; Task A pins it; task B still sees nothing. Isolation as a trace.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:activate "task-a" 1)))))
    (assert (eql 1 (resolve registry "task-a" "search")))
    (assert (null (resolve registry "task-b" "search")))
    ;; FINDING 1 as a trace: discard refused while A runs it.
    (multiple-value-bind (next effects) (evolution-transition registry '(:discard 1))
      (assert (equal next registry))
      (assert (eq :discard-refused (second (first effects)))))
    ;; Promotion changes the default for everyone; a second candidate pinned
    ;; by B is B's alone.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:promote 1))
                                   ((:create-candidate "search"))
                                   ((:activate "task-b" 2)))))
    (assert (eql 1 (current-promoted registry "search")))
    (assert (eql 2 (resolve registry "task-b" "search")))
    (assert (eql 1 (resolve registry "task-c" "search")))
    ;; FINDING 3 as a trace: B spawns a scoped child; the child inherits B's
    ;; pin REGISTRY-VISIBLY. B ends; the child's pin holds the discard off.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:task-spawned "task-b-child" "task-b"))
                                   ((:task-ended "task-b")))))
    (assert (null (pins-of registry "task-b")))
    (assert (eql 2 (resolve registry "task-b-child" "search")))
    (multiple-value-bind (next effects) (evolution-transition registry '(:discard 2))
      (assert (equal next registry))
      (assert (eq :discard-refused (second (first effects)))))
    ;; FINDING 2 as a trace: a stale activate for the DEAD parent is refused;
    ;; no pin outlives a lifetime.
    (multiple-value-bind (next effects) (evolution-transition registry '(:activate "task-b" 2))
      (assert (equal next registry))
      (assert (eq :activate-refused (second (first effects)))))
    ;; The child ends; now the discard proceeds, and its judgment is published.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:task-ended "task-b-child")))))
    (multiple-value-bind (next effects) (evolution-transition registry '(:discard 2))
      (assert (eq :discarded (version-status next 2)))
      (assert (eq :improvement.discarded (second (first effects))))
      (setf registry next))
    ;; DEACTIVATION vs REVERSION, still different words: promote a third
    ;; candidate, revert, and the lineage steps back for everyone while no
    ;; pin moves.
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:create-candidate "search"))
                                   ((:promote 3))
                                   ((:revert "search")))))
    (assert (eql 1 (current-promoted registry "search")))
    (assert (eq :retired (version-status registry 3)))
    (assert (eq :promoted (version-status registry 1)))
    ;; Refusals still refuse.
    (multiple-value-bind (next effects) (evolution-transition registry '(:promote 3))
      (assert (equal next registry))
      (assert (eq :promote-refused (second (first effects)))))
    (multiple-value-bind (next effects) (evolution-transition registry '(:revert "search"))
      (assert (equal next registry))
      (assert (eq :revert-refused (second (first effects))))))
  ;; THE DOOR as a trace: the same organism, the other arm. Everything a
  ;; closed run can still do -- create, spawn, end, discard -- it does; the
  ;; two things that would let it change what it runs are refused by name,
  ;; and ClosedDoorIsInert's Lisp form holds: nothing resolves to anything.
  (let ((*door* :closed)
        (registry (empty-registry)))
    (setf registry (replay-trace #'evolution-transition registry
                                 '(((:create-candidate "search")))))
    (assert (eq :candidate (version-status registry 1)))
    (multiple-value-bind (next effects) (evolution-transition registry '(:activate "task-a" 1))
      (assert (equal next registry))
      (assert (eq :improvement.door-refused (second (first effects))))
      (assert (eq :activate (fifth (first effects)))))
    (multiple-value-bind (next effects) (evolution-transition registry '(:promote 1))
      (assert (equal next registry))
      (assert (eq :improvement.door-refused (second (first effects))))
      (assert (eq :promote (fifth (first effects)))))
    (assert (null (resolve registry "task-a" "search")))
    ;; Still lively: a candidate nobody can pin is discardable, which is why
    ;; EvolutionClosed carries the liveness property and not only the safety.
    (setf registry (replay-trace #'evolution-transition registry '(((:discard 1)))))
    (assert (eq :discarded (version-status registry 1))))
  (format t "~&evolution self-test: all traces passed, three findings and the door held~%")
  t)
