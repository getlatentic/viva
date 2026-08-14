;;;; Does the instrument discriminate?
;;;;
;;;; A benchmark nothing has ever attempted is not a benchmark. If every model
;;;; scores zero on every task the set is unusable and every downstream
;;;; comparison would read as a null result; if every model scores full marks it
;;;; is equally unusable and would read as a tie. Either failure is invisible
;;;; from inside the task set and both would be discovered halfway through an
;;;; experiment, attributed to whatever that experiment was varying.
;;;;
;;;; What this measures is the MODEL, not the harness. Every arm here runs the
;;;; same harness and the same tool set, so the only thing separating the
;;;; columns is the model behind them. Harness comparisons are S3 and S5.
;;;;
;;;;   set -a && . ./.env && set +a
;;;;   sbcl --non-interactive --load experiments/s1-calibration.lisp

(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") ql:*local-project-directories*)
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium/tasks :silent t)

(defpackage #:vivarium.calibration
  (:use #:cl)
  (:local-nicknames (#:tasks #:vivarium.tasks)
                    (#:provider #:vivarium.provider)))
(in-package #:vivarium.calibration)

(defun env (name) (sb-posix:getenv name))

(defstruct arm label provider model (effort "low"))

(defun available-arms ()
  "Only the arms whose credentials are actually present, so a missing key is a
missing column rather than a run of zeros that looks like a model failing."
  (remove
   nil
   (list (when (env "OPENROUTER_API_KEY")
           (make-arm :label "gpt-oss-120b"
                     :provider (provider:openai-provider
                                :endpoint "https://openrouter.ai/api/v1/chat/completions"
                                :api-key (env "OPENROUTER_API_KEY"))
                     :model (or (env "OPENROUTER_MODEL") "openai/gpt-oss-120b")))
         (when (env "DEEPSEEK_API_KEY")
           (make-arm :label "deepseek-flash"
                     :provider (provider:openai-provider
                                :endpoint (or (env "DEEPSEEK_ENDPOINT")
                                              "https://api.deepseek.com/v1/chat/completions")
                                :api-key (env "DEEPSEEK_API_KEY"))
                     :model (or (env "DEEPSEEK_MODEL") "deepseek-v4-flash")
                     :effort nil)))))

;;; Reporting

(defun fraction (attempt)
  (let ((ceiling (tasks:attempt-ceiling attempt)))
    (if (plusp ceiling) (/ (tasks:attempt-total attempt) ceiling) 0)))

(defun scored-attempts (results)
  (remove-if (lambda (result) (tasks:attempt-error (cdr result))) results))

(defun cell (attempt)
  ;; A request that never reached the model is not a model scoring zero, and
  ;; printing both as 0.00 would put an outage in the results table.
  (if (tasks:attempt-error attempt) "err" (format nil "~,2f" (fraction attempt))))

(defun case-line (attempt)
  (format nil "~{~a~^ ~}"
          (mapcar (lambda (entry)
                    (format nil "~a=~a" (car entry)
                            (if (cdr entry) (format nil "~,1f" (cdr entry)) "crash")))
                  (tasks:attempt-scores attempt))))

(defun verdict (results)
  "Sort tasks by what they can and cannot tell apart.

Three buckets, and the distinction between the last two matters more than it
looks. A task every model solves is useless for separating MODELS and is exactly
the task that should separate HARNESSES -- model capability is not the
bottleneck, so a difference there is attributable to the harness. A task no model
solves separates nothing and measures nothing."
  (let ((by-task (make-hash-table :test #'eq)))
    (dolist (result (scored-attempts results))
      (push (fraction (cdr result)) (gethash (car result) by-task)))
    (let ((floored '()) (solved '()) (partial '()) (separating '()))
      (maphash (lambda (id fractions)
                 (cond ((every #'zerop fractions) (push id floored))
                       ((every (lambda (f) (= 1 f)) fractions) (push id solved))
                       ((apply #'= fractions) (push id partial))
                       (t (push id separating))))
               by-task)
      (flet ((tidy (ids) (sort ids #'string< :key #'string)))
        (values (tidy floored) (tidy solved) (tidy partial) (tidy separating))))))

(defun run ()
  (let ((arms (available-arms))
        (results '()))
    (when (null arms)
      (format t "~&No credentials found. Source .env first.~%")
      (sb-ext:exit :code 1))
    (format t "~&=== S1 calibration: ~d tasks x ~d models ===~%~%"
            (length (tasks:all-tasks)) (length arms))
    (format t "~&~12a~{~16a~}~%" "task" (mapcar #'arm-label arms))
    (dolist (task (tasks:all-tasks))
      (let ((row '()))
        (dolist (arm arms)
          (let ((attempt (tasks:attempt-task task
                                             :provider (arm-provider arm)
                                             :model (arm-model arm)
                                             :reasoning-effort (arm-effort arm)
                                             :limit 12)))
            (push (cons (tasks:task-id task) attempt) results)
            (push attempt row)))
        (setf row (nreverse row))
        (format t "~&~12a~{~16a~}  ~a~%"
                (tasks:task-id task)
                (mapcar #'cell row)
                (case-line (first row)))
        (dolist (attempt row)
          (when (tasks:attempt-error attempt)
            (format t "~&              ~a ERROR: ~a~%"
                    (tasks:attempt-label attempt)
                    (subseq (tasks:attempt-error attempt)
                            0 (min 90 (length (tasks:attempt-error attempt)))))))
        (finish-output)))
    (multiple-value-bind (floored solved partial separating) (verdict results)
      (format t "~&~%=== what each task can tell apart ===~%")
      (format t "  separates the models    : ~2d  ~{~a ~}~%" (length separating) separating)
      (format t "  partly solved, tied     : ~2d  ~{~a ~}~%" (length partial) partial)
      (format t "  solved by both          : ~2d  ~{~a ~}~%" (length solved) solved)
      (format t "    ^ not waste: model capability is not the bottleneck on these,~%")
      (format t "      so a harness that fails them fails for harness reasons.~%")
      (format t "  solved by neither       : ~2d  ~{~a ~}~%" (length floored) floored)
      (format t "    ^ measures nothing. Fix the task or retire it.~%")
      (let ((errors (- (length results) (length (scored-attempts results)))))
        (when (plusp errors)
          (format t "  runs lost to transport  : ~2d~%" errors)))
      (format t "~&~%  mean requests: ~,1f of a ~d cap~%"
              (/ (reduce #'+ results :key (lambda (r) (tasks:attempt-requests (cdr r))))
                 (length results))
              12))))

(handler-case (run)
  (error (condition) (format t "~&FAILED: ~a~%" condition) (sb-ext:exit :code 1)))
(sb-ext:exit :code 0)
