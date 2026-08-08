;;;; The image backend and arm A's tool set.
;;;;
;;;; These tests really do compile definitions into the process running them.
;;;; Everything installed lives in the throwaway package below, so a failing
;;;; test cannot leave a redefined function behind in the test suite itself.

(in-package #:vivarium.tests)

(defpackage #:vivarium.tests.scratch (:use #:cl))

(defun fresh-image ()
  (let ((package (find-package '#:vivarium.tests.scratch)))
    (do-symbols (symbol package)
      (when (eq package (symbol-package symbol))
        (when (fboundp symbol) (fmakunbound symbol))
        (when (boundp symbol) (makunbound symbol))))
    (make-instance 'image:sbcl-image :package "VIVARIUM.TESTS.SCRATCH")))

(defun scratch (name)
  (find-symbol (string-upcase name) '#:vivarium.tests.scratch))

(defmacro with-image ((var) &body body)
  `(let* ((,var (fresh-image))
          (image-tools:*backend* ,var))
     ,@body))

(defun call-tool* (tool &rest arguments)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on arguments by #'cddr
          do (setf (gethash key table) value))
    (tool:execute tool table nil)))

;;; Backend

(define-test "installing a defun makes it callable in this process"
  (with-image (image)
    (let ((result (image:install-definition image "(defun doubler (x) (* 2 x))")))
      (is string= "DEFUN VIVARIUM.TESTS.SCRATCH::DOUBLER" (image:installation-target result))
      (false (image:installation-error result))
      (is = 14 (funcall (scratch "doubler") 7)))))

(define-test "two forms in one install are refused"
  (with-image (image)
    (fail (image:install-definition image "(defun a () 1) (defun b () 2)")
          'image:install-error)))

(define-test "a form that is not a definition is refused"
  (with-image (image)
    (fail (image:install-definition image "(+ 1 2)") 'image:install-error)))

(define-test "a definition that fails to compile reports rather than crashes"
  (with-image (image)
    (let ((result (image:install-definition image "(defun broken (x) (undefined-fn x))")))
      ;; An undefined callee is a style warning, not an error -- the definition
      ;; installs. What must not happen is the install signalling out.
      (false (image:installation-error result))
      (true (image:installation-warnings result)))))

(define-test "a read error is reported as an install error"
  (with-image (image)
    (fail (image:install-definition image "(defun unbalanced (x") 'image:install-error)))

(define-test "the ledger keeps the version each install replaced"
  (with-image (image)
    (image:install-definition image "(defun version (x) (declare (ignore x)) 1)")
    (image:install-definition image "(defun version (x) (declare (ignore x)) 2)")
    (let ((target "DEFUN VIVARIUM.TESTS.SCRATCH::VERSION"))
      (is = 2 (funcall (scratch "version") nil))
      (true (search "1)" (ledger:previous-source (image:image-ledger image) target)))
      (is = 2 (length (ledger:entries (image:image-ledger image) :target target))))))

(define-test "rollback restores the version that was replaced"
  (with-image (image)
    (image:install-definition image "(defun rolled (x) (declare (ignore x)) :first)")
    (image:install-definition image "(defun rolled (x) (declare (ignore x)) :second)")
    (is eq :second (funcall (scratch "rolled") nil))
    (image:rollback-definition image "DEFUN VIVARIUM.TESTS.SCRATCH::ROLLED")
    (is eq :first (funcall (scratch "rolled") nil))))

(define-test "rolling back a first install undefines it"
  (with-image (image)
    (image:install-definition image "(defun only-version () :here)")
    (true (fboundp (scratch "only-version")))
    (image:rollback-definition image "DEFUN VIVARIUM.TESTS.SCRATCH::ONLY-VERSION")
    (false (fboundp (scratch "only-version")))))

;;; Tools

(define-test "the install tool reports the target it compiled"
  (with-image (image)
    (declare (ignore image))
    (let ((result (call-tool* image-tools:install "source" "(defun via-tool (x) x)")))
      (false (tool:tool-result-error-p result))
      (true (search "VIA-TOOL" (tool:tool-result-output result)))
      (is = 3 (funcall (scratch "via-tool") 3)))))

(define-test "the install tool turns a malformed form into an error result"
  (with-image (image)
    (declare (ignore image))
    (let ((result (call-tool* image-tools:install "source" "(+ 1 2)")))
      (true (tool:tool-result-error-p result))
      (true (search "Not a definition" (tool:tool-result-output result))))))

(define-test "read_definition returns what install recorded"
  (with-image (image)
    (declare (ignore image))
    (call-tool* image-tools:install "source" "(defun readable (x) (* x x))")
    (let ((result (call-tool* image-tools:read-definition
                              "target" "DEFUN VIVARIUM.TESTS.SCRATCH::READABLE")))
      (false (tool:tool-result-error-p result))
      (true (search "(* x x)" (tool:tool-result-output result))))))

(define-test "read_definition on an unknown target is an error result"
  (with-image (image)
    (declare (ignore image))
    (let ((result (call-tool* image-tools:read-definition "target" "DEFUN NOWHERE::NOTHING")))
      (true (tool:tool-result-error-p result)))))

(define-test "find_definitions locates an installed definition"
  (with-image (image)
    (declare (ignore image))
    (call-tool* image-tools:install "source" "(defun findable-thing () 1)")
    (let ((result (call-tool* image-tools:find-definitions "pattern" "findable")))
      (true (search "FINDABLE-THING" (tool:tool-result-output result))))))

(define-test "the rollback tool undoes the install tool"
  (with-image (image)
    (declare (ignore image))
    (call-tool* image-tools:install "source" "(defun undoable (x) (declare (ignore x)) :one)")
    (call-tool* image-tools:install "source" "(defun undoable (x) (declare (ignore x)) :two)")
    (call-tool* image-tools:rollback "target" "DEFUN VIVARIUM.TESTS.SCRATCH::UNDOABLE")
    (is eq :one (funcall (scratch "undoable") nil))))

(define-test "bash returns output, and a non-zero exit is an error result"
  (let ((ok (call-tool* image-tools:bash "command" "echo hello-from-bash"))
        (bad (call-tool* image-tools:bash "command" "exit 3")))
    (false (tool:tool-result-error-p ok))
    (true (search "hello-from-bash" (tool:tool-result-output ok)))
    (true (tool:tool-result-error-p bad))
    (true (search "exit 3" (tool:tool-result-output bad)))))

(define-test "a tool used with no backend bound fails its call, not the run"
  (let ((image-tools:*backend* nil))
    (let ((result (call-tool* image-tools:install "source" "(defun nope () 1)")))
      (true (tool:tool-result-error-p result))
      (true (search "backend" (tool:tool-result-output result))))))
