;;;; B10 stage 1: the paired fork.
;;;;
;;;; One run to a quiescent turn-4 boundary, then three children from an
;;;; identical world:
;;;;
;;;;     C   control    keep the context and continue
;;;;     S   sham       rebuild the machinery, hand back the transcript
;;;;     A1  recovery   destroy the context, rebuild from the ledger
;;;;
;;;; which decomposes what a single delta would confuse:
;;;;
;;;;     restart / plumbing cost  =  S - C
;;;;     reconstruction tax       =  A1 - S      <- what B10 measures
;;;;     total recovery effect    =  A1 - C
;;;;
;;;; If A1 is slower than C but indistinguishable from S, the measurement was of
;;;; restart machinery rather than of lost cognition.
;;;;
;;;; Every parameter is fixed in docs/b10-preregistration.md and none of them is
;;;; a knob here. See especially: the fork is quiescent, A1 is vivarium's
;;;; existing ledger recovery semantics and must not be enriched, and a task
;;;; that finishes before the checkpoint is INELIGIBLE rather than relocated.
;;;;
;;;;   ./bin/vivarium eval experiments/b10-paired-fork.lisp
;;;;   -- or --
;;;;   set -a && . ./.env && set +a
;;;;   sbcl --non-interactive --load experiments/b10-paired-fork.lisp

(require :sb-posix)
(require :sb-introspect)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") ql:*local-project-directories*)
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :vivarium/cli :silent t))

(in-package #:vivarium.cli)

(defparameter *family-d* '(:t18 :t19 :t20))
(defparameter *checkpoint* 4 "Turn ordinal. Pre-registered, not a knob.")
(defparameter *branch-budget* 8 "Requests each branch gets after the fork.")
(defparameter *branch-kinds* '(:control :sham :recovery))

;;; The boundary
;;;
;;; Forking mid-batch would hand one child a half-applied world, and the delta
;;; would then be a fact about the harness's crash-consistency rather than about
;;; cognition. execute-batch joins its tool threads before RUN-ITERATION
;;; returns, and LEDGER:RECORD persists inside its lock with WITH-OPEN-FILE, so
;;; both are settled once the loop has returned and one thread is running --
;;; which is what this asserts rather than assumes.

(defun assert-quiescent (where)
  (let ((threads (sb-thread:list-all-threads)))
    (unless (= 1 (length threads))
      (error "~a: not quiescent -- ~a threads live: ~{~a~^, ~}"
             where (length threads) (mapcar #'sb-thread:thread-name threads))))
  ;; The fourth clause, learned the hard way. Dexador pools connections, so at
  ;; the fork boundary the parent holds live TLS sockets that are neither an
  ;; in-flight request nor an uncommitted write -- the request finished and the
  ;; socket was parked for reuse. Three children inheriting the same descriptors
  ;; and using them concurrently faults inside the TLS layer: the first stage-1
  ;; run produced 90 memory faults and zero usable branches.
  ;;
  ;; Cleared in the PARENT rather than in each child on purpose. A child that
  ;; closes an inherited socket sends a FIN on a connection the parent still
  ;; believes it owns, so clearing here makes the invariant true instead of
  ;; patching around it: there is nothing shared left to inherit.
  (dex:clear-connection-pool))

;;; Accounting

(defun token-counter (box)
  "BOX is (prompt . completion), accumulated off the provider's usage field."
  (lambda (event)
    (when (eq (getf event :type) :message)
      (a:when-let* ((message (getf event :message))
                    (usage (ignore-errors (msg:assistant-message-usage message))))
        (when (hash-table-p usage)
          (incf (car box) (or (gethash "prompt_tokens" usage) 0))
          (incf (cdr box) (or (gethash "completion_tokens" usage) 0)))))))

(defun branch-agent (arm limit counter)
  (make-instance 'tasks:bench-agent
                 :provider (arm-provider arm) :model (arm-model arm)
                 :limit limit :reasoning-effort (or (arm-effort arm) "low")
                 :max-tokens 4096 :on-event counter
                 :system-prompt image-tools:*system-prompt*
                 :tools (image-tools:tool-set)))

;;; A1 -- vivarium's existing recovery semantics, and nothing more
;;;
;;; The ledger records what was INSTALLED. It does not record what was
;;; considered and rejected, which is the whole point of the comparison: A1 must
;;; not be enriched to carry it, because the moment it does it stops being the
;;; baseline and the A1 -> A2 delta measures nothing.

(defun ledger-recap (backend)
  (let ((entries (ledger:entries (image:image-ledger backend))))
    (if (null entries)
        "Nothing had been installed yet."
        (format nil "~{~a~^~%~}"
                (mapcar (lambda (entry)
                          (format nil "~a~@[  [~a]~]~%  now: ~a~@[~%  was: ~a~]"
                                  (ledger:entry-target entry)
                                  (ledger:entry-outcome entry)
                                  (ledger:entry-source entry)
                                  (ledger:entry-previous-source entry)))
                        (coerce entries 'list))))))

(defun recovery-messages (task backend)
  (list (msg:make-user-message
         :content
         (list (msg:make-text
                (format nil "~a~2%---~2%An earlier attempt at this task was ~
interrupted. These definitions were installed before it stopped; nothing else ~
about that attempt was kept.~2%~a"
                        (tasks:task-prompt task) (ledger-recap backend)))))))

;;; The branches

(defun run-branch (kind task arm backend cases context)
  (let* ((tokens (cons 0 0))
         (start (get-internal-real-time))
         (agent (branch-agent arm *branch-budget* (token-counter tokens)))
         (failure nil))
    (handler-case
        (ecase kind
          ;; Same context object, same agent lineage: just keep going.
          (:control (loop*:run agent '() :context context))
          ;; Machinery rebuilt -- new agent, new tool set, new context -- but
          ;; the transcript is handed back, so cognition is retained and only
          ;; the restart is exercised.
          (:sham (loop*:run agent (copy-list (loop*:context-messages context))
                            :context (loop*:make-context)))
          ;; Context destroyed. Rebuilt from the ledger alone.
          (:recovery (loop*:run agent (recovery-messages task backend)
                                :context (loop*:make-context))))
      (error (condition) (setf failure (princ-to-string condition))))
    (list :kind kind
          :scores (tasks:score-cases cases)
          :turns (tasks:bench-requests agent)
          :prompt-tokens (car tokens)
          :completion-tokens (cdr tokens)
          :elapsed-ms (round (- (get-internal-real-time) start)
                             (/ internal-time-units-per-second 1000))
          :error failure)))

(defun branch-path (task kind)
  (merge-pathnames (format nil "b10-~(~a~)-~(~a~)-~36r.sexp"
                           (tasks:task-id task) kind (random (expt 36 6)))
                   (uiop:temporary-directory)))

(defun fork-branches (task arm backend cases context)
  "Fork one child per branch from the identical post-checkpoint world.

E1 measured this fork at 28-32 ms with full isolation, which is what lets three
branches mutate the same live image without seeing each other. A child writes
its result and leaves via a hard exit: unwinding would run the parent's exit
hooks a second time and flush its streams from three processes."
  (assert-quiescent "before fork")
  (let ((children '()))
    (dolist (kind *branch-kinds*)
      (let* ((path (branch-path task kind))
             (pid (sb-posix:fork)))
        (if (zerop pid)
            (progn
              (let ((result (run-branch kind task arm backend cases context)))
                (with-open-file (out path :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
                  (write result :stream out :readably t)))
              (sb-ext:exit :code 0 :abort t))
            (push (cons pid path) children))))
    (dolist (child children)
      (sb-posix:waitpid (car child) 0))
    (mapcar (lambda (child)
              (with-open-file (in (cdr child)) (read in)))
            (nreverse children))))

;;; One pair

(defun paired-fork (task arm)
  "Run to the checkpoint, then fork C/S/A1. Returns a plist for the whole pair."
  (let ((backend (make-instance 'image:sbcl-image :package (tasks:task-package task))))
    (tasks:setup task backend)
    (let ((cases (tasks:cases-for task backend))
          (context (loop*:make-context))
          (tokens (cons 0 0)))
      (let ((image-tools:*backend* backend)
            (image-tools:*bash-directory* (tasks:jail-directory task))
            (image-tools:*bash-commands* '()))
        (let ((agent (branch-agent arm *checkpoint* (token-counter tokens))))
          (handler-case
              (loop*:run agent (list (msg:make-user-message
                                      :content (list (msg:make-text (tasks:task-prompt task)))))
                         :context context)
            (error (condition)
              (return-from paired-fork
                (list :task (tasks:task-id task) :status :prefix-failed
                      :error (princ-to-string condition)))))
          ;; A task the model finished before the checkpoint is INELIGIBLE. It
          ;; is never relocated to an earlier turn -- that is the researcher
          ;; discretion the fixed ordinal exists to remove.
          (if (< (tasks:bench-requests agent) *checkpoint*)
              (list :task (tasks:task-id task) :status :ineligible
                    :reason :completed-before-checkpoint
                    :turns (tasks:bench-requests agent))
              (list :task (tasks:task-id task) :status :eligible
                    :prefix-turns (tasks:bench-requests agent)
                    :prefix-prompt-tokens (car tokens)
                    :prefix-completion-tokens (cdr tokens)
                    :branches (fork-branches task arm backend cases context))))))))

;;; Reporting

(defun fraction (scores)
  (let ((scored (remove nil (mapcar #'cdr scores))))
    (if (null scored) 0 (/ (reduce #'+ scored) (length scores)))))

(defun branch (pair kind) (find kind (getf pair :branches) :key (lambda (b) (getf b :kind))))

(defun report-pair (pair)
  (format t "~2&=== ~a : ~a~@[ (~a)~]~%" (getf pair :task) (getf pair :status)
          (getf pair :reason))
  (when (eq (getf pair :status) :eligible)
    (format t "prefix: ~a turns, ~a tokens~%"
            (getf pair :prefix-turns)
            (+ (getf pair :prefix-prompt-tokens) (getf pair :prefix-completion-tokens)))
    (format t "~&~10a~8a~10a~10a~10a  ~a~%" "branch" "turns" "tokens" "elapsed" "score" "error")
    (dolist (kind *branch-kinds*)
      (let ((b (branch pair kind)))
        (format t "~&~10a~8d~10d~10d~10,2f  ~a~%"
                (string-downcase kind) (getf b :turns)
                (+ (getf b :prompt-tokens) (getf b :completion-tokens))
                (getf b :elapsed-ms)
                (float (fraction (getf b :scores)))
                (or (getf b :error) ""))))
    (let ((c (branch pair :control)) (s (branch pair :sham)) (a (branch pair :recovery)))
      (flet ((delta (x y key) (- (getf x key) (getf y key))))
        (format t "~&~%  plumbing   S-C : ~+d turns  ~+d tokens~%"
                (delta s c :turns) (- (+ (getf s :prompt-tokens) (getf s :completion-tokens))
                                      (+ (getf c :prompt-tokens) (getf c :completion-tokens))))
        (format t "  recon tax  A1-S: ~+d turns  ~+d tokens~%"
                (delta a s :turns) (- (+ (getf a :prompt-tokens) (getf a :completion-tokens))
                                      (+ (getf s :prompt-tokens) (getf s :completion-tokens))))
        (format t "  total      A1-C: ~+d turns  ~+d tokens~%"
                (delta a c :turns) (- (+ (getf a :prompt-tokens) (getf a :completion-tokens))
                                      (+ (getf c :prompt-tokens) (getf c :completion-tokens))))))))

(defun tokens-of (b) (+ (getf b :prompt-tokens) (getf b :completion-tokens)))

(defun spread (values)
  "Mean, low, high. S2c's rule: a mean without its spread makes n=1 noise look
like a result, and two runs of this very harness already flipped the sign of the
headline quantity."
  (if (null values)
      (values nil nil nil)
      (values (/ (reduce #'+ values) (length values))
              (reduce #'min values) (reduce #'max values))))

(defun summarise (pairs label extract)
  (multiple-value-bind (mean low high) (spread (mapcar extract pairs))
    (when mean
      (format t "~&  ~14a mean ~8,1f   range ~8,1f .. ~8,1f~%" label (float mean)
              (float low) (float high)))))

(defun pair-usable-p (pair)
  "Every branch ran and none errored. A pair with a failed branch is dropped
whole, never half-counted -- averaging a delta over a branch that never made a
request is how a broken instrument produces a confident number."
  (and (eq (getf pair :status) :eligible)
       (every (lambda (b) (and (null (getf b :error)) (plusp (getf b :turns))))
              (getf pair :branches))))

(defun report-stage-1 (pairs)
  (let* ((eligible (remove :eligible pairs :key (lambda (p) (getf p :status)) :test-not #'eq))
         (broken (remove-if #'pair-usable-p eligible))
         (eligible (remove-if-not #'pair-usable-p eligible)))
    (format t "~2&~60,,,'=a~%" "")
    (format t "STAGE 1: ~a pairs, ~a usable, ~a ineligible, ~a dropped for branch failure~%"
            (length pairs) (length eligible)
            (count :ineligible pairs :key (lambda (p) (getf p :status)))
            (length broken))
    (when broken
      (format t "~&DROPPED -- these are not results:~%")
      (dolist (p broken)
        (format t "  ~a: ~{~a~^; ~}~%" (getf p :task)
                (remove nil (mapcar (lambda (b) (getf b :error)) (getf p :branches))))))
    (when (null eligible)
      (format t "~&~%NO USABLE PAIRS. Nothing below would be a measurement.~%")
      (return-from report-stage-1))
    (dolist (id *family-d*)
      (let ((mine (remove id eligible :key (lambda (p) (getf p :task)) :test-not #'eq)))
        (when mine
          (format t "~2&~a  (~a pairs)~%" id (length mine))
          (flet ((br (p k) (branch p k)))
            (summarise mine "score C" (lambda (p) (fraction (getf (br p :control) :scores))))
            (summarise mine "score S" (lambda (p) (fraction (getf (br p :sham) :scores))))
            (summarise mine "score A1" (lambda (p) (fraction (getf (br p :recovery) :scores))))
            (summarise mine "S-C tokens" (lambda (p) (- (tokens-of (br p :sham)) (tokens-of (br p :control)))))
            (summarise mine "A1-S tokens" (lambda (p) (- (tokens-of (br p :recovery)) (tokens-of (br p :sham)))))
            (summarise mine "A1-C tokens" (lambda (p) (- (tokens-of (br p :recovery)) (tokens-of (br p :control)))))
            (summarise mine "S-C turns" (lambda (p) (- (getf (br p :sham) :turns) (getf (br p :control) :turns))))
            (summarise mine "A1-S turns" (lambda (p) (- (getf (br p :recovery) :turns) (getf (br p :sham) :turns))))))))
    (format t "~2&ALL FAMILY D~%")
    (flet ((br (p k) (branch p k)))
      (summarise eligible "score C" (lambda (p) (fraction (getf (br p :control) :scores))))
      (summarise eligible "score S" (lambda (p) (fraction (getf (br p :sham) :scores))))
      (summarise eligible "score A1" (lambda (p) (fraction (getf (br p :recovery) :scores))))
      (summarise eligible "S-C tokens" (lambda (p) (- (tokens-of (br p :sham)) (tokens-of (br p :control)))))
      (summarise eligible "A1-S tokens" (lambda (p) (- (tokens-of (br p :recovery)) (tokens-of (br p :sham)))))
      (summarise eligible "A1-C tokens" (lambda (p) (- (tokens-of (br p :recovery)) (tokens-of (br p :control))))))
    (format t "~2&Read S-C first. If A1-S sits inside the S-C range, the effect~%")
    (format t "is restart machinery and not lost cognition.~%")))

(defun stage-1 (&key (pairs 5))
  (let ((arm (or (find "gpt-oss-120b" (available-arms) :key #'arm-label :test #'string=)
                 (error "gpt-oss-120b arm unavailable -- is OPENROUTER_API_KEY set?")))
        (out (merge-pathnames "b10-stage1.sexp" (uiop:temporary-directory)))
        (collected '()))
    (format t "~&arm: ~a  checkpoint: turn ~a  branch budget: ~a  pairs: ~a~%"
            (arm-model arm) *checkpoint* *branch-budget* pairs)
    (dotimes (i pairs)
      (dolist (id *family-d*)
        (let ((pair (paired-fork (tasks:find-task id) arm)))
          (push pair collected)
          (report-pair pair)
          (finish-output)
          ;; Written after every pair: a run that dies at pair 13 should not
          ;; throw away the twelve that already cost tokens.
          (with-open-file (o out :direction :output :if-exists :supersede
                                 :if-does-not-exist :create)
            (write (reverse collected) :stream o :readably t)))))
    (report-stage-1 (reverse collected))
    (format t "~&~%raw: ~a~%" out)))

(stage-1)
