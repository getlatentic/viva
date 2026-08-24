;;;; Do any local nicknames point at a package defined later in the same file?
;;;;
;;;; Standalone, and that is the entire point. A nickname resolves when its
;;;; DEFPACKAGE is read, so pointing further down the same file fails at load --
;;;; which means anything that guards it must not itself require the load.
;;;;
;;;; Two homes were tried and both are dead: the test suite never runs, because
;;;; a broken package file stops the suite loading; and `vivarium check` dies in
;;;; the loader too, because bin/viva quickloads the system before any
;;;; command runs. This file loads nothing. It reads text.
;;;;
;;;;     sbcl --script tools/check-package-order.lisp
;;;;
;;;; A target defined in ANOTHER file is fine: the system definition loads those
;;;; first, and if it did not that file would fail on its own. Same-file
;;;; lateness is the whole rule.

(defun trimmed (line) (string-left-trim '(#\Space #\Tab) line))

(defun defpackage-name (line)
  (let ((body (subseq (trimmed line) 14)))
    (string-upcase (string-right-trim ")" body))))

(defun nickname-target (line)
  "The vivarium package a `(#:nick #:vivarium.x)` line points at, or NIL."
  (let* ((text (trimmed line))
         (at (search "#:vivarium." text)))
    (when (and at (>= (length text) 3) (string= "(#:" (subseq text 0 3)))
      (let ((rest (subseq text (+ at 2))))
        (string-upcase
         (string-right-trim ")" (subseq rest 0 (or (position #\Space rest)
                                                   (position #\) rest)
                                                   (length rest)))))))))

(defun problems-in (path)
  (let ((lines (with-open-file (in path)
                 (loop for line = (read-line in nil nil) while line collect line)))
        (defined (make-hash-table :test #'equal))
        (problems '())
        (current nil))
    (loop for line in lines
          for position from 1
          when (and (>= (length (trimmed line)) 14)
                    (string= "(defpackage #:" (subseq (trimmed line) 0 14)))
            do (setf (gethash (defpackage-name line) defined) position))
    (loop for line in lines
          for position from 1
          do (cond
               ((and (>= (length (trimmed line)) 14)
                     (string= "(defpackage #:" (subseq (trimmed line) 0 14)))
                (setf current (defpackage-name line)))
               ((and current (nickname-target line))
                (let* ((target (nickname-target line))
                       (where (gethash target defined)))
                  (when (and where (> where position))
                    (push (format nil "~a:~d  ~a nicknames ~a, which is defined below at line ~d"
                                  (file-namestring path) position
                                  (string-downcase current) (string-downcase target) where)
                          problems))))))
    (nreverse problems)))

(let* ((root (merge-pathnames "../" (directory-namestring *load-truename*)))
       (files (sort (directory (merge-pathnames "src/*/package.lisp" root))
                    #'string< :key #'namestring))
       (found (loop for file in files append (problems-in file))))
  (cond (found
         (format *error-output* "~&a local nickname points at a package defined below it:~%~%")
         (dolist (problem found) (format *error-output* "  ~a~%" problem))
         (format *error-output* "~%A nickname resolves when its DEFPACKAGE is read. Move the~%~
target's DEFPACKAGE above the one that names it.~%")
         (sb-ext:exit :code 1))
        (t (format t "~&~d package file~:p, no nickname points below itself~%" (length files))
           (sb-ext:exit :code 0))))
