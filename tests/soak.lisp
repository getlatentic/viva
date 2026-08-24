;;;; Churn until told to stop, and prove the organism plateaus.
;;;;
;;;; Standalone, like the other live-*.lisp scripts: never loaded by the suite.
;;;;
;;;;     sbcl --script bin/entry.lisp soak [minutes]
;;;;
;;;; is wired through bin/viva's entry so the .env and systems load the
;;;; same way as everything else. Continuously starts and stops sessions,
;;;; connects and drops clients (some of them deliberately slow), streams
;;;; events, replays old history, cancels turns -- while sampling what a
;;;; long-lived process must keep flat:
;;;;
;;;;     heap after GC, thread count, session registry size, journal lag
;;;;
;;;; A leak shows as monotonic growth across samples; health shows as a
;;;; plateau. Ten green suite runs cannot answer that question; this can.

(in-package #:vivarium.tests)

(defun soak-descriptors ()
  "Open descriptors for this process, or NIL where lsof is unavailable."
  (ignore-errors
   (1- (count #\Newline
              (uiop:run-program (list "lsof" "-p" (format nil "~d" (sb-posix:getpid)))
                                :output :string :error-output nil)))))

(defun soak-sample ()
  (sb-ext:gc :full t)
  (list :heap-mb (round (sb-kernel:dynamic-usage) (* 1024 1024))
        :threads (length (bt:all-threads))
        :cells (length (actor:all-cells))
        :fds (soak-descriptors)
        ;; A growing depth here is the journal owner falling behind or dead --
        ;; the exact unbounded-queue failure the acknowledged design guards.
        :journal-depth (alexandria:when-let ((service vivarium.actor::*journal-service*))
                         (sb-concurrency:mailbox-count
                          (vivarium.actor::journal-mailbox service)))))

(defun soak-rotate-journals ()
  "Completed sessions' journals are rotated out, as a long-lived organism
would rotate them. Run between cycles, when no cell is live -- and it keeps a
multi-hour soak from writing hundreds of thousands of files into /tmp."
  (ignore-errors
   (mapc #'delete-file (directory (merge-pathnames "*.jsonl" actor:*journal-root*)))))

(defun soak-cycle (path)
  "One round of everything the organism does, done carelessly on purpose."
  (with-repository (environment)
    (let ((cell (paced-cell environment :pause 0.005 :limit 3)))
      (actor:submit cell "one")
      ;; A client that attaches and hangs up without reading -- the hostile
      ;; kind.
      (handler-case
          (let ((stream (daemon:connect path)))
            (daemon:request stream "type" "session.attach"
                            "session" (actor:cell-id cell))
            (close stream :abort t))
        (error () nil))
      ;; A client that replays history from zero, politely.
      (handler-case
          (daemon:with-connection (stream path)
            (read-line stream nil nil)
            (daemon:request stream "type" "events"
                            "session" (actor:cell-id cell) "since" 0))
        (error () nil))
      (actor:tell cell :cancel)
      (actor:await-shutdown cell :timeout 30))))

(defun soak (&key (minutes 10) (path (format nil "/tmp/vivarium-soak-~d.sock" (sb-posix:getpid))))
  (setf actor:*journal-root* (format nil "/tmp/vivarium-soak-journal-~d/" (sb-posix:getpid)))
  (daemon:serve :path path :background t)
  (unwind-protect
       (let ((deadline (+ (get-universal-time) (* 60 minutes)))
             (cycles 0)
             (samples '()))
         (let ((next-sample 0))
           (loop while (< (get-universal-time) deadline)
                 do (soak-cycle path)
                    (incf cycles)
                    ;; By time, not by cycle count: a two-minute pass and a
                    ;; two-hour one should both produce a readable log.
                    (when (>= (get-universal-time) next-sample)
                      (setf next-sample (+ (get-universal-time) 30))
                      (soak-rotate-journals)
                      (let ((sample (soak-sample)))
                        (push sample samples)
                        (format t "~&cycle ~6d  heap ~3dMB  threads ~3d  cells ~2d  fds ~a  journal-q ~a~%"
                                cycles (getf sample :heap-mb)
                                (getf sample :threads) (getf sample :cells)
                                (getf sample :fds) (getf sample :journal-depth))
                        (finish-output)))))
         (let* ((ordered (nreverse samples))
                (early (subseq ordered 0 (min 3 (length ordered))))
                (late (last ordered (min 3 (length ordered))))
                (mean (lambda (rows key)
                        (/ (reduce #'+ rows :key (lambda (row) (getf row key)))
                           (max 1 (length rows))))))
           (format t "~&~%~d cycles.~%" cycles)
           (format t "heap    early ~,1fMB -> late ~,1fMB~%"
                   (funcall mean early :heap-mb) (funcall mean late :heap-mb))
           (format t "threads early ~,1f -> late ~,1f~%"
                   (funcall mean early :threads) (funcall mean late :threads))
           (when (getf (first late) :fds)
             (format t "fds     early ~,1f -> late ~,1f~%"
                     (funcall mean early :fds) (funcall mean late :fds)))
           (multiple-value-bind (kept total) (daemon:diagnostics)
             (declare (ignore kept))
             (format t "contained failures over the run: ~d~%" total))
           (let ((flat (and (<= (funcall mean late :heap-mb)
                                (+ (funcall mean early :heap-mb) 32))
                            (<= (funcall mean late :threads)
                                (+ (funcall mean early :threads) 3))
                            (or (null (getf (first late) :fds))
                                (<= (funcall mean late :fds)
                                    (+ (funcall mean early :fds) 16))))))
             (format t "~:[GREW -- investigate before any long-lived claim~;PLATEAU~]~%" flat)
             (if flat 0 1))))
    (daemon:stop)))
