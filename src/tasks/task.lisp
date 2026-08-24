;;;; What a task is, and the registry of them.
;;;;
;;;; Cases are thunks because RUN-TRIAL already takes ((name . thunk) ...) and
;;;; already scores a thunk that signals as NIL rather than zero -- a crash and a
;;;; wrong answer must not be the same number.
;;;;
;;;; Cases are built AFTER setup, so a case can close over state the setup made.

(in-package #:viva.tasks)

(defstruct (task (:conc-name task-))
  (id nil :type symbol)
  ;; :A-STATE :A-LIVE :A-FLIGHT -- the three faces of the one asymmetry a file
  ;; harness cannot reach. :B-CAPABILITY -- acquiring a tool mid-run.
  ;; :M-CONFLICT / :M-COMPLEMENT -- the pair E2 claim 1 has never had.
  ;; :CONTROL -- nothing is broken.
  (family nil :type symbol)
  (split :train :type (member :train :held-out))
  (package "" :type string)
  (prompt "" :type string)
  ;; (lambda (backend package) ...) -- installs definitions, then builds state.
  (setup nil :type (or null function))
  ;; (lambda (package backend) -> ((name . thunk) ...)), each thunk returning
  ;; [0,1]. The backend is passed because a case may need the ledger -- whether
  ;; a definition was rolled back or rewritten is a fact about the ledger, and
  ;; it is still a fact about the image rather than about the agent's report.
  (cases nil :type (or null function))
  ;; Populated by S5: the same defect as source on disk, so the file-based
  ;; control can attempt the task and be scored by these same cases.
  (file-form nil))

(defvar *registry* (make-hash-table :test #'eq))

(defun register-task (task)
  "Idempotent, so reloading a family file replaces rather than duplicates."
  (setf (gethash (task-id task) *registry*) task))

(defun find-task (id)
  (or (gethash id *registry*)
      (error "No such task: ~a. Known: ~{~a~^ ~}" id (mapcar #'task-id (all-tasks)))))

(defun all-tasks ()
  (sort (a:hash-table-values *registry*) #'string< :key (lambda (task) (string (task-id task)))))

(defun tasks-in (split)
  (remove split (all-tasks) :key #'task-split :test-not #'eq))

(defun task-families ()
  (remove-duplicates (mapcar #'task-family (all-tasks))))

(defmacro deftask (id (&key family split package) prompt setup cases)
  "Declarative because there are fourteen of these and the shape must be
obvious at a glance."
  `(register-task
    (make-task :id ,id :family ,family :split ,split :package ,package
               :prompt ,prompt :setup ,setup :cases ,cases)))

;;; Running one

(defun setup (task backend)
  "Establish the task's world. Runs in the zygote, before any fork, so every
trial inherits the same warm state."
  (service:fresh-package (task-package task))
  (funcall (task-setup task) backend (task-package task))
  task)

(defun cases-for (task backend)
  "Build the task's cases. Must be called AFTER SETUP and BEFORE the agent or
the candidate acts: a case closes over the pre-change world it will later
compare against, and there is nowhere else to capture it from."
  (funcall (task-cases task) (task-package task) backend))

;;; Scoring vocabulary
;;;
;;; Every case returns [0,1]. RUN-TRIAL does not require it, but without it
;;; scores are not comparable across tasks and a frontier over mixed magnitudes
;;; means nothing.

(defun score (condition) (if condition 1.0 0.0))

(defun scored-fraction (achieved total)
  (if (plusp total) (max 0.0 (min 1.0 (/ (float achieved) total))) 0.0))

(defun intact-p (package name expected-count)
  "Did the pre-existing state survive? This is the case a file-based harness
cannot pass: its only way to apply a fix is to reload, and the reload is what
destroys the thing being counted."
  (let ((live (service:value-in package name)))
    (score (= expected-count (if (hash-table-p live) (hash-table-count live) (length live))))))
