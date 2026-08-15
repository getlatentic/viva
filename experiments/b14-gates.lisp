;;;; B14.1 -- Gate 1 and Gate 2 on the representative repair.
;;;;
;;;; Every threshold and every definition this script uses is frozen in
;;;; docs/b14-preregistration.md and none of them is a parameter here. The
;;;; script's whole job is to run the attempts and hand the numbers to
;;;; BURDEN:GATE-2, which does not negotiate.
;;;;
;;;; READING ORDER, frozen with the rest and enforced by what this prints:
;;;;
;;;;   1 operational validity   every intended run completed, no contamination
;;;;   2 Gate 1                 solve rate
;;;;   3 Gate 2                 the verdict as returned
;;;;   4 only then              trajectories
;;;;
;;;; So the per-attempt detail is written to a file rather than printed. Reading
;;;; trajectories first makes it far too easy to explain a median of 4 away --
;;;; "the model found a clever shortcut on these three runs" -- and A SHORTCUT IS
;;;; EVIDENCE THAT THE TASK FAILED THE GATE, not an excuse for the number.

(in-package #:vivarium.cli)

(defparameter *b14-task* :e24)
(defparameter *b14-attempts* 5
  "Five, matching B10 and B11's repeat discipline. Gate 2's solve-rate floor of
0.6 is three of these.")
(defparameter *b14-limit* 24
  "Requests before cutoff. Higher than the task set's usual 12 because this task
is deliberately investigation-heavy, and a cap that truncates the investigation
would measure the cap rather than the burden.

RAISED FROM 16 after the first high-effort sweep, where the cap was doing exactly
what this docstring forbids: 4 of 5 attempts hit 16 requests, and the single solve
used all 16. Not a frozen number -- burden >= 6 and solve rate >= 0.6 are frozen
and neither moved.

THE RAISE DISCONFIRMED ITS OWN HYPOTHESIS, which is why it stays recorded at 24
rather than being reverted. At 16 the sweep solved 1 of 5 with burdens 11-23; at
24 it solved 0 of 3 with burdens 25, 30, 30 and every attempt again exhausting the
cap. THE AGENT EXPANDS ITS INVESTIGATION TO FILL WHATEVER BUDGET IT IS GIVEN
rather than converging, so the extra requests bought more looking and no more
finishing -- and the single solve at 16 is better read as variance than as a
budget effect.")

(defun b14-solved-p (attempt)
  "Frozen: every case passes. Partial credit is not a solve."
  (and (null (tasks:attempt-error attempt))
       (null (tasks:attempt-contamination attempt))
       (let ((scores (tasks:attempt-scores attempt)))
         ;; A case that SIGNALLED scores NIL, not 0 -- the agent left the world
         ;; in a state the case could not even be evaluated against. That is
         ;; further from a solve than a plain failure, never closer.
         (and scores (every (lambda (pair) (and (numberp (cdr pair)) (>= (cdr pair) 1)))
                            scores)))))

(defun b14-run (&key (attempts *b14-attempts*) oracle (label "CONTROL")
                     effort model limit (arm-label "gpt-oss-120b"))
  "EFFORT overrides the arm's default. One variable: same task, tools, prompt and
budget, so a difference is attributable to reasoning effort and nothing else.
Gate 1 has failed four times at the arm default of \"low\", and this separates
'the task is too hard' from 'the model is too weak AT THIS EFFORT'."
  (let ((arm (or (find arm-label (available-arms) :key #'vivarium.cli:arm-label :test #'string=)
                 (error "~a arm unavailable -- is its API key set?" arm-label)))
        (task (tasks:find-task *b14-task*))
        (rows '()))
    (format t "~&~a  task ~a  attempts ~a  limit ~a  effort ~a  model ~a~%"
            label *b14-task* attempts (or limit *b14-limit*)
            (or effort (arm-effort arm)) (or model (arm-model arm)))
    (dotimes (i attempts)
      (let* ((attempt (tasks:attempt-task task
                                          :provider (arm-provider arm)
                                          :model (or model (arm-model arm))
                                          :reasoning-effort (or effort (arm-effort arm))
                                          :limit (or limit *b14-limit*)
                                          :oracle oracle))
             (burden (getf (tasks:attempt-burden attempt) :burden))
             (solved (b14-solved-p attempt)))
        (push (list :solved solved
                    :burden burden
                    :requests (tasks:attempt-requests attempt)
                    :fraction (tasks:attempt-fraction attempt)
                    ;; Per-case, not just the aggregate. This run's diagnosis
                    ;; only worked because a pre-run no-repair measurement
                    ;; happened to exist to compare 0.6667 against; B14 should
                    ;; not need that inference twice.
                    :scores (tasks:attempt-scores attempt)
                    :error (tasks:attempt-error attempt)
                    :contamination (tasks:attempt-contamination attempt)
                    :report (tasks:attempt-burden attempt))
              rows)
        (format t "  ~2d/~2d  ~:[    ~;SOLVED~]  burden ~2@a  requests ~2a  score ~,2f~@[  ERROR ~a~]~%"
                (1+ i) attempts solved burden
                (tasks:attempt-requests attempt)
                (tasks:attempt-fraction attempt)
                (tasks:attempt-error attempt))))
    (nreverse rows)))

(defun b14-report (rows &key (label "CONTROL"))
  (let* ((operational (remove-if (lambda (r) (or (getf r :error) (getf r :contamination))) rows))
         (verdict (vivarium.burden:gate-2 (mapcar (lambda (r) (list :solved (getf r :solved)
                                                           :burden (getf r :burden)))
                                         operational))))
    (format t "~2&==== ~a ====~%" label)
    (format t "~&1. OPERATIONAL VALIDITY~%")
    (format t "     intended ~a, completed ~a, errored ~a, contaminated ~a~%"
            (length rows) (length operational)
            (count-if (lambda (r) (getf r :error)) rows)
            (count-if (lambda (r) (getf r :contamination)) rows))
    (when (< (length operational) (length rows))
      (format t "     RUN IS NOT CLEAN -- fix the operation before reading anything below.~%"))
    (format t "~&2. GATE 1 -- solve rate~%")
    (format t "     ~,2f  (~a of ~a solved; frozen floor ~,2f)~%"
            (getf verdict :solve-rate) (getf verdict :solved) (getf verdict :attempts)
            (float vivarium.burden:+solve-rate-threshold+))
    (format t "~&3. GATE 2 -- observation burden, over solved attempts only~%")
    (format t "     median ~a  (frozen threshold ~a)~%"
            (getf verdict :median-burden) vivarium.burden:+burden-threshold+)
    (format t "     burdens ~a~%" (getf verdict :burdens))
    (format t "     inspect calls / investigation requests per solved attempt:~%")
    (dolist (row operational)
      (when (getf row :solved)
        (let ((r (getf row :report)))
          (format t "        ~2a = ~2a inspect + ~2a investigation-only requests (of ~a turns)~%"
                  (getf r :burden) (getf r :inspect-calls)
                  (getf r :investigation-requests) (getf r :turns)))))
    (format t "~&     which cases failed, across all attempts:~%")
    (let ((tally (make-hash-table :test #'equal)))
      (dolist (row operational)
        (loop for (name . score) in (getf row :scores)
              unless (and (numberp score) (>= score 1))
                do (incf (gethash (if (numberp score) name
                                      (concatenate 'string name " [SIGNALLED]"))
                                  tally 0))))
      (if (zerop (hash-table-count tally))
          (format t "        none~%")
          (maphash (lambda (name n)
                     (format t "        ~a failed in ~a of ~a~%" name n (length operational)))
                   tally)))
    (format t "~&     VERDICT: ~a~%" (getf verdict :verdict))
    verdict))

(defun b14-gate-1-and-2 (&key effort model limit (arm-label "gpt-oss-120b"))
  (let* ((rows (b14-run :effort effort :model model :limit limit :arm-label arm-label))
         (verdict (b14-report rows)))
    (with-open-file (out (merge-pathnames "b14-gates.sexp" (uiop:temporary-directory))
                         :direction :output :if-exists :supersede)
      (write (list :task *b14-task* :verdict verdict :rows rows) :stream out))
    (format t "~&~%trajectory detail written to ~a -- read it AFTER the verdict above.~%"
            (merge-pathnames "b14-gates.sexp" (uiop:temporary-directory)))
    verdict))
