;;;; Zygote: a single-threaded image with genera-lab loaded that forks trials.
;;;; Measures per-trial cost sequentially and with a parallel fan-out.

(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(funcall (find-symbol "QUICKLOAD" "QL") :genera-lab :silent t)

(defvar *sym* (find-symbol "ORDER-TOTAL" "GENERA-LAB.APP"))

(defun ms-since (start)
  (/ (- (get-internal-real-time) start)
     (/ internal-time-units-per-second 1000.0)))

(defun trial-work (n)
  "What one trial does: compile a candidate definition in and run it."
  (eval `(defun ,*sym* (order) (declare (ignore order)) ,n))
  (funcall *sym* nil))

(defun fork-trial (n)
  "Fork a child that runs trial N. Returns the child pid."
  (finish-output)
  (let ((pid (sb-posix:fork)))
    (if (zerop pid)
        (progn (trial-work n) (sb-ext:exit :code (mod n 100) :abort t))
        pid)))

(format t "~&threads=~d  loaded=~a~%"
        (length (sb-thread:list-all-threads)) (and *sym* t))

(format t "~&=== sequential: 20 forked trials, one at a time ===~%")
(let ((start (get-internal-real-time)))
  (dotimes (n 20) (sb-posix:waitpid (fork-trial n) 0))
  (let ((total (ms-since start)))
    (format t "total=~,1fms  per-trial=~,2fms~%" total (/ total 20))))

(format t "~&=== parallel fan-out: 20 forked trials at once ===~%")
(let ((start (get-internal-real-time)))
  (let ((pids (loop for n below 20 collect (fork-trial n))))
    (dolist (pid pids) (sb-posix:waitpid pid 0)))
  (format t "total=~,1fms  per-trial=~,2fms~%" (ms-since start) (/ (ms-since start) 20)))

(format t "~&=== in-process baseline: 20 trials, no fork, no isolation ===~%")
(let ((start (get-internal-real-time)))
  (dotimes (n 20) (trial-work n))
  (let ((total (ms-since start)))
    (format t "total=~,1fms  per-trial=~,2fms~%" total (/ total 20))))

(sb-ext:exit :code 0 :abort t)
