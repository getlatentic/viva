;;;; Forked trials, and selection over the archive.
;;;;
;;;; These really fork. The suite process must therefore be single-threaded,
;;;; which is exactly the constraint the zygote design exists to satisfy -- if
;;;; this file starts failing with NOT-A-ZYGOTE, something in the test harness
;;;; has begun spawning threads and the production path would fail the same way.

(in-package #:vivarium.tests)

(defpackage #:vivarium.tests.trial (:use #:cl))

(defun trial-image ()
  (make-instance 'image:sbcl-image :package "VIVARIUM.TESTS.TRIAL"))

(defun definitions (&rest sources)
  (mapcar (lambda (source) (cons "ignored" source)) sources))

(defun cases (&rest name-and-thunk)
  (loop for (name thunk) on name-and-thunk by #'cddr collect (cons name thunk)))

;;; Forking

(define-test "a trial scores a candidate in a child, leaving the parent untouched"
  (let* ((backend (trial-image))
         (candidate (trial:make-candidate
                     :id :c1
                     :definitions (definitions "(defun answer () 42)")))
         (result (trial:run-trial
                  backend candidate
                  (cases "value" (lambda ()
                                   (funcall (find-symbol "ANSWER" '#:vivarium.tests.trial)))))))
    (is eq :ok (trial:result-status result))
    (is = 42 (cdr (assoc "value" (trial:result-scores result) :test #'equal)))
    ;; The definition the child installed must not exist here.
    (false (fboundp (find-symbol "ANSWER" '#:vivarium.tests.trial)))))

(define-test "two trials do not see each other's definitions"
  (let ((backend (trial-image)))
    (let ((first (trial:run-trial
                  backend
                  (trial:make-candidate :id :a :definitions (definitions "(defun shared () 1)"))
                  (cases "v" (lambda () (funcall (find-symbol "SHARED" '#:vivarium.tests.trial))))))
          (second (trial:run-trial
                   backend
                   (trial:make-candidate :id :b :definitions (definitions "(defun shared () 2)"))
                   (cases "v" (lambda () (funcall (find-symbol "SHARED" '#:vivarium.tests.trial)))))))
      (is = 1 (cdr (assoc "v" (trial:result-scores first) :test #'equal)))
      (is = 2 (cdr (assoc "v" (trial:result-scores second) :test #'equal))))))

(define-test "a case that signals scores NIL rather than zero"
  (let* ((backend (trial-image))
         (result (trial:run-trial
                  backend
                  (trial:make-candidate :id :c :definitions (definitions "(defun fine () 1)"))
                  (cases "good" (lambda () 5)
                         "bad" (lambda () (error "case blew up"))))))
    (is eq :ok (trial:result-status result))
    (is = 5 (cdr (assoc "good" (trial:result-scores result) :test #'equal)))
    (false (cdr (assoc "bad" (trial:result-scores result) :test #'equal)))))

(define-test "a candidate that will not compile is reported, not scored"
  (let* ((backend (trial-image))
         (result (trial:run-trial backend
                                  (trial:make-candidate :id :bad
                                                        :definitions (definitions "(+ 1 2)"))
                                  (cases "v" (lambda () 1)))))
    (is eq :install-failed (trial:result-status result))
    (true (search "Not a definition" (trial:result-detail result)))))

(define-test "a child that hangs is killed and reported as a timeout"
  (let* ((backend (trial-image))
         (result (trial:run-trial backend
                                  (trial:make-candidate :id :slow
                                                        :definitions (definitions "(defun idle () 1)"))
                                  (cases "v" (lambda () (sleep 30) 1))
                                  :timeout 1)))
    (is eq :timeout (trial:result-status result))))

(define-test "a candidate is a set of ledger entries, replayable anywhere"
  (let ((source (make-instance 'image:sbcl-image :package "VIVARIUM.TESTS.TRIAL")))
    (image:install-definition source "(defun replayed () :original)")
    (let* ((candidate (trial:candidate-from-entries
                       (ledger:entries (image:image-ledger source)) :id :replay))
           (result (trial:run-trial (trial-image) candidate
                                    (cases "v" (lambda ()
                                                 (if (eq :original
                                                         (funcall (find-symbol "REPLAYED"
                                                                               '#:vivarium.tests.trial)))
                                                     1 0))))))
      (is eq :ok (trial:result-status result))
      (is = 1 (cdr (assoc "v" (trial:result-scores result) :test #'equal))))))

;;; Selection

(defun fake-result (id &rest case-scores)
  (trial:make-result :candidate (trial:make-candidate :id id)
                     :status :ok
                     :scores (loop for (name score) on case-scores by #'cddr
                                   collect (cons name score))))

(defun stocked-archive (&rest results)
  (let ((archive (arena:make-archive)))
    (dolist (result results) (arena:admit archive result))
    archive))

(define-test "greedy picks the best total, ignoring what it is bad at"
  (let ((archive (stocked-archive (fake-result :allrounder "a" 5 "b" 5)
                                  (fake-result :specialist "a" 9 "b" 0))))
    (is eq :specialist (trial:candidate-id (arena:select-parent :pareto archive)))
    (is eq :allrounder (trial:candidate-id
                        (trial:result-candidate (arena:best-by-total archive))))))

(define-test "the frontier keeps a candidate that wins one case and loses overall"
  (let* ((archive (stocked-archive (fake-result :broad "a" 5 "b" 5)
                                   (fake-result :narrow "a" 9 "b" 0)
                                   (fake-result :nobody "a" 1 "b" 1)))
         (front (mapcar (lambda (r) (trial:candidate-id (trial:result-candidate r)))
                        (arena:frontier archive))))
    (is = 2 (length front))
    (true (member :narrow front))
    (true (member :broad front))
    (false (member :nobody front))))

(define-test "a candidate beaten on every case is dominated"
  (let ((strong (fake-result :strong "a" 9 "b" 9))
        (weak (fake-result :weak "a" 1 "b" 1)))
    (true (arena:dominated-p weak (list strong weak)))
    (false (arena:dominated-p strong (list strong weak)))))

(define-test "a failed case does not win by default"
  (let ((archive (stocked-archive (fake-result :complete "a" 1 "b" 1)
                                  (fake-result :partial "a" nil "b" nil))))
    (let ((front (mapcar (lambda (r) (trial:candidate-id (trial:result-candidate r)))
                         (arena:frontier archive))))
      (is equal '(:complete) front))))

(define-test "pareto selection round-robins the frontier instead of starving it"
  (let* ((archive (stocked-archive (fake-result :broad "a" 5 "b" 5)
                                   (fake-result :narrow "a" 9 "b" 0)))
         (picks (loop repeat 4
                      collect (prog1 (trial:candidate-id (arena:select-parent :pareto archive))
                                (arena:admit archive (fake-result :filler "a" 0 "b" 0))))))
    ;; Both frontier members must be bred from, not just whichever sorts first.
    (is = 2 (length (remove-duplicates picks)))))

(define-test "crashed trials stay in the archive but never enter the frontier"
  (let ((archive (stocked-archive
                  (fake-result :good "a" 3)
                  (trial:make-result :candidate (trial:make-candidate :id :dead)
                                     :status :crashed))))
    (is = 2 (length (arena:archive-results archive)))
    (is = 1 (length (arena:scored archive)))
    (is equal '(:good) (mapcar (lambda (r) (trial:candidate-id (trial:result-candidate r)))
                               (arena:frontier archive)))))

(define-test "the report names who leads each case"
  (let ((text (arena:report (stocked-archive (fake-result :broad "speed" 5 "accuracy" 9)
                                             (fake-result :narrow "speed" 9 "accuracy" 1)))))
    (true (search "frontier 2" text))
    (true (search "speed" text))
    (true (search "NARROW" text))))

(defun open-descriptors ()
  (length (directory "/dev/fd/*" :resolve-symlinks nil)))

(define-test "trials do not leak file descriptors"
  ;; A leak of one descriptor per trial is invisible in a short run and kills a
  ;; long search at the process limit, with an error that names neither pipes
  ;; nor trials. Guarded by counting rather than by running to failure.
  (let* ((backend (trial-image))
         (candidate (trial:make-candidate :id :fd :definitions (definitions "(defun tick () 1)")))
         (probe (lambda ()
                  (trial:run-trial backend candidate
                                   (cases "v" (lambda ()
                                                (funcall (find-symbol "TICK"
                                                                      '#:vivarium.tests.trial))))))))
    (funcall probe)
    (let ((before (open-descriptors)))
      (dotimes (i 20) (funcall probe))
      (true (<= (open-descriptors) (+ before 2))))))
