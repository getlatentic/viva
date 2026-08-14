;;;; Point an agent at a task and score what it did to the image.
;;;;
;;;; Shared by every experiment that needs a harness to attempt something --
;;;; S3's wire-format comparison, S5's fidelity check, S6's mutable-object arm --
;;;; so it lives here rather than being rewritten per experiment script.
;;;;
;;;; The ordering is the whole correctness argument and it is not negotiable:
;;;; set the task up, build the cases, THEN let the agent act. A case closes over
;;;; the world it will later compare against, and once the agent has run there is
;;;; nowhere left to capture that from.

(in-package #:vivarium.tasks)

(defclass bench-agent (agent:queued-agent)
  ((limit :initarg :limit :accessor bench-limit :initform 12
          :documentation "Requests before the run is cut off.

A cap is required rather than tidy. A model that cannot find the defect loops
between read and search until something stops it, and an uncapped run against a
paid endpoint is an unbounded bill.")
   (requests :initform 0 :accessor bench-requests)
   (on-event :initarg :on-event :accessor bench-on-event :initform nil)))

(defmethod agent:should-stop-after-turn ((agent bench-agent) message results context)
  (declare (ignore message results context))
  ;; Runs once per model request, after that request's tool calls. It is
  ;; therefore where a turn boundary belongs, and grouping calls per turn is what
  ;; separates an investigation-only REQUEST from an investigative CALL -- the
  ;; distinction B14's Gate 2 turns on.
  (burden:record-turn-boundary)
  (>= (incf (bench-requests agent)) (bench-limit agent)))

(defmethod agent:emit ((agent bench-agent) event)
  (a:when-let ((listener (bench-on-event agent)))
    (funcall listener event)))

(defstruct (attempt (:conc-name attempt-))
  (task nil)
  (label "" :type string)
  (scores '() :type list)
  (requests 0)
  ;; What Gate 2 measures. Produced here rather than read off a transcript
  ;; afterwards: a number a person extracts by eye is a number a person can
  ;; extract differently once they know which way it needs to come out.
  (burden '() :type list)
  (elapsed-ms 0)
  (error nil)
  ;; Shell commands that reached toward the harness itself. Not a score: a
  ;; contaminated attempt has to be discarded, not marked down.
  (contamination '() :type list))

(defparameter +harness-tells+
  '("tests/tasks" "tasks.lisp" "backlog.toml" "task-set.md" "/workspace/" "cd ..")
  "Shell fragments that mean a command reached for the benchmark itself.

Path-shaped on purpose. A first version matched the bare word \"vivarium\",
which every task's own package name contains -- VIVARIUM.TASK.T11 -- so an agent
doing exactly what it was asked tripped the detector. A contamination flag that
fires on correct behaviour is worse than none, because it discards good runs.")

(defun contamination-in (commands root)
  "Commands that reached toward the harness. Not scored -- a contaminated
attempt is discarded, because it may have read the answer key."
  (remove-if-not (lambda (command)
                   (or (search root command :test #'char-equal)
                       (some (lambda (tell) (search tell command :test #'char-equal))
                             +harness-tells+)))
                 commands))

(defun attempt-total (attempt)
  "Sum of the cases that produced a score. Reporting only -- selection and
comparison must use the per-case vector, or a harness that is good at
correctness and bad at preserving state looks the same as one that is mediocre
at both."
  (reduce #'+ (remove nil (mapcar #'cdr (attempt-scores attempt))) :initial-value 0))

(defun attempt-ceiling (attempt) (length (attempt-scores attempt)))

(defun attempt-fraction (attempt)
  (let ((ceiling (attempt-ceiling attempt)))
    (if (plusp ceiling) (/ (attempt-total attempt) ceiling) 0)))

(defun attempt-repeatedly (task &rest options &key (times 3) &allow-other-keys)
  "Attempt TASK several times and return every attempt.

Required rather than thorough. Two full calibration sweeps of the same 14 tasks
against the same two models, at temperature 0 and a fixed seed, disagreed on
**6 of 25 comparable cells** -- 24%. Hosted providers do not promise determinism
and do not deliver it, so a single sample per cell cannot support a comparison:
most differences an A/B would report at n=1 are inside that noise."
  (let ((once (a:remove-from-plist options :times)))
    (loop repeat times collect (apply #'attempt-task task once))))

(defun fraction-summary (attempts)
  "(values mean lowest highest) over ATTEMPTS that actually reached the model.
Reporting a mean without its spread is what makes n=1 noise look like a result."
  (let ((scored (remove-if #'attempt-error attempts)))
    (if (null scored)
        (values nil nil nil)
        (let ((fractions (mapcar #'attempt-fraction scored)))
          (values (/ (reduce #'+ fractions) (length fractions))
                  (reduce #'min fractions)
                  (reduce #'max fractions))))))

(defun score-cases (cases)
  "Mirrors TRIAL:SCORE-CASE: a case that signals scores NIL, which is different
information from a case that ran and scored zero."
  (mapcar (lambda (entry)
            (cons (car entry) (handler-case (funcall (cdr entry)) (error () nil))))
          cases))

(defun bench-tool-set (&optional oracle)
  "Arm A's fixed set, plus the observational floor, plus optionally an oracle.

INSPECT_VALUE belongs to the CONTROL set rather than being an extra. Without it
the agent can change a running image and cannot see into it, so a task whose
evidence lives in runtime values is UNREACHABLE rather than expensive -- and a
capability that turns impossible into possible manufactures a result instead of
measuring one. See docs/b14-preregistration.md, Gate 1.

Every tool is wrapped for recording, including the oracle, so the oracle arm's
burden is counted the same way the control arm's is."
  (burden:recording-tool-set
   (append (image-tools:tool-set) (inspect:tool-set) (a:ensure-list oracle))))

(defun attempt-task (task &key provider model (limit 12) (reasoning-effort "low")
                              (max-tokens 4096) on-event oracle)
  "Set TASK up, let an agent attempt it, and score the image afterwards."
  (let* ((backend (make-instance 'image:sbcl-image :package (task-package task)))
         (label (or model "unnamed")))
    (setup task backend)
    (let ((cases (cases-for task backend))
          (start (get-internal-real-time)))
      (let ((agent (make-instance 'bench-agent
                                  :provider provider :model model :limit limit
                                  :reasoning-effort reasoning-effort
                                  :max-tokens max-tokens :on-event on-event
                                  :system-prompt image-tools:*system-prompt*
                                  :tools (bench-tool-set oracle))))
        (let* ((jail (jail-directory task))
               (image-tools:*bash-commands* '())
               (burden:*log* '())
               ;; Unqualified names in INSPECT_VALUE resolve in the task's own
               ;; package, which is also the only package it can reach.
               (inspect:*package-under-inspection* (find-package (task-package task)))
               (failure
                 (handler-case
                     (let ((image-tools:*backend* backend)
                           ;; The shell runs somewhere with nothing in it. An
                           ;; agent that shells out from the repository root
                           ;; can read the answer key, and one already went
                           ;; looking -- see +HARNESS-TELLS+.
                           (image-tools:*bash-directory* jail))
                       (inspect:begin-inspection-session)
                       (loop*:run agent (list (msg:make-user-message
                                               :content (list (msg:make-text (task-prompt task))))))
                       nil)
                   (error (condition) (princ-to-string condition)))))
          (make-attempt :task (task-id task) :label label
                        :scores (score-cases cases)
                        :requests (bench-requests agent)
                        :burden (burden:burden-report burden:*log*)
                        :elapsed-ms (round (- (get-internal-real-time) start)
                                           (/ internal-time-units-per-second 1000))
                        :error failure
                        :contamination (contamination-in
                                        (reverse image-tools:*bash-commands*)
                                        (namestring (repository-root)))))))))

(defun repository-root ()
  (or (a:when-let ((override (sb-posix:getenv "VIVARIUM_ROOT")))
        (and (plusp (length override)) override))
      (namestring (asdf:system-source-directory "vivarium"))))

(defun jail-directory (task)
  "A fresh empty directory per attempt, so the shell starts nowhere useful."
  (let ((path (merge-pathnames (format nil "vivarium-~(~a~)-~36r/"
                                       (task-id task) (random (expt 36 8)))
                               (uiop:temporary-directory))))
    (ensure-directories-exist path)
    path))
