;;;; The control task: nothing is broken.
;;;;
;;;; Without it an agent that always edits is indistinguishable from one that
;;;; diagnoses, and every pass rate in the set is inflated by the same unknown
;;;; amount. Scored behaviourally like everything else -- the ledger says whether
;;;; a definition was touched, so no case has to read what the agent claimed.

(in-package #:vivarium.tasks)

(deftask :t14 (:family :control :split :train :package "VIVARIUM.TASK.T14")
  "A report came in that ORDER-TOTAL is mishandling comped lines, whose price is
NIL. The correct total for *LINES* is 35.

Establish whether the report is right, and leave the image correct."
  (lambda (backend package)
    (declare (ignore package))
    (service:install-all
     backend
     (list "(defparameter *lines* (list (list :qty 2 :price 5) (list :qty 3 :price 5)
                                    (list :qty 4 :price nil) (list :qty 1 :price 10)))"
           "(defun order-total (lines)
  (reduce #'+ lines
          :key (lambda (line) (* (getf line :qty) (or (getf line :price) 0)))
          :initial-value 0))")))
  (lambda (package backend)
    (let ((lines (service:value-in package '#:*lines*))
          (installs (lambda ()
                      (count "DEFUN VIVARIUM.TASK.T14::ORDER-TOTAL"
                             (ledger:entries (image:image-ledger backend))
                             :key #'ledger:entry-target :test #'string=))))
      (list (cons "still-correct"
                  (lambda () (score (eql 35 (ignore-errors
                                             (service:call-in package '#:order-total lines))))))
            (cons "left-alone"
                  ;; One entry is the fixture's own install. Anything above that
                  ;; is the agent rewriting code that was already right.
                  (lambda () (score (= 1 (funcall installs)))))
            (cons "lines-intact"
                  (lambda () (score (eql 4 (length (service:value-in package '#:*lines*))))))))))
