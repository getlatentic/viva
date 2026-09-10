;;;; What must a DORMANT session keep resident?
;;;;
;;;; The stall is a full collection over live data, so the question behind the
;;;; substrate comparison is not "which runtime collects better" but "how much
;;;; should be live at all". A session waiting on a person is not doing
;;;; anything; viva already rebuilds sessions from their transcripts when the
;;;; daemon restarts, so the parts are reconstructible.
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push #p"/Users/dev/workspace/viva/" (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/daemon :silent t))
(setf (symbol-value (find-symbol "+TAIL-LIMIT+" "VIVA.ACTOR")) 64)

(defun timed (thunk)
  (let ((start (get-internal-real-time)))
    (funcall thunk)
    (/ (* 1000.0 (- (get-internal-real-time) start)) internal-time-units-per-second)))
(defun best (thunk &optional (runs 5)) (loop repeat runs minimize (timed thunk)))

(defvar *kept* nil)

(defun measure (label make)
  (setf *kept* nil)
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (setf *kept* (loop repeat 8000 collect (funcall make)))
    (sb-ext:gc :full t)
    (let ((delta (- (sb-kernel:dynamic-usage) before)))
      (format t "  ~34a ~8,1f KB ~9d MB ~9,1f ms~%"
              label (/ delta 8000 1024.0)
              (round (sb-kernel:dynamic-usage) (* 1024 1024))
              (best (lambda () (sb-ext:gc :full t)))))))

(let ((work "/tmp/b16-floor/"))
  (ensure-directories-exist work)
  (sb-posix:setenv "VIVA_HOME" "/tmp/b16-floor" 1)
  (format t "~&  8000 dormant sessions, by how much each keeps~%~%")
  (format t "  ~34a ~11a ~11a ~11a~%" "what is resident" "each" "heap" "full gc")
  ;; What a registry row would be: identity and a mailbox, nothing more.
  (measure "id, label, cwd, mailbox only"
           (lambda () (list (viva.session:new-id) work work (sb-concurrency:make-mailbox))))
  ;; What viva keeps today.
  (measure "the whole object graph (spawn)"
           (lambda () (viva.actor:spawn :label work
                                        :agent (viva.harness:make-workspace-agent :cwd work)))))
