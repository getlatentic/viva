;;;; Can a threaded SBCL image fork a child that compiles and runs code?
;;;; Stage 1: single-threaded.  Stage 2: after spawning worker threads.
;;;; Stage 3: with genera-lab loaded and its web server actually serving.

(require :sb-posix)

(defvar *dir* (or (sb-posix:getenv "PROBE_DIR") "/tmp"))

(defun child-path (label)
  (format nil "~a/child-~a.txt" *dir* label))

(defun slurp (path)
  (if (probe-file path)
      (with-open-file (in path) (read-line in nil "<empty>"))
      "<no file>"))

(defun ms-since (start)
  (/ (- (get-internal-real-time) start)
     (/ internal-time-units-per-second 1000.0)))

(defun probe (label &key (work (lambda () (funcall (compile nil '(lambda (x) (* x 7))) 6))))
  "Fork; child does WORK and writes the result; parent reports."
  (let ((path (child-path label))
        (threads (length (sb-thread:list-all-threads))))
    (ignore-errors (delete-file path))
    (finish-output)
    (let* ((start (get-internal-real-time))
           (pid (handler-case (sb-posix:fork)
                  (error (e)
                    (format t "~&[~a] threads=~d  FORK REFUSED: ~a~%" label threads e)
                    (return-from probe :fork-refused)))))
      (if (zerop pid)
          (progn
            (handler-case
                (let ((result (funcall work)))
                  (with-open-file (out path :direction :output :if-exists :supersede)
                    (format out "ok result=~a threads-in-child=~d~%"
                            result (length (sb-thread:list-all-threads)))))
              (error (e)
                (ignore-errors
                 (with-open-file (out path :direction :output :if-exists :supersede)
                   (format out "child-error ~a~%" e)))))
            (sb-ext:exit :code 0 :abort t))
          (multiple-value-bind (waited status) (sb-posix:waitpid pid 0)
            (declare (ignore waited))
            (format t "~&[~a] threads=~d  fork+work+reap=~,1fms  status=~d  child: ~a~%"
                    label threads (ms-since start) status (slurp path))
            :ok)))))

(format t "~&=== stage 1: single-threaded ===~%")
(probe "stage1")

(format t "~&=== stage 2: after spawning 4 worker threads ===~%")
(defvar *stop* nil)
(defvar *workers*
  (loop repeat 4
        collect (sb-thread:make-thread
                 (lambda () (loop until *stop* do (sleep 0.05)))
                 :name "probe-worker")))
(sleep 0.2)
(probe "stage2")

(format t "~&=== stage 3: genera-lab loaded and serving ===~%")
(handler-case
    (progn
      (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
      (funcall (find-symbol "QUICKLOAD" "QL") :genera-lab :silent t)
      (format t "~&genera-lab loaded, threads=~d~%" (length (sb-thread:list-all-threads)))
      (let ((start-fn (or (find-symbol "START" "GENERA-LAB.LAB")
                          (find-symbol "START" "GENERA-LAB"))))
        (if start-fn
            (progn
              (handler-case (funcall start-fn)
                (error (e) (format t "~&start failed: ~a~%" e)))
              (sleep 1)
              (format t "~&serving, threads=~d~%" (length (sb-thread:list-all-threads))))
            (format t "~&no START symbol found; probing with load-only threads~%")))
      ;; child work: compile a definition into the image, the way a trial would
      (probe "stage3"
             :work (lambda ()
                     (let ((sym (find-symbol "ORDER-TOTAL" "GENERA-LAB.APP")))
                       (if sym
                           (progn (eval `(defun ,sym (order) (declare (ignore order)) :patched))
                                  (funcall sym nil))
                           :no-order-total)))))
  (error (e) (format t "~&stage 3 setup failed: ~a~%" e)))

(setf *stop* t)
(sb-ext:exit :code 0 :abort t)
