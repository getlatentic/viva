;;;; Running one scored trial in a forked copy of the image.
;;;;
;;;; Shape forced by measurement, not preference. SBCL refuses to fork with more
;;;; than one thread running, so the process that forks trials can never be the
;;;; one serving traffic: it is a zygote that loads the code and the fixtures and
;;;; then spawns nothing. See e1-trial-isolation.md.
;;;;
;;;; A child installs a candidate, scores it, writes the scores back down a pipe
;;;; and _exits. Nothing it does -- a wedged heap, a redefinition that breaks the
;;;; world, an infinite loop -- can reach the parent, which is the same property
;;;; that makes the fork worth its ~30ms.
;;;;
;;;; Scores are per case, never one number. A single scalar per candidate makes a
;;;; Pareto frontier impossible and silently collapses the search back into
;;;; greedy hill-climbing.

(in-package #:viva.trial)

(defun obj (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr do (setf (gethash key table) value))
    table))

(defstruct (candidate (:conc-name candidate-))
  (id nil)
  ;; ((target . source) ...) -- the genome, in install order.
  (definitions '() :type list)
  ;; Id of the candidate this was derived from, so a win can be traced back
  ;; through the lineage that produced it.
  (parent nil))

(defun candidate-from-entries (entries &key id parent)
  "A candidate is exactly a set of ledger entries, so a trial's output can be
replayed into any image without a textual merge."
  (make-candidate :id id :parent parent
                  :definitions (mapcar (lambda (entry)
                                         (cons (ledger:entry-target entry)
                                               (ledger:entry-source entry)))
                                       entries)))

(defstruct (result (:conc-name result-))
  (candidate nil)
  ;; ((case-name . score) ...) with a score of NIL where the case failed.
  (scores '() :type list)
  (status :ok :type keyword)
  (detail nil)
  (elapsed-ms 0))

(defun result-total (result)
  "Sum of the scores that were produced. For reporting only -- selection must
use the per-case scores."
  (reduce #'+ (remove nil (mapcar #'cdr (result-scores result))) :initial-value 0))

;;; Guards

(define-condition not-a-zygote (error)
  ((threads :initarg :threads :reader not-a-zygote-threads))
  (:report (lambda (condition stream)
             (format stream
                     "Cannot fork a trial: ~d threads are running. SBCL refuses to ~
fork with more than one. Trials must run from a single-threaded zygote, not from ~
a process that serves."
                     (not-a-zygote-threads condition)))))

(defun check-zygote ()
  (let ((threads (length (sb-thread:list-all-threads))))
    (unless (= 1 threads)
      (error 'not-a-zygote :threads threads))))

;;; Child side

(defun apply-candidate (backend candidate)
  "Install every definition in CANDIDATE. Returns NIL, or the first failure."
  (loop for (target . source) in (candidate-definitions candidate)
        for outcome = (handler-case (image:install-definition backend source
                                                              :note "trial candidate")
                        (image:install-error (condition)
                          (image:make-installation
                           :target target :error (image:install-error-detail condition))))
        when (image:installation-error outcome)
          return (format nil "~a: ~a" target (image:installation-error outcome))))

(defun score-case (name function)
  "Run one case. A case that signals scores NIL, which is not the same as zero."
  (cons name (handler-case (funcall function)
               (error () nil))))

(defvar *detail-limit* 4000
  "Longest failure detail a child may report. The parent reaps before it reads,
so the whole payload has to fit the pipe buffer or the child blocks in WRITE and
is killed as a timeout. Scores are tiny; an unbounded error string is not.")

(defun clip (text)
  (if (and text (> (length text) *detail-limit*))
      (concatenate 'string (subseq text 0 *detail-limit*) " ...[truncated]")
      text))

(defun run-child (backend candidate cases write-fd)
  (let* ((failure (apply-candidate backend candidate))
         (payload (if failure
                      (obj "status" "install-failed" "detail" (clip failure))
                      (obj "status" "ok"
                           "scores" (mapcar (lambda (entry)
                                              (let ((scored (score-case (car entry) (cdr entry))))
                                                (obj "case" (string (car scored))
                                                     "score" (cdr scored))))
                                            cases)))))
    (let ((stream (sb-sys:make-fd-stream write-fd :output t :external-format :utf-8)))
      (write-string (jzon:stringify payload) stream)
      (finish-output stream))
    (sb-posix:close write-fd)))

;;; Parent side

(defun drain (read-fd)
  "Read the child's payload and close the descriptor.

The close is not tidiness. Without it every trial leaks one fd and a long search
dies at the process limit -- observed as \"1024 is not of type (UNSIGNED-BYTE
10)\" some hundreds of trials in, which names nothing about pipes and points
nowhere near here."
  (let ((stream (sb-sys:make-fd-stream read-fd :input t :external-format :utf-8)))
    (unwind-protect
         (let ((out (make-string-output-stream)))
           (loop for char = (read-char stream nil nil)
                 while char do (write-char char out))
           (get-output-stream-string out))
      (close stream))))

(defun reap (pid timeout)
  "Wait for PID, killing it if it outlives TIMEOUT. Returns :OK or :TIMEOUT."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (multiple-value-bind (waited status) (sb-posix:waitpid pid sb-posix:wnohang)
        (declare (ignore status))
        (when (plusp waited) (return :ok))
        (when (> (get-internal-real-time) deadline)
          (ignore-errors (sb-posix:kill pid 9))
          (sb-posix:waitpid pid 0)
          (return :timeout))
        (sleep 0.002)))))

(defun parse-payload (text candidate elapsed)
  (if (zerop (length text))
      ;; No payload means the child died before it could report -- a crash, which
      ;; is a different thing from scoring badly and must not be recorded as zero.
      (make-result :candidate candidate :status :crashed :elapsed-ms elapsed
                   :detail "child produced no result")
      (handler-case
          (let* ((json (jzon:parse text))
                 (status (gethash "status" json)))
            (if (string= status "ok")
                (make-result :candidate candidate :status :ok :elapsed-ms elapsed
                             :scores (map 'list
                                          (lambda (entry)
                                            (cons (gethash "case" entry) (gethash "score" entry)))
                                          (gethash "scores" json)))
                (make-result :candidate candidate :status :install-failed :elapsed-ms elapsed
                             :detail (gethash "detail" json))))
        (error (condition)
          (make-result :candidate candidate :status :crashed :elapsed-ms elapsed
                       :detail (princ-to-string condition))))))

(defun run-trial (backend candidate cases &key (timeout 30))
  "Fork, install CANDIDATE, score it against CASES, and return a RESULT.
CASES is ((name . thunk) ...); each thunk returns a number or signals."
  (check-zygote)
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
      (finish-output)
      (let ((pid (sb-posix:fork)))
        (when (zerop pid)
          (ignore-errors (sb-posix:close read-fd))
          (ignore-errors (run-child backend candidate cases write-fd))
          (sb-ext:exit :code 0 :abort t))
        (sb-posix:close write-fd)
        ;; Reap before draining. Draining first blocks until the child closes the
        ;; pipe, which makes the deadline unenforceable -- a child that sleeps
        ;; past its timeout holds the parent in READ, and the timeout never runs.
        ;; This relies on the payload fitting the pipe buffer, which is why
        ;; RUN-CHILD caps what it writes.
        (let* ((outcome (reap pid timeout))
               (text (drain read-fd))
               (elapsed (round (- (get-internal-real-time) start)
                               (/ internal-time-units-per-second 1000))))
          (if (eq outcome :timeout)
              (make-result :candidate candidate :status :timeout :elapsed-ms elapsed
                           :detail (format nil "exceeded ~ds" timeout))
              (parse-payload text candidate elapsed)))))))

(defun run-trials (backend candidates cases &key (timeout 30))
  "Sequentially, because fork cost dominates and does not parallelise here:
20 forks took 28.3ms each in parallel against 31.8ms sequentially."
  (mapcar (lambda (candidate) (run-trial backend candidate cases :timeout timeout))
          candidates))
