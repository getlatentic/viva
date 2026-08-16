(defun fail (why) (format t "FAIL: ~a~%" why) (sb-ext:exit :code 1))

(defvar *files* '("kernel.lisp" "ledger.lisp" "actor.lisp" "tools.lisp" "cli.lisp"))

;; Pass 1: the packages themselves. Only the leading defpackage of each file
;; is evaluated; bodies never run.
(handler-case
    (dolist (file *files*)
      (with-open-file (in file) (eval (read in))))
  (error (c) (fail (format nil "packages do not build: ~a" c))))

;; Pass 2: every form, read under the file's own package context, so
;; nicknamed references resolve to the symbols they mean.
(defvar *forms* '())
(handler-case
    (dolist (file *files*)
      (with-open-file (in file)
        (let ((*package* (find-package "COMMON-LISP-USER")))
          (loop for form = (read in nil in)
                until (eq form in)
                do (cond ((and (consp form) (eq (car form) 'in-package))
                          (setf *package* (find-package (string (second form)))))
                         ((and (consp form) (eq (car form) 'defpackage)))
                         (t (push (cons file form) *forms*)))))))
  (error (c) (fail (format nil "a source file does not read: ~a" c))))
(setf *forms* (nreverse *forms*))

(defun count-in (form sym)
  "Operator-position occurrences. QUOTE and FUNCTION subtrees are references,
not calls, and are not descended into."
  (cond ((not (consp form)) 0)
        ((member (car form) '(quote function)) 0)
        (t (+ (if (eq (car form) sym) 1 0)
              (count-in (car form) sym)
              (loop for rest on (cdr form)
                    sum (count-in (car rest) sym))))))

(defun total-calls (sym)
  (loop for (file . form) in *forms* sum (count-in form sym)))

(defun calls-in-file (sym file)
  (loop for (f . form) in *forms*
        when (string= f file) sum (count-in form sym)))

(defun defined-in (sym)
  (loop for (file . form) in *forms*
        when (and (consp form) (eq (car form) 'defun) (eq (second form) sym))
          return file))

(defun caller-lines (sym)
  (let ((files (sort (remove-duplicates
                      (loop for (file . form) in *forms*
                            when (plusp (count-in form sym)) collect file)
                      :test #'string=)
                     #'string<)))
    (format nil "~{~a~^~%~}"
            (mapcar (lambda (file) (format nil "~a ~d" file (calls-in-file sym file)))
                    files))))

(defvar *expected* (let ((kernel-sym (find-symbol "TRANSITION" "MINI.KERNEL"))
      (tools-sym (find-symbol "TRANSITION" "MINI.TOOLS")))
  (format nil "kernel ~d~%tools ~d"
          (total-calls kernel-sym) (total-calls tools-sym))))

(unless (probe-file "answer.txt") (fail "no answer.txt"))
(let ((got (with-open-file (in "answer.txt")
             (format nil "~{~a~^~%~}"
                     (loop for line = (read-line in nil)
                           while line
                           for trimmed = (string-trim " " line)
                           unless (string= trimmed "") collect trimmed)))))
  (if (string= got *expected*)
      (format t "ok~%")
      (progn
        (format t "FAIL: answer.txt does not match~%--- expected ---~%~a~%--- got ---~%~a~%"
                *expected* got)
        (sb-ext:exit :code 1))))
