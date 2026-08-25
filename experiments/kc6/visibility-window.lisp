;;;; Does an activation become visible to the task that asked for it?
;;;;
;;;; Found by KC6's preflight, which lost this race once where the suite never
;;;; had. The evolution owner used to send :ACTIVATE's answer from inside the
;;;; publish effect, before the later :REBIND-TASK-CONTEXT effect wrote the
;;;; task's box -- so "the activation succeeded" could reach a worker before
;;;; the activation was visible to it, and the worker would fail to resolve
;;;; its own pin. The reply now goes after every effect of the message.
;;;;
;;;; MEASURED, because a race probe that cannot lose is not evidence. The
;;;; window is narrow in practice: the owner reaches the box write faster than
;;;; a caller can start a thread, so 200 rounds miss it every time either way.
;;;; Widened by one line -- (sleep 0.01) between the reply and the box write --
;;;; it separates completely:
;;;;
;;;;   reply inside the effect, window widened   200 of 200 invisible
;;;;   reply after all effects, same widening      0 of 200 invisible
;;;;
;;;; To re-run that discrimination, put (sleep 0.01) after EVOLUTION-PUBLISH in
;;;; the :IMPROVEMENT.ACTIVATED branch of RUN-EVOLUTION-EFFECT and run this;
;;;; it must still report zero. Then move the reply back inside that branch and
;;;; it must report two hundred.
;;;;
;;;;   sbcl --script experiments/kc6/visibility-window.lisp [rounds]

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-truename*)))))
  (push root (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL"))))

(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/daemon :silent t))

(in-package #:viva.actor)

(let ((rounds (or (ignore-errors (parse-integer (second sb-ext:*posix-argv*))) 200))
      (missed 0))
  (setf *journal-root* (format nil "/tmp/kc6-visibility-~36r/"
                               (random (expt 2 30) (make-random-state t))))
  (ensure-directories-exist *journal-root*)
  (ensure-evolver)
  (dotimes (round rounds)
    (let ((task (format nil "visibility-~d" round))
          (component (format nil "visibility-~d" round)))
      (multiple-value-bind (id condition) (create-candidate component '(lambda () :seen))
        (when condition (error "create refused: ~a" condition))
        (activate-candidate task id)
        ;; No wait between the answer and the resolution. The answer is the
        ;; only thing standing between them, which is the claim under test.
        (let ((box (task-context-box task nil))
              (seen nil))
          (bt:join-thread
           (bt:make-thread
            (lambda ()
              (let ((*activation-box* box)
                    (*resolution-task* task)
                    (*resolutions-seen* (make-hash-table :test #'equal)))
                (setf seen (ignore-errors (call-component component)))))
            :name "visibility-worker"))
          (unless (eq :seen seen) (incf missed))))))
  (format t "~&VISIBILITY: ~d of ~d activations invisible to their own task~%"
          missed rounds)
  (finish-output)
  (sb-ext:exit :code (if (zerop missed) 0 1)))
