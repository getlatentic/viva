;;;; Compile everything from scratch and refuse an undefined variable.
;;;;
;;;; A docstring with an unescaped quote in it ended early, and what followed
;;;; parsed as a free variable reference and a stray string -- so a function
;;;; began by reading something unbound. The compiler said so on every build
;;;; for as long as it was there, and the warning scrolled past with the rest.
;;;;
;;;; Whether it then SIGNALS depends on the compiler: the unused read is elided
;;;; on one machine and raised on another, which is how this passed here and
;;;; failed on the first CI runner it met. A warning nobody reads is the same
;;;; as no warning, so this makes the build read it.
(require :sb-posix)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))

(defparameter *systems*
  '("viva" "viva/image" "viva/search" "viva/tasks"
    "viva/console" "viva/daemon" "viva/tui" "viva/cli"))

;; Quietly first, so the fetch and the dependency tree are not what is read.
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/cli :silent t))

(let ((found '()))
  (handler-bind ((warning
                   (lambda (condition)
                     (let ((text (princ-to-string condition)))
                       ;; UNDEFINED, not merely unused: a style warning about a
                       ;; variable nobody reads is housekeeping, and one about a
                       ;; variable nobody DEFINED is a bug that has not run yet.
                       (when (search "undefined variable" (string-downcase text))
                         (pushnew text found :test #'string=))))))
    (dolist (system *systems*)
      (asdf:load-system system :force t)))
  (cond (found
         (format *error-output* "~&~d undefined variable~:p:~%" (length found))
         (dolist (each found) (format *error-output* "  ~a~%" each))
         (sb-ext:exit :code 1))
        (t (format t "~&no undefined variables in ~d systems~%" (length *systems*))
           (sb-ext:exit :code 0))))
