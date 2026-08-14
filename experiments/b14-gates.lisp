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
(defparameter *b14-limit* 16
  "Requests before cutoff. Higher than the task set's usual 12 because this task
is deliberately investigation-heavy, and a cap that truncates the investigation
would measure the cap rather than the burden.")

(defun b14-solved-p (attempt)
  "Frozen: every case passes. Partial credit is not a solve."
  (and (null (tasks:attempt-error attempt))
       (null (tasks:attempt-contamination attempt))
       (let ((scores (tasks:attempt-scores attempt)))
         (and scores (every (lambda (pair) (>= (cdr pair) 1)) scores)))))

(defun b14-run (&key (attempts *b14-attempts*) oracle (label "CONTROL"))
  (let ((arm (or (find "gpt-oss-120b" (available-arms) :key #'arm-label :test #'string=)
                 (error "gpt-oss-120b arm unavailable -- is OPENROUTER_API_KEY set?")))
        (task (tasks:find-task *b14-task*))
        (rows '()))
    (format t "~&~a  task ~a  attempts ~a  limit ~a~%"
            label *b14-task* attempts *b14-limit*)
    (dotimes (i attempts)
      (let* ((attempt (tasks:attempt-task task
                                          :provider (arm-provider arm)
                                          :model (arm-model arm)
                                          :reasoning-effort (arm-effort arm)
                                          :limit *b14-limit*
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
              unless (>= score 1) do (incf (gethash name tally 0))))
      (if (zerop (hash-table-count tally))
          (format t "        none~%")
          (maphash (lambda (name n)
                     (format t "        ~a failed in ~a of ~a~%" name n (length operational)))
                   tally)))
    (format t "~&     VERDICT: ~a~%" (getf verdict :verdict))
    verdict))

(defun b14-gate-1-and-2 ()
  (let* ((rows (b14-run))
         (verdict (b14-report rows)))
    (with-open-file (out (merge-pathnames "b14-gates.sexp" (uiop:temporary-directory))
                         :direction :output :if-exists :supersede)
      (write (list :task *b14-task* :verdict verdict :rows rows) :stream out))
    (format t "~&~%trajectory detail written to ~a -- read it AFTER the verdict above.~%"
            (merge-pathnames "b14-gates.sexp" (uiop:temporary-directory)))
    verdict))
