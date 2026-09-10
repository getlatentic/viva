;;;; B16 arm 1, measured properly: MIN of several runs, not a median.
;;;;
;;;; A pause is a floor plus whatever the scheduler stole. The minimum is the
;;;; closest estimate of the floor; a median on a busy machine measures the
;;;; machine. The first run of all is discarded because it collects the garbage
;;;; that loading the systems left behind.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push #p"/Users/dev/workspace/viva/" (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/daemon :silent t))
(sb-ext:gc :full t)
(sb-ext:gc :full t)

(defun timed (thunk)
  (let ((start (get-internal-real-time)))
    (funcall thunk)
    (/ (* 1000.0 (- (get-internal-real-time) start)) internal-time-units-per-second)))

(defun best (thunk &optional (runs 5))
  (loop repeat runs minimize (timed thunk)))

(defun sample (label)
  (let ((full (best (lambda () (sb-ext:gc :full t))))
        (nursery (best (lambda () (sb-ext:gc)))))
    (format t "  ~8a ~10,1f ~12,1f ~9d~%" label full nursery
            (round (sb-kernel:dynamic-usage) (* 1024 1024)))
    (finish-output)))

(let ((work (format nil "/tmp/b16b-~36r/" (random (expt 2 32) (make-random-state t)))))
  (ensure-directories-exist work)
  (sb-posix:setenv "VIVA_HOME" (string-right-trim "/" work) 1)
  (format t "~&  sessions   full gc ms   nursery ms   heap MB~%")
  (sample 0)
  (let ((made 0))
    (dolist (target '(500 1000 2000 4000 8000))
      (loop repeat (- target made)
            do (viva.actor:spawn :label work
                                 :agent (viva.harness:make-workspace-agent :cwd work)))
      (setf made target)
      (sample made))))
