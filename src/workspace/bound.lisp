;;;; Bounded output.
;;;;
;;;; Every tool that can return an unbounded amount of text goes through here.
;;;; The limits match Pi's so a like-for-like comparison is comparing harnesses
;;;; rather than context budgets: 2000 lines or 50KB, whichever is hit first.
;;;;
;;;; Truncation is always from the head, and always says how to get the rest. A
;;;; tool that silently returns a prefix teaches the model that the file ended
;;;; there.

(in-package #:vivarium.bound)

(defconstant +max-lines+ 2000)
(defconstant +max-bytes+ (* 50 1024))

(defvar *max-lines* +max-lines+)
(defvar *max-bytes* +max-bytes+)

(defstruct (truncation (:conc-name truncation-))
  (text "" :type string)
  (cut-p nil :type boolean)
  (lines 0 :type integer)
  (reason nil :type symbol)
  (first-line-too-long-p nil :type boolean))

(defun utf8-length (text)
  (length (sb-ext:string-to-octets text :external-format :utf-8)))

(defun format-size (bytes)
  (cond ((< bytes 1024) (format nil "~dB" bytes))
        ((< bytes (* 1024 1024)) (format nil "~dKB" (round bytes 1024)))
        (t (format nil "~,1fMB" (/ bytes 1024.0 1024.0)))))

(defun truncate-head (text &key (max-lines *max-lines*) (max-bytes *max-bytes*))
  "Keep the first MAX-LINES lines, or the first MAX-BYTES bytes, whichever ends
sooner. A single line longer than the byte budget is reported rather than cut,
because half a minified bundle is worse than a message saying so."
  (let ((lines (uiop:split-string text :separator (string #\Newline))))
    (cond ((and (<= (length lines) max-lines) (<= (utf8-length text) max-bytes))
           (make-truncation :text text :lines (length lines)))
          ((> (utf8-length (first lines)) max-bytes)
           (make-truncation :text "" :cut-p t :reason :bytes :first-line-too-long-p t))
          (t
           (let ((kept '()) (bytes 0) (count 0) (reason :lines))
             (dolist (line lines)
               (let ((size (1+ (utf8-length line))))
                 (when (>= count max-lines) (return))
                 (when (> (+ bytes size) max-bytes) (setf reason :bytes) (return))
                 (push line kept)
                 (incf bytes size)
                 (incf count)))
             (make-truncation :text (format nil "~{~a~^~%~}" (nreverse kept))
                              :cut-p t :lines count :reason reason))))))
