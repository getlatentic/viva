;;;; The SBCL half of B7 probe 1.
;;;;
;;;; B6 measured the fork-and-save operation end to end at 388 ms. That is the
;;;; number the story puts beside Pharo's snapshot pause, but the two are not
;;;; the same quantity: Pharo's pause stops the whole image, while SBCL's child
;;;; does the writing and the parent is only stopped for the fork itself. This
;;;; measures the quantity that actually matters for availability -- how long
;;;; the PARENT stops -- so the comparison is between like and like.
;;;;
;;;; The parent runs a tight loop stamping the clock. The longest gap between
;;;; consecutive stamps is the stall a request in that process would have seen.

(require :sb-posix)

(defparameter *events* (make-array 0 :adjustable t :fill-pointer t))
(dotimes (i 5000) (vector-push-extend (list i (get-universal-time)) *events*))

(defun ms (ticks) (/ (* 1000.0 ticks) internal-time-units-per-second))

(defun spin-and-watch (seconds fork-at)
  "Stamp the clock in a tight loop for SECONDS, forking a saving child at FORK-AT.
Returns (values worst-gap-ms fork-call-ms whole-operation-ms)."
  (let* ((start (get-internal-real-time))
         (limit (+ start (* seconds internal-time-units-per-second)))
         (fork-time (+ start (* fork-at internal-time-units-per-second)))
         (forked nil) (child nil)
         (fork-cost 0) (op-start 0) (op-end 0)
         (last (get-internal-real-time)) (worst 0))
    (loop while (< (get-internal-real-time) limit)
          do (let ((now (get-internal-real-time)))
               (let ((gap (- now last)))
                 (when (> gap worst) (setf worst gap)))
               (setf last now)
               (when (and (not forked) (> now fork-time))
                 (setf forked t op-start (get-internal-real-time))
                 (let ((before (get-internal-real-time)))
                   (setf child (sb-posix:fork))
                   (when (zerop child)
                     ;; Child: write the core and die. The parent is already gone
                     ;; from this branch.
                     (sb-ext:save-lisp-and-die "fork.core"))
                   (setf fork-cost (- (get-internal-real-time) before))))
               (when (and forked child (plusp child) (zerop op-end))
                 (multiple-value-bind (pid status)
                     (sb-posix:waitpid child sb-posix:wnohang)
                   (declare (ignore status))
                   (when (plusp pid) (setf op-end (get-internal-real-time)))))))
    (values (ms worst) (ms fork-cost)
            (if (plusp op-end) (ms (- op-end op-start)) :still-running))))

(multiple-value-bind (worst fork-ms op-ms) (spin-and-watch 6 2)
  (format t "~%parent worst stall  : ~,1f ms~%" worst)
  (format t "fork() call itself  : ~,1f ms~%" fork-ms)
  (format t "whole operation     : ~a ms~%" op-ms)
  (format t "core bytes          : ~a~%"
          (ignore-errors (with-open-file (s "fork.core") (file-length s))))
  (format t "events in parent    : ~a~%" (length *events*)))
(sb-ext:quit)
