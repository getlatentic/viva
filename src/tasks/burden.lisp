;;;; Observation burden: what B14's Gate 2 measures.
;;;;
;;;; Raw tool-call count is the wrong instrument and the pre-registration says
;;;; why. Five inspections inside one model request may cost less than three that
;;;; each need their own reasoning cycle, so the bottleneck under test is
;;;; INVESTIGATIVE INTERACTION rather than API calls:
;;;;
;;;;   observation burden = inspect_value calls
;;;;                      + investigation-only requests
;;;;
;;;; where an INVESTIGATION-ONLY REQUEST is a turn whose tool calls are all
;;;; read-only -- a turn spent finding out rather than changing.
;;;;
;;;; Produced by the harness rather than read off a transcript afterwards,
;;;; because a number a person extracts by eye is a number a person can extract
;;;; differently once they know which way it needs to come out.
;;;;
;;;; RECORDING WRAPS THE TOOLS RATHER THAN EDITING THEM. inspect_value is frozen
;;;; for the duration of B14 and the other four are arm A's fixed set; neither
;;;; should acquire a measurement side effect. A wrapper also means the recorded
;;;; name is the one the model actually called.

(in-package #:vivarium.burden)

(defparameter +read-only-tools+
  '("inspect_value" "read_definition" "find_definitions" "bash")
  "Tools that observe and change nothing. INSTALL and ROLLBACK are the complement:
a turn containing either is a turn that acted.")

(defvar *log* nil
  "Reversed list of tool-name strings and :TURN markers. NIL means not recording,
so an unmeasured run costs nothing rather than silently accumulating.")

(defun start-recording () (setf *log* '()))

(defun record-call (name) (when (listp *log*) (push name *log*)))

(defun record-turn-boundary ()
  "Called once per model request, after its tool calls have run."
  (when (listp *log*) (push :turn *log*)))

;;; Wrapping

(defclass recording-tool (tool:tool)
  ((inner :initarg :inner :reader inner-tool)))

(defmethod tool:execute ((tool recording-tool) arguments context)
  (record-call (tool:tool-name tool))
  (tool:execute (inner-tool tool) arguments context))

(defun recording (tool)
  (make-instance 'recording-tool
                 :inner tool
                 :name (tool:tool-name tool)
                 :description (tool:tool-description tool)
                 :parameters (tool:tool-parameters tool)))

(defun recording-tool-set (tools) (mapcar #'recording tools))

;;; Reading the log

(defun turns (log)
  "Tool names grouped per request, oldest first. A turn with no tool calls is
kept as an empty list: it is a request that spent its reasoning and asked for
nothing, which counts toward neither term but must not silently merge with its
neighbour."
  (let ((turns '()) (current '()))
    (dolist (entry (reverse log) (nreverse (if current (cons (nreverse current) turns) turns)))
      (if (eq entry :turn)
          (setf turns (cons (nreverse current) turns) current '())
          (push entry current)))))

(defun investigation-only-p (turn)
  (and turn (every (lambda (name) (member name +read-only-tools+ :test #'string=)) turn)))

(defun inspect-calls (log)
  (count "inspect_value" (remove :turn log) :test #'string=))

(defun investigation-requests (log) (count-if #'investigation-only-p (turns log)))

(defun observation-burden (log)
  (+ (inspect-calls log) (investigation-requests log)))

(defun burden-report (log)
  (list :burden (observation-burden log)
        :inspect-calls (inspect-calls log)
        :investigation-requests (investigation-requests log)
        :turns (length (turns log))
        :calls (reverse (remove :turn log))))

;;; Gate 2
;;;
;;; Both figures or neither. A median over successes alone is survivorship-biased
;;; and an unsolved attempt is NOT a cheap solve -- it contributes to the solve
;;; rate and to nothing else. Thresholds are the frozen ones from
;;; docs/b14-preregistration.md and are not arguments this function takes.

(defparameter +burden-threshold+ 6)
(defparameter +solve-rate-threshold+ 6/10)

(defun median (numbers)
  (let* ((sorted (sort (copy-list numbers) #'<))
         (n (length sorted)))
    (cond ((zerop n) nil)
          ((oddp n) (elt sorted (floor n 2)))
          (t (/ (+ (elt sorted (1- (/ n 2))) (elt sorted (/ n 2))) 2)))))

(defun gate-2 (results)
  "RESULTS is a list of (:solved boolean :burden integer). Reports the pair and
the verdict; it does not negotiate with either threshold."
  (let* ((attempts (length results))
         (solved (remove-if-not (lambda (r) (getf r :solved)) results))
         (rate (if (plusp attempts) (/ (length solved) attempts) 0))
         (burdens (mapcar (lambda (r) (getf r :burden)) solved))
         (typical (median burdens)))
    (list :attempts attempts
          :solved (length solved)
          :solve-rate (float rate)
          :median-burden typical
          :burdens (sort (copy-list burdens) #'<)
          :verdict
          (cond ((< rate +solve-rate-threshold+)
                 ;; High burden here would be an agent that is lost, not a
                 ;; reusable bottleneck. It fails Gate 1's premise, not Gate 2's.
                 :fail-not-reliably-solvable)
                ((null typical) :fail-nothing-solved)
                ((< typical +burden-threshold+) :fail-nothing-worth-abstracting)
                (t :pass)))))
