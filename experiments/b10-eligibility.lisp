;;;; B10 pre-run probe: how long does a train-split attempt actually last?
;;;;
;;;; The checkpoint ordinal N is set by a formula fixed in
;;;; docs/b10-preregistration.md BEFORE this ran:
;;;;
;;;;     N = clamp(floor(median turns to completion / 2), 2, 4)
;;;;
;;;; so this supplies a number and cannot choose one. S2c persisted its
;;;; aggregate table but not its trajectories, so the distribution has to be
;;;; measured rather than recovered.
;;;;
;;;; UNSCORED AND CONTENT-BLIND on purpose. It reads turn counts and token
;;;; usage. It never reads what the agent did, so it cannot become a way of
;;;; picking an interesting moment to interrupt.
;;;;
;;;;   ./bin/viva eval experiments/b10-eligibility.lisp
;;;;   -- or --
;;;;   set -a && . ./.env && set +a
;;;;   sbcl --non-interactive --load experiments/b10-eligibility.lisp

(require :sb-posix)
(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") ql:*local-project-directories*)
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/cli :silent t))

(in-package #:viva.cli)

(defparameter *train* '(:t1 :t4 :t5 :t7 :t9 :t11 :t13 :t14 :t15 :t17
                        :t18 :t19 :t20)
  "The train split, per S1's fixed division plus B10's depth tasks. The held-out
split stays unspent.")

(defun usage-field (usage name)
  "Usage arrives as whatever the provider's JSON decoded to -- a hash table for
jzon. Absent counts are zero, not an error: a probe that dies on a missing
field would cost an attempt to learn nothing."
  (or (and usage (hash-table-p usage) (gethash name usage)) 0))

(defun probe-one (task arm)
  "One unscored attempt. Returns (values turns prompt-tokens completion-tokens error)."
  (let ((prompt 0) (completion 0))
    (let ((attempt
            (tasks:attempt-task
             task
             :provider (arm-provider arm) :model (arm-model arm)
             :reasoning-effort (or (arm-effort arm) "low")
             :on-event
             (lambda (event)
               (when (eq (getf event :type) :message)
                 (a:when-let* ((message (getf event :message))
                               (usage (ignore-errors (msg:assistant-message-usage message))))
                   (incf prompt (or (usage-field usage "prompt_tokens") 0))
                   (incf completion (or (usage-field usage "completion_tokens") 0))))))))
      (values (tasks:attempt-requests attempt) prompt completion
              (tasks:attempt-error attempt)))))

(defun median (numbers)
  (let* ((sorted (sort (copy-list numbers) #'<)) (n (length sorted)))
    (if (zerop n) 0
        (if (oddp n)
            (nth (floor n 2) sorted)
            (/ (+ (nth (1- (/ n 2)) sorted) (nth (/ n 2) sorted)) 2)))))

(defun run-probe ()
  (let ((arm (or (find "gpt-oss-120b" (available-arms) :key #'arm-label :test #'string=)
                 (error "gpt-oss-120b arm unavailable -- is OPENROUTER_API_KEY set?"))))
    (format t "~&arm: ~a (~a)~2%" (arm-label arm) (arm-model arm))
    (format t "~&task   turns   prompt-tok   completion-tok   note~%")
    (let ((turns '()) (prompt-total 0) (completion-total 0))
      (dolist (id *train*)
        (multiple-value-bind (n prompt completion failure)
            (probe-one (tasks:find-task id) arm)
          (push n turns)
          (incf prompt-total prompt)
          (incf completion-total completion)
          (format t "~&~(~a~)~7t~4d~15t~8d~28t~8d~45t~a~%"
                  id n prompt completion (or failure ""))
          (finish-output)))
      (let* ((turns (nreverse turns))
             (med (median turns))
             (n (max 2 (min 4 (floor med 2)))))
        (format t "~2&turns: ~a~%median: ~a~%" turns med)
        (format t "N = clamp(floor(~a / 2), 2, 4) = ~a~%" med n)
        (format t "~%tokens: ~d prompt + ~d completion = ~d over ~d attempts~%"
                (round prompt-total) (round completion-total)
                (round (+ prompt-total completion-total)) (length turns))
        (format t "per attempt: ~d tokens, per turn: ~d~%"
                (round (/ (+ prompt-total completion-total) (max 1 (length turns))))
                (round (/ (+ prompt-total completion-total)
                          (max 1 (reduce #'+ turns)))))
        (format t "~%tasks that would be ineligible at N=~a (completed in fewer turns): ~a~%"
                n (remove-if (lambda (pair) (> (cdr pair) n))
                             (mapcar #'cons *train* turns)))))))

(run-probe)
