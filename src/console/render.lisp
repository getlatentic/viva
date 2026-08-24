;;;; Turning loop events into something a person can follow.

(in-package #:viva.console)

(defvar *colour* t
  "Set to NIL for a plain transcript. Escape codes in a log file are noise.")

(defparameter +styles+
  '((:dim . "2") (:bold . "1") (:red . "31") (:green . "32")
    (:yellow . "33") (:blue . "34") (:cyan . "36")))

(defun paint (text style)
  (let ((code (cdr (assoc style +styles+))))
    (if (and *colour* code)
        (format nil "~c[~am~a~c[0m" #\Escape code text #\Escape)
        text)))

(defun one-line (text &key (width 72))
  (let* ((flat (substitute #\Space #\Newline (string-trim '(#\Space #\Newline #\Tab) text)))
         (squeezed (with-output-to-string (out)
                     (loop with previous = #\a
                           for character across flat
                           do (unless (and (char= #\Space character) (char= #\Space previous))
                                (write-char character out))
                              (setf previous character)))))
    (if (> (length squeezed) width)
        (format nil "~a..." (subseq squeezed 0 width))
        squeezed)))

(defun salient-argument (call)
  "The argument worth showing: the one the tool's first parameter names.

Generic rather than a table per tool, so a tool an extension registered -- or
one the agent wrote for itself -- prints as legibly as a built-in."
  (let ((arguments (msg:tool-call-arguments call)))
    (when (hash-table-p arguments)
      (or (loop for key in '("path" "pattern" "command" "note" "target" "source" "name")
                for value = (gethash key arguments)
                when (stringp value) return value)
          (loop for value being the hash-values of arguments
                when (stringp value) return value)))))

(defun call-summary (call)
  (format nil "~a~@[ ~a~]" (msg:tool-call-name call)
          (a:when-let ((argument (salient-argument call)))
            (one-line argument :width 60))))

(defun result-summary (result)
  (let ((text (one-line (tool:tool-result-output result) :width 72)))
    (if (tool:tool-result-error-p result)
        (paint (format nil "    ! ~a" text) :red)
        (paint (format nil "    ~a" text) :dim))))
