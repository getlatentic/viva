;;;; E2, claim 2: does a Pareto frontier beat greedy keep-best on equal budget?
;;;;
;;;; No model is involved. Both arms get the same budget, the same starting
;;;; point and the same proposal function; the only difference is which parent
;;;; they breed from. That isolates the selection strategy, which is the thing
;;;; under test -- running this with an LLM proposer would confound the question
;;;; with model quality and tell us nothing about selection.
;;;;
;;;; Every trial is a real forked child scoring a real installed definition, so
;;;; this also exercises the trial machinery at a few hundred forks.
;;;;
;;;;   sbcl --non-interactive --load experiments/e2-selection.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :vivarium/search :silent t)

(defpackage #:vivarium.e2
  (:use #:cl)
  (:local-nicknames (#:image #:vivarium.image)
                    (#:trial #:vivarium.trial)
                    (#:arena #:vivarium.arena)))

(in-package #:vivarium.e2)

(defpackage #:knobs (:use #:cl))

;;; The landscape.
;;;
;;; ACCURACY peaks early at n=10 and dies off. THROUGHPUT is negligible but
;;; always rising until n=25, after which it pays properly. So total score has a
;;; local maximum at n=10 and its global maximum at n=40, with a long valley in
;;; between that no improving step will cross.

(defun accuracy (n) (max 0 (- 10 (abs (- n 10)))))
(defun throughput (n) (if (<= n 25) (/ n 100.0) (- n 25)))
(defun total (n) (+ (accuracy n) (throughput n)))

(defparameter *space* (loop for n from 0 to 40 collect n))
(defparameter *global-best* (first (sort (copy-list *space*) #'> :key #'total)))
(defparameter *local-trap* 10)

(defun knob-value ()
  (funcall (find-symbol "KNOB" '#:knobs)))

(defun cases ()
  (list (cons "accuracy" (lambda () (accuracy (knob-value))))
        (cons "throughput" (lambda () (throughput (knob-value))))))

(defun candidate-for (n &optional parent)
  (trial:make-candidate
   :id n :parent parent
   :definitions (list (cons "DEFUN KNOBS::KNOB"
                            (format nil "(defun knob () ~d)" n)))))

;;; Proposal: local steps only. A search that can jump anywhere does not have a
;;; local optimum to get stuck in, and the question would be meaningless.

(defparameter *steps* '(1 -1 2 -2))

(defun propose (parent-n counter)
  (let ((n (+ parent-n (nth (mod counter (length *steps*)) *steps*))))
    (max 0 (min 40 n))))

(defun search-with (strategy budget)
  (let ((backend (make-instance 'image:sbcl-image :package "KNOBS"))
        (archive (arena:make-archive)))
    (arena:admit archive (trial:run-trial backend (candidate-for 0) (cases)))
    (loop for counter from 0 below budget
          for parent = (arena:select-parent strategy archive)
          for parent-n = (if parent (trial:candidate-id parent) 0)
          for n = (propose parent-n counter)
          do (arena:admit archive
                          (trial:run-trial backend (candidate-for n parent-n) (cases))))
    archive))

(defun best-reached (archive)
  (let ((results (arena:scored archive)))
    (reduce #'max results :key (lambda (r) (total (trial:candidate-id
                                                   (trial:result-candidate r)))))))

(defun explored (archive)
  (sort (remove-duplicates
         (mapcar (lambda (r) (trial:candidate-id (trial:result-candidate r)))
                 (arena:scored archive)))
        #'<))

(defun run (budget)
  (format t "~&landscape: local trap at n=~d (total ~,2f), global best at n=~d (total ~,2f)~%"
          *local-trap* (total *local-trap*) *global-best* (total *global-best*))
  (format t "budget: ~d trials per arm, same proposer, same start~%~%" budget)
  (dolist (strategy '(:greedy :pareto))
    (let* ((start (get-internal-real-time))
           (archive (search-with strategy budget))
           (elapsed (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second))
           (reached (best-reached archive))
           (range (explored archive)))
      (format t "~&=== ~a ===~%" strategy)
      (format t "  best total reached: ~,2f~@[  (global is ~,2f)~]~%"
              reached (total *global-best*))
      (format t "  reached n range:    ~d..~d over ~d distinct settings~%"
              (first range) (car (last range)) (length range))
      (format t "  frontier size:      ~d~%" (length (arena:frontier archive)))
      (format t "  crossed the valley: ~a~%"
              (if (find-if (lambda (n) (> n 25)) range) "YES" "no"))
      (format t "  wall clock:         ~,2fs for ~d trials (~,1f ms each)~%~%"
              elapsed (1+ budget) (/ (* elapsed 1000) (1+ budget)))))
  (format t "~&Read this as: whether keeping a candidate that leads one case while~%")
  (format t "losing on total is what lets the search leave a local optimum.~%"))

(defun budget-sweep (budgets)
  (format t "~&~%=== trapped, or merely slow? ===~%")
  (format t "  Greedy that is trapped cannot improve with budget. A frontier that~%")
  (format t "  is only diluted by round-robin should keep advancing.~%~%")
  (format t "  ~10a ~10a ~10a ~10a~%" "budget" "strategy" "best n" "total")
  (dolist (budget budgets)
    (dolist (strategy '(:greedy :pareto))
      (let* ((archive (search-with strategy budget))
             (range (explored archive))
             (best (car (last range))))
        (format t "  ~10d ~10a ~10d ~10,2f~%" budget strategy best (best-reached archive))))))

(handler-case (progn (run 60) (budget-sweep '(60 150 300 600)))
  (error (condition)
    (format t "~&FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
