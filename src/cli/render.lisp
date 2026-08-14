;;;; What a run looks like, separated from where it is drawn.
;;;;
;;;; One generic function over one event stream, and renderers are consumers of
;;;; it. A transcript and a live screen are not alternatives -- they are two
;;;; consumers, and framing them as a choice was the mistake in the first
;;;; version of this file. B4's post-hoc report is a third consumer over
;;;; recorded events rather than a separate subsystem.
;;;;
;;;; The other half is that a run has two kinds of data and they want different
;;;; treatment. The TRAJECTORY is events: append it. The LEDGER and the SCORES
;;;; are state: you want their current value, and streaming a history of changes
;;;; is strictly worse. Everything below that computes what a pane should say is
;;;; a pure function of the run, so it can be tested without a terminal.

(in-package #:vivarium.cli)

(defun one-line (text limit)
  (let ((flat (substitute #\Space #\Newline (or text ""))))
    (if (> (length flat) limit) (concatenate 'string (subseq flat 0 limit) " …") flat)))

(defgeneric render (renderer event)
  (:documentation "Show one event. A renderer implements only what it cares
about; everything else falls through."
  )
  (:method (renderer event) (declare (ignore renderer event)) nil))

(defun broadcast (renderers event)
  (dolist (renderer renderers) (render renderer event)))

;;; Pure view models -- what a pane should say, with nothing drawn

(defun trajectory-line (event)
  "One line for one event, or NIL for an event that is not worth a line."
  (case (getf event :type)
    (:tool-start
     (let ((call (getf event :call)))
       (format nil "→ ~a ~a" (msg:tool-call-name call)
               (one-line (jzon:stringify (msg:tool-call-arguments call)) 90))))
    (:tool-end
     (let ((result (getf event :result)))
       (format nil "~a ~a" (if (tool:tool-result-error-p result) "✗" "←")
               (one-line (tool:tool-result-output result) 90))))
    (:message
     ;; Assistant text only. INJECT emits :MESSAGE for messages going *in* as
     ;; well, and echoing the prompt back is noise.
     (let ((message (getf event :message)))
       (when (msg:assistant-message-p message)
         (a:when-let ((text (msg:text-of message)))
           (when (plusp (length text)) (one-line text 120))))))
    (:steer (format nil "steer: ~a" (getf event :text)))))

(defun ledger-lines (backend)
  "The image's current state: every definition this run changed, as it was and
as it now is. A query, not an accumulation -- which is why it belongs in a pane
rather than in the log."
  (let ((entries (and backend
                      (remove "fixture" (ledger:entries (image:image-ledger backend))
                              :key #'ledger:entry-note :test #'equal))))
    (if (null entries)
        (list "nothing installed yet")
        (loop for entry in entries
              append (cons (ledger:entry-target entry)
                           (append
                            (a:when-let ((was (ledger:entry-previous-source entry)))
                              (mapcar (lambda (line) (format nil "  was ~a" line))
                                      (uiop:split-string was :separator '(#\Newline))))
                            (mapcar (lambda (line) (format nil "  now ~a" line))
                                    (uiop:split-string (ledger:entry-source entry)
                                                       :separator '(#\Newline)))))))))

(defun score-line (scores)
  (if (null scores)
      "not scored yet"
      (format nil "~{~a~^  ~}"
              (mapcar (lambda (entry)
                        (format nil "~a ~a" (car entry)
                                (cond ((null (cdr entry)) "crash")
                                      (t (format nil "~,2f" (cdr entry))))))
                      scores))))

;;; The transcript: append-only, always on
;;;
;;; Always on even when a screen is up, because the transcript is the artefact.
;;; E5's second kill criterion is whether an operator can tell what the agent
;;; did, and that is answered by something scrollable, greppable and pasteable.

(defclass transcript ()
  ((stream :initarg :stream :reader transcript-stream :initform *standard-output*)))

(defmethod render ((renderer transcript) event)
  (let ((out (transcript-stream renderer)))
    (case (getf event :type)
      (:opening
       (format out "~&~a via ~a~%~%~a~%~%"
               (getf event :task) (getf event :arm) (getf event :prompt)))
      (:scored
       (format out "~&~%what changed in the image~%")
       (dolist (line (ledger-lines (getf event :backend)))
         (format out "~&  ~a~%" line))
       (format out "~&~%what it scored~%")
       (dolist (entry (getf event :scores))
         (format out "~&  ~a ~a~%"
                 (if (cdr entry) (format nil "~5,2f" (cdr entry)) "crash") (car entry)))
       (format out "~&~%~d requests~%" (getf event :requests)))
      (t (a:when-let ((line (trajectory-line event)))
           (format out "~&~a~%" line))))
    (finish-output out)))
