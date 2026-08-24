;;;; B14 diagnostic -- was the constraint ever visible before the agent committed?
;;;;
;;;; Run 3 narrowed E24 to one behaviour: the agent discovers stale quotes,
;;;; derives a generic predicate, installs it, executes it, and destroys the
;;;; negotiated population every time. Scores cannot say why, and three readings
;;;; imply three different fixes:
;;;;
;;;;   A NONE       *NEGOTIATED* never reached the context. A SEARCH problem --
;;;;                the symptom does not point at a second location.
;;;;   B NAME_ONLY  it was named in a tool result and never inspected. PREMATURE
;;;;                HYPOTHESIS CLOSURE -- the agent stopped once one story
;;;;                explained the symptom.
;;;;   C INSPECTED  it was read and the repair ignored it anyway. EVIDENCE
;;;;                INTEGRATION failure -- the agent had both facts and still
;;;;                wrote `stored /= current` instead of
;;;;                `stored /= current AND NOT negotiated`.
;;;;
;;;; TIMING SEPARATES A FROM B AND B FROM C. Exposure after the repair is already
;;;; installed is search termination; exposure before it is integration failure.
;;;; So commitment is recorded, not just contact.

(in-package #:viva.cli)

(defparameter *constraint* "NEGOTIATED")

(defun mentions-constraint-p (text)
  (and (stringp text) (search *constraint* (string-upcase text))))

(defun classify-attempt (steps preserved)
  "STEPS is (index tool args-text result-text), oldest first."
  (let ((commit nil) (named nil) (inspected nil))
    (dolist (step steps)
      (destructuring-bind (index tool args result) step
        ;; Commitment is the first act that changes the world.
        (when (and (null commit) (member tool '("install" "call_function") :test #'string=))
          (setf commit index))
        ;; Named: the constraint appeared in something the model READ.
        (when (and (null named) (mentions-constraint-p result))
          (setf named index))
        ;; Inspected: the model asked for it BY NAME -- deliberate contact,
        ;; not incidental appearance in a listing.
        (when (and (null inspected)
                   (string= tool "inspect_value")
                   (mentions-constraint-p args))
          (setf inspected index))))
    (list :exposure (cond (inspected :inspected) (named :name-only) (t :none))
          :timing (let ((contact (or inspected named)))
                    (cond ((null contact) :never)
                          ((null commit) :no-commit)
                          ((< contact commit) :before-commit)
                          (t :after-commit)))
          :repair (if preserved :preserves :destroys)
          :first-named named :first-inspected inspected :first-commit commit)))

(defun b14-exposure (&key (attempts 5))
  (let ((arm (or (find "gpt-oss-120b" (available-arms) :key #'arm-label :test #'string=)
                 (error "gpt-oss-120b arm unavailable -- is OPENROUTER_API_KEY set?")))
        (task (tasks:find-task :e24))
        (rows '()))
    (dotimes (i attempts)
      (let* ((steps '()) (n 0)
             (pending nil)
             (attempt
               (tasks:attempt-task
                task :provider (arm-provider arm) :model (arm-model arm)
                     :reasoning-effort (arm-effort arm) :limit *b14-limit*
                     :on-event
                     (lambda (event)
                       (case (getf event :type)
                         (:tool-start
                          (let ((c (getf event :call)))
                            (setf pending
                                  (list (incf n) (msg:tool-call-name c)
                                        (with-output-to-string (s)
                                          (maphash (lambda (k v) (format s "~a=~a " k v))
                                                   (msg:tool-call-arguments c)))))))
                         (:tool-end
                          (when pending
                            (push (append pending
                                          (list (princ-to-string
                                                 (tool:tool-result-output (getf event :result)))))
                                  steps)
                            (setf pending nil)))))))
             (preserved (let ((case* (assoc "negotiated-quotes-preserved"
                                            (tasks:attempt-scores attempt) :test #'string=)))
                          (and case* (numberp (cdr case*)) (>= (cdr case*) 1))))
             (verdict (classify-attempt (nreverse steps) preserved)))
        (push verdict rows)
        (format t "~&~2d  exposure ~12a timing ~14a repair ~a   ~
first-named ~a first-inspected ~a first-commit ~a~%"
                (1+ i) (getf verdict :exposure) (getf verdict :timing) (getf verdict :repair)
                (getf verdict :first-named) (getf verdict :first-inspected)
                (getf verdict :first-commit))))
    (let ((rows (nreverse rows)))
      (format t "~2&CLASSIFICATION over ~a attempts~%" (length rows))
      (dolist (key '(:exposure :timing :repair))
        (let ((tally (make-hash-table)))
          (dolist (r rows) (incf (gethash (getf r key) tally 0)))
          (format t "  ~a~{ ~a=~a~}~%" key
                  (let ((out '())) (maphash (lambda (k v) (push v out) (push k out)) tally)
                       (nreverse out)))))
      (format t "~&READ: none=search problem | name-only+before-commit=premature closure~%")
      (format t "      inspected+before-commit=EVIDENCE INTEGRATION FAILURE~%")
      rows)))
