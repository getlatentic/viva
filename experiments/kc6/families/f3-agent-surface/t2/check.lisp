(defun fail (why) (format t "FAIL: ~a~%" why) (sb-ext:exit :code 1))

(handler-case (progn (load "harness.lisp"))
  (error (c) (fail (format nil "the harness does not load: ~a" c))))

;; Ground truth is DERIVED, at grade time, by the real constructor -- the
;; family's whole lesson applied to its own grader.
(defvar *names*
  (handler-case (sort (copy-list (tool-names (make-reviewer-agent))) #'string<)
    (error (c) (fail (format nil "the constructor itself failed: ~a" c)))))

(unless (probe-file "answer.txt") (fail "no answer.txt"))
(let ((lines (with-open-file (in "answer.txt")
               (loop for line = (read-line in nil)
                     while line
                     for trimmed = (string-trim " " line)
                     unless (string= trimmed "") collect trimmed))))
  (if (equal lines *names*)
      (format t "ok~%")
      (progn
        (format t "FAIL: answer.txt does not match~%--- expected ---~%~{~a~%~}--- got ---~%~{~a~%~}"
                *names* lines)
        (sb-ext:exit :code 1))))
