(require :asdf)
(asdf:initialize-source-registry
 (list :source-registry (list :directory "/Users/dev/workspace/vivarium/") :inherit-configuration))
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "vivarium/tasks") (asdf:load-system "vivarium/cli"))
(in-package #:cl-user)

(defvar *n* 0)
(defun fresh (arm)
  (let* ((task (vivarium.tasks:find-task :f1))
         (backend (make-instance 'vivarium.image:sbcl-image
                                 :package (vivarium.tasks:task-package task))))
    (vivarium.tasks:setup task backend)
    (setf vivarium.inspect:*package-under-inspection*
          (find-package (vivarium.tasks:task-package task))
          vivarium.inspect:*callable*
          (vivarium.inspect:capture-callables
           (find-package (vivarium.tasks:task-package task))
           vivarium.tasks::+f1-observation-api+))
    (vivarium.inspect:begin-inspection-session)
    (setf *n* 0)
    (values task backend (vivarium.tasks:cases-for task backend)
            (vivarium.tasks:experiment-b-tool-set arm))))

(defun use (tools backend name &rest kv)
  (let ((tool (find name tools :key #'vivarium.tool:tool-name :test #'string=))
        (args (make-hash-table :test #'equal)))
    (unless tool (return-from use (format nil "NO SUCH TOOL: ~a" name)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k args) v))
    (let* ((vivarium.image-tools:*backend* backend)
           (r (vivarium.tool:execute tool args nil)))
      (incf *n*)
      (if (stringp r) r
          (format nil "~:[~;[REFUSED] ~]~a" (vivarium.tool:tool-result-error-p r)
                  (vivarium.tool:tool-result-output r))))))

(defun passing (cases &optional show)
  (let ((scores (vivarium.tasks:score-cases cases)))
    (when show (dolist (s scores) (format t "        ~,1f ~a~%" (or (cdr s) -1) (car s))))
    (every (lambda (s) (and (numberp (cdr s)) (>= (cdr s) 1))) scores)))

;;; ---------------- PROOF 1: REACHABILITY (CONTROL, no invocation) ----------
(multiple-value-bind (task backend cases tools) (fresh :control)
  (declare (ignore task))
  (dolist (id '(":ALFA" ":BRAVO" ":CHARLIE" ":DELTA" ":ECHO" ":FOXTROT"))
    (dolist (fn '("USAGE-FOR" "RATE-FOR" "OVERRIDE-FOR" "CURRENT-CHARGE"))
      (use tools backend "inspect_value" "target" fn "args" (vector id))))
  (let ((manual *n*))
    (use tools backend "install_definition" "source"
         "(defun calculate-charge (id)
  (case id (:alfa 120) (:bravo 132) (:charlie 100)
           (:delta 200) (:echo 135) (:foxtrot 90)))")
    (format t "~&PROOF 1 REACHABILITY   ~:[FAIL~;PASS~]   (~d manual observations)~%"
            (passing cases t) manual)))

;;; ---------------- PROOF 2: NON-COLLAPSE -----------------------------------
(multiple-value-bind (task backend cases tools) (fresh :control)
  (declare (ignore task cases))
  (format t "~&PROOF 2 NON-COLLAPSE~%")
  (format t "   defer investigation into the repair  ~a~%"
          (let ((r (use tools backend "install_definition" "source"
                        "(defun calculate-charge (id) (* (usage-for id) (rate-for id)))")))
            (declare (ignore r))
            ;; installs fine -- the CASE is what must reject it
            (multiple-value-bind (task2 backend2 cases2) (fresh :control)
              (declare (ignore task2))
              (use (vivarium.tasks:experiment-b-tool-set :control) backend2
                   "install_definition" "source"
                   "(defun calculate-charge (id) (* (usage-for id) (rate-for id)))")
              (if (passing cases2) "COLLAPSED -- BAD" "REFUSED by scorer"))))
  (format t "   invoke a new helper from CONTROL     ~a~%"
          (progn (use tools backend "install_definition" "source" "(defun h () 1)")
                 (let ((r (use tools backend "inspect_value" "target" "H")))
                   (if (search "REFUSED" r) "REFUSED" (format nil "ALLOWED -- BAD: ~a" r)))))
  (format t "   call_function present in CONTROL?    ~a~%"
          (if (find "call_function" tools :key #'vivarium.tool:tool-name :test #'string=)
              "PRESENT -- BAD" "absent")))

;;; ---------------- PROOF 3: INSTRUMENTALITY + ABLATION ---------------------
(multiple-value-bind (task backend cases tools) (fresh :generic-call)
  (declare (ignore task))
  (use tools backend "install_definition" "source"
       "(defun audit-account (id)
  (list :usage (usage-for id) :rate (rate-for id)
        :override (override-for id) :current (current-charge id)))")
  (dolist (id '(":ALFA" ":BRAVO" ":CHARLIE" ":DELTA" ":ECHO" ":FOXTROT"))
    (use tools backend "call_function" "name" "AUDIT-ACCOUNT" "args" (vector id)))
  (let ((helped *n*))
    (use tools backend "install_definition" "source"
         "(defun calculate-charge (id)
  (case id (:alfa 120) (:bravo 132) (:charlie 100)
           (:delta 200) (:echo 135) (:foxtrot 90)))")
    (let ((before (passing cases)))
      ;; ABLATION: remove the self-created helper, keep the task repair.
      (let ((sym (find-symbol "AUDIT-ACCOUNT" (find-package (vivarium.tasks:task-package (vivarium.tasks:find-task :f1))))))
        (when (and sym (fboundp sym)) (fmakunbound sym)))
      (format t "~&PROOF 3 INSTRUMENTALITY~%")
      (format t "   with helper      ~:[FAIL~;PASS~]   (~d observations vs 24 manual)~%" before helped)
      (format t "   helper ABLATED   ~:[FAIL -- helper WAS the solution~;PASS -- helper was an instrument~]~%"
              (passing cases)))))
