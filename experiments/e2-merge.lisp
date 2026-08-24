;;;; E2, claim 1: is per-definition merge enough, or is a line-level merge needed?
;;;;
;;;; The claim is that because a candidate is a set of ledger entries, joining
;;;; two of them is per-definition: a target is taken from whichever parent has
;;;; it, and a target both parents changed differently is a conflict reported
;;;; whole rather than a diff to reconcile.
;;;;
;;;; The thing worth measuring is not whether that operation exists -- it plainly
;;;; does -- but how often a real search produces pairs it cannot join. If most
;;;; frontier pairs conflict, per-definition merge is a nicety and the git
;;;; systems' merge layer was carrying real weight.
;;;;
;;;;   sbcl --non-interactive --load experiments/e2-merge.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :viva/search :silent t)

(defpackage #:viva.e2merge
  (:use #:cl)
  (:local-nicknames (#:image #:viva.image)
                    (#:trial #:viva.trial)
                    (#:arena #:viva.arena)))

(in-package #:viva.e2merge)

(defpackage #:dials (:use #:cl))

;;; Two independent dials, each owning one case. Nothing couples them, so the
;;; best possible candidate sets both -- which is precisely what a merge should
;;; be able to construct from two specialists.

(defun accuracy-of (x) (max 0 (- 20 (abs (- x 15)))))
(defun throughput-of (y) (max 0 (- 20 (abs (- y 30)))))

(defun dial (name) (funcall (find-symbol name '#:dials)))

(defun cases ()
  (list (cons "accuracy" (lambda () (accuracy-of (dial "DIAL-A"))))
        (cons "throughput" (lambda () (throughput-of (dial "DIAL-B"))))))

(defun definitions-for (x y)
  (list (cons "DEFUN DIALS::DIAL-A" (format nil "(defun dial-a () ~d)" x))
        (cons "DEFUN DIALS::DIAL-B" (format nil "(defun dial-b () ~d)" y))))

(defun candidate-for (x y &optional parent)
  (trial:make-candidate :id (list x y) :parent parent :definitions (definitions-for x y)))

;;; A search that only ever moves one dial per step, so lineages specialise.

(defun mutate (setting counter)
  (destructuring-bind (x y) setting
    (let ((step (nth (mod counter 4) '(1 -1 2 -2))))
      (if (evenp (floor counter 4))
          (list (max 0 (min 40 (+ x step))) y)
          (list x (max 0 (min 40 (+ y step))))))))

(defun search-pareto (budget)
  (let ((backend (make-instance 'image:sbcl-image :package "DIALS"))
        (archive (arena:make-archive)))
    (arena:admit archive (trial:run-trial backend (candidate-for 0 0) (cases)))
    (loop for counter from 0 below budget
          for parent = (arena:select-parent :pareto archive)
          for setting = (if parent (trial:candidate-id parent) '(0 0))
          for next = (mutate setting counter)
          do (arena:admit archive
                          (trial:run-trial backend
                                           (candidate-for (first next) (second next) setting)
                                           (cases))))
    (values archive backend)))

;;; Measuring

(defun frontier-pairs (archive)
  (let ((front (arena:frontier archive)))
    (loop for (a . rest) on front
          append (loop for b in rest collect (cons a b)))))

(defun conflict-census (archive)
  (let ((pairs (frontier-pairs archive))
        (clean 0) (conflicted 0) (targets '()))
    (dolist (pair pairs)
      (let ((conflicts (arena:conflicts-between (trial:result-candidate (car pair))
                                                (trial:result-candidate (cdr pair)))))
        (if conflicts
            (progn (incf conflicted) (setf targets (union targets conflicts :test #'equal)))
            (incf clean))))
    (values clean conflicted targets)))

(defun scores-of (result)
  (mapcar #'cdr (trial:result-scores result)))

(defun run (budget)
  (multiple-value-bind (archive backend) (search-pareto budget)
    (format t "~&=== search ===~%")
    (format t "  ~d trials, frontier ~d~%"
            (length (arena:archive-results archive)) (length (arena:frontier archive)))

    (format t "~&~%=== can the frontier's specialists be joined? ===~%")
    (multiple-value-bind (clean conflicted targets) (conflict-census archive)
      (format t "  frontier pairs:  ~d~%" (+ clean conflicted))
      (format t "  merge cleanly:   ~d~%" clean)
      (format t "  conflict:        ~d~@[  on ~{~a~^, ~}~]~%" conflicted targets))

    (format t "~&~%=== merging the two complementary leaders ===~%")
    (multiple-value-bind (a b) (arena:complementary-pair archive)
      (if (null a)
          (format t "  no complementary pair -- one candidate leads every case~%")
          (multiple-value-bind (merged conflicts)
              (arena:merge-candidates a b :id :merged)
            (format t "  parent A ~a scores ~a~%" (trial:candidate-id a)
                    (scores-of (find a (arena:scored archive) :key #'trial:result-candidate)))
            (format t "  parent B ~a scores ~a~%" (trial:candidate-id b)
                    (scores-of (find b (arena:scored archive) :key #'trial:result-candidate)))
            (cond
              (conflicts
               (format t "  REFUSED: both parents changed ~{~a~^, ~}~%" conflicts)
               (format t "  Retrying with an explicit resolution, one trial per direction:~%")
               (dolist (direction '(:prefer-a :prefer-b))
                 (let* ((resolved (arena:merge-candidates a b :id direction
                                                          :on-conflict direction))
                        (result (trial:run-trial backend resolved (cases))))
                   (format t "    ~a -> ~a~%" direction (scores-of result)))))
              (t
               (let ((result (trial:run-trial backend merged (cases))))
                 (format t "  merged   scores ~a~%" (scores-of result))))))))

    (format t "~&~%Read this as: whether a search whose candidates carry their whole~%")
    (format t "definition set can still be crossed over per definition.~%")))

(handler-case (run 80)
  (error (condition)
    (format t "~&FAILED: ~a~%" condition)
    (sb-ext:exit :code 1)))

(sb-ext:exit :code 0)
