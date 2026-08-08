;;;; Crossover: joining two candidates, and what happens when they disagree.

(in-package #:vivarium.tests)

(defun candidate-with (id &rest target-source)
  (trial:make-candidate
   :id id
   :definitions (loop for (target source) on target-source by #'cddr
                      collect (cons target source))))

(defun merged-source (candidate target)
  (cdr (assoc target (trial:candidate-definitions candidate) :test #'equal)))

(define-test "candidates touching different definitions merge without conflict"
  (multiple-value-bind (merged conflicts)
      (arena:merge-candidates (candidate-with :a "DEFUN X" "(defun x () 1)")
                              (candidate-with :b "DEFUN Y" "(defun y () 2)")
                              :id :ab)
    (false conflicts)
    (is = 2 (length (trial:candidate-definitions merged)))
    (is string= "(defun x () 1)" (merged-source merged "DEFUN X"))
    (is string= "(defun y () 2)" (merged-source merged "DEFUN Y"))
    (is equal '(:a :b) (trial:candidate-parent merged))))

(define-test "the same definition with the same source is not a conflict"
  (multiple-value-bind (merged conflicts)
      (arena:merge-candidates (candidate-with :a "DEFUN X" "(defun x () 1)")
                              (candidate-with :b "DEFUN X" "(defun x () 1)")
                              :id :ab)
    (false conflicts)
    (is = 1 (length (trial:candidate-definitions merged)))))

(define-test "the same definition with different sources refuses rather than picking"
  (multiple-value-bind (merged conflicts)
      (arena:merge-candidates (candidate-with :a "DEFUN X" "(defun x () 1)")
                              (candidate-with :b "DEFUN X" "(defun x () 2)")
                              :id :ab)
    (false merged)
    (is equal '("DEFUN X") conflicts)))

(define-test "a conflict can be resolved explicitly, in either direction"
  (let ((a (candidate-with :a "DEFUN X" "(defun x () 1)"))
        (b (candidate-with :b "DEFUN X" "(defun x () 2)")))
    (is string= "(defun x () 1)"
        (merged-source (arena:merge-candidates a b :id :ab :on-conflict :prefer-a) "DEFUN X"))
    (is string= "(defun x () 2)"
        (merged-source (arena:merge-candidates a b :id :ab :on-conflict :prefer-b) "DEFUN X"))))

(define-test "conflict detection is per definition, never per line"
  ;; Two candidates that rewrite the same function completely differently still
  ;; produce exactly one conflict, not a diff to reconcile.
  (multiple-value-bind (merged conflicts)
      (arena:merge-candidates
       (candidate-with :a "DEFUN X" "(defun x (n) (reduce #'+ (mapcar #'abs n)))")
       (candidate-with :b "DEFUN X" "(defun x (n) (loop for i in n sum (abs i)))")
       :id :ab)
    (declare (ignore merged))
    (is = 1 (length conflicts))))

(define-test "complementary-pair finds two frontier members leading different cases"
  (let ((archive (stocked-archive
                  (trial:make-result :candidate (candidate-with :fast "DEFUN X" "(defun x () 1)")
                                     :status :ok :scores '(("speed" . 9) ("accuracy" . 1)))
                  (trial:make-result :candidate (candidate-with :sharp "DEFUN Y" "(defun y () 2)")
                                     :status :ok :scores '(("speed" . 1) ("accuracy" . 9))))))
    (multiple-value-bind (a b) (arena:complementary-pair archive)
      (true a)
      (true b)
      (false (eq a b))
      (true (member (trial:candidate-id a) '(:fast :sharp)))
      (true (member (trial:candidate-id b) '(:fast :sharp))))))

(define-test "one candidate leading everything yields no complementary pair"
  (let ((archive (stocked-archive
                  (trial:make-result :candidate (candidate-with :best "DEFUN X" "(defun x () 1)")
                                     :status :ok :scores '(("speed" . 9) ("accuracy" . 9)))
                  (trial:make-result :candidate (candidate-with :worse "DEFUN Y" "(defun y () 2)")
                                     :status :ok :scores '(("speed" . 1) ("accuracy" . 1))))))
    (false (arena:complementary-pair archive))))

(define-test "a merged candidate installs and scores as one unit"
  (let* ((backend (trial-image))
         (merged (arena:merge-candidates
                  (candidate-with :a "DEFUN LEFT" "(defun left () 3)")
                  (candidate-with :b "DEFUN RIGHT" "(defun right () 4)")
                  :id :ab))
         (result (trial:run-trial
                  backend merged
                  (cases "sum" (lambda ()
                                 (+ (funcall (find-symbol "LEFT" '#:vivarium.tests.trial))
                                    (funcall (find-symbol "RIGHT" '#:vivarium.tests.trial))))))))
    (is eq :ok (trial:result-status result))
    (is = 7 (cdr (assoc "sum" (trial:result-scores result) :test #'equal)))))

;;; Frontier degeneration
;;;
;;; Measured, not hypothetical: on a landscape whose scores floor at zero, the
;;; "best on at least one case" definition returned 81 candidates out of 81
;;; trials, and Pareto selection became random sampling.

(define-test "a population of ties does not become the whole frontier"
  (let ((archive (arena:make-archive)))
    (dotimes (i 30)
      (arena:admit archive (fake-result (intern (format nil "TIED-~d" i) :keyword)
                                        "a" 0 "b" 0)))
    (arena:admit archive (fake-result :better "a" 1 "b" 0))
    (let ((front (arena:frontier archive)))
      (is = 1 (length front))
      (is eq :better (trial:candidate-id (trial:result-candidate (first front)))))))

(define-test "candidates with identical scores collapse to one frontier seat"
  (let ((archive (stocked-archive (fake-result :twin-a "a" 5 "b" 5)
                                  (fake-result :twin-b "a" 5 "b" 5))))
    (is = 1 (length (arena:frontier archive)))))

(define-test "genuinely complementary candidates both keep their seat"
  (let ((archive (stocked-archive (fake-result :fast "a" 9 "b" 1)
                                  (fake-result :sharp "a" 1 "b" 9)
                                  (fake-result :beaten "a" 0 "b" 0))))
    (is = 2 (length (arena:frontier archive)))))
