;;;; A session's inbox: the work a crash must not lose.
;;;;
;;;; The turn running, every turn accepted and not yet started, and the request
;;;; ids recent prompts arrived with. The live marker carries all of it, and is
;;;; rewritten whenever it changes and before a prompt is acknowledged -- so a
;;;; crash at any moment either loses a prompt nobody was told about or keeps
;;;; one somebody was. spec/Resumption.tla checks that, and what breaks it.
;;;;
;;;; Kept apart from the cell, under its own lock: the cell publishes on every
;;;; streamed token, and nothing here should wait on that, nor it on this.

(in-package #:viva.actor)

(defparameter +requests-kept+ 256
  "Request ids remembered per session. A client retries within seconds of a
reconnect; this is the window in which a retried prompt is recognised.")

(defstruct (inbox (:conc-name inbox-))
  ;; Turns minted so far, so an id is never used twice -- not even by the
  ;; daemon that comes back after a crash.
  (turns 0 :type integer)
  ;; (TURN . OPTIONS) of the turn running, or NIL.
  (current nil)
  ;; ((TURN . OPTIONS) ...), oldest first: accepted, not yet started.
  (accepted '() :type list)
  ;; ((REQUEST . TURN) ...), newest first.
  (requests '() :type list)
  (lock (bt:make-lock "viva.inbox") :read-only t))

(defun inbox-accept (inbox prefix options &key request)
  "Mint a turn named after PREFIX for OPTIONS and record it, unless REQUEST
already became one. Returns (values TURN DUPLICATE-P OPTIONS), OPTIONS being
what the turn's :USER-MESSAGE carries."
  (bt:with-lock-held ((inbox-lock inbox))
    (a:if-let ((known (and request (cdr (assoc request (inbox-requests inbox) :test #'equal)))))
      (values known t nil)
      (let* ((turn (format nil "~a-t~d" prefix (incf (inbox-turns inbox))))
             (options (append (list :turn turn) options
                              (when request (list :request request)))))
        (setf (inbox-accepted inbox) (append (inbox-accepted inbox) (list (cons turn options))))
        (when request
          (push (cons request turn) (inbox-requests inbox))
          (when (> (length (inbox-requests inbox)) +requests-kept+)
            (setf (inbox-requests inbox) (subseq (inbox-requests inbox) 0 +requests-kept+))))
        (values turn nil options)))))

(defun inbox-begin (inbox turn)
  "TURN starts: from accepted to running."
  (bt:with-lock-held ((inbox-lock inbox))
    (setf (inbox-current inbox) (assoc turn (inbox-accepted inbox) :test #'equal)
          (inbox-accepted inbox) (remove turn (inbox-accepted inbox) :key #'car :test #'equal))))

(defun inbox-end (inbox turn)
  "TURN is over: nothing runs."
  (bt:with-lock-held ((inbox-lock inbox))
    (when (equal turn (car (inbox-current inbox)))
      (setf (inbox-current inbox) nil))))

(defun inbox-forget (inbox turns)
  "TURNS will not run -- refused, or discarded with the queue -- so a restart
must not bring them back."
  (bt:with-lock-held ((inbox-lock inbox))
    (setf (inbox-accepted inbox)
          (remove-if (lambda (entry) (member (car entry) turns :test #'equal))
                     (inbox-accepted inbox)))))

(defun inbox-pending (inbox)
  "What is accepted and not started, oldest first."
  (bt:with-lock-held ((inbox-lock inbox))
    (copy-list (inbox-accepted inbox))))

;;; On disk

(defun turn-record (entry)
  "(TURN . OPTIONS) as the marker and the handoff write it."
  (destructuring-bind (turn . options) entry
    (event::object "turn" turn
                   "text" (getf options :text)
                   "source" (getf options :source)
                   "retain" (and (getf options :retain) t)
                   "request" (getf options :request))))

(defun turn-entry (record)
  "A turn record back as (TURN . OPTIONS), the options a :USER-MESSAGE carries."
  (let ((turn (gethash "turn" record)))
    (cons turn
          (append (list :turn turn)
                  (a:when-let ((text (gethash "text" record))) (list :text text))
                  (a:when-let ((source (gethash "source" record))) (list :source source))
                  (when (gethash "retain" record) (list :retain t))
                  (a:when-let ((request (gethash "request" record))) (list :request request))))))

(defun requests-record (requests)
  (coerce (mapcar (lambda (pair) (vector (car pair) (cdr pair))) requests) 'vector))

(defun requests-from (records)
  (map 'list (lambda (pair) (cons (aref pair 0) (aref pair 1))) (or records #())))

(defun inbox-fields (inbox)
  "The inbox's part of the live marker, as a plist of JSON fields."
  (bt:with-lock-held ((inbox-lock inbox))
    (list "turns" (inbox-turns inbox)
          "running" (a:when-let ((current (inbox-current inbox))) (turn-record current))
          "accepted" (coerce (mapcar #'turn-record (inbox-accepted inbox)) 'vector)
          "requests" (requests-record (inbox-requests inbox)))))

(defun inbox-from (marker)
  "The inbox a crashed daemon's MARKER describes: the turn it was running first
among the accepted, marked to resume, and the prompts waiting behind it."
  (let ((running (gethash "running" marker)))
    (make-inbox :turns (or (gethash "turns" marker) 0)
                :requests (requests-from (gethash "requests" marker))
                :accepted (append (when (hash-table-p running)
                                    (list (append (turn-entry running) (list :resume t))))
                                  (map 'list #'turn-entry (or (gethash "accepted" marker) #()))))))

(defun write-atomically (path text)
  "Replace PATH with TEXT so that a reader, or a crash, sees the old file or the
new one and never half of either."
  (let ((scratch (format nil "~a.~d.tmp" (namestring path) (sb-posix:getpid))))
    (ensure-directories-exist path)
    (with-open-file (out scratch :direction :output :if-exists :supersede
                                 :external-format :utf-8)
      (write-string text out)
      (finish-output out))
    (sb-posix:rename scratch (namestring path))))
