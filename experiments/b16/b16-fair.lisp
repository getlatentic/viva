;;;; SBCL measured the way an SBCL expert would write it.
;;;;
;;;; Every cell eagerly allocates a 4096-slot event ring: 32 KB for a session
;;;; that has published nothing. The ring is a CACHE -- the journal is the
;;;; truth, and anything older than the ring is served from disk -- so its size
;;;; is a tuning choice, not a correctness one.
;;;;
;;;; This does not change viva. It rebinds the size the probe spawns with, to
;;;; measure the ceiling of the fix before anyone writes it.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push #p"/Users/dev/workspace/viva/" (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/daemon :silent t))

(defun timed (thunk)
  (let ((start (get-internal-real-time)))
    (funcall thunk)
    (/ (* 1000.0 (- (get-internal-real-time) start)) internal-time-units-per-second)))
(defun best (thunk &optional (runs 5)) (loop repeat runs minimize (timed thunk)))

(defun measure (label ring-size)
  (setf (symbol-value (find-symbol "+TAIL-LIMIT+" "VIVA.ACTOR")) ring-size)
  (let ((work (format nil "/tmp/b16-fair-~a/" ring-size)))
    (ensure-directories-exist work)
    (sb-posix:setenv "VIVA_HOME" (string-right-trim "/" work) 1)
    (sb-ext:gc :full t)
    (let ((before (round (sb-kernel:dynamic-usage) (* 1024 1024))))
      (loop repeat 8000
            do (viva.actor:spawn :label work
                                 :agent (viva.harness:make-workspace-agent :cwd work)))
      (sb-ext:gc :full t)
      (let ((heap (round (sb-kernel:dynamic-usage) (* 1024 1024))))
        (format t "  ~26a ~9d MB ~11,1f ms~%" label heap
                (best (lambda () (sb-ext:gc :full t))))
        (- heap before)))))

(format t "~&  8000 sessions, SBCL~%~%  ~26a ~12a ~14a~%" "ring per session" "heap" "full gc")
(measure "64 slots (grown on demand)" 64)
