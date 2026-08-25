;;;; Bootstrap for bin/viva. Outside the ASDF system on purpose: it is what
;;;; brings the system up, so it cannot be part of it.

(require :sb-posix)
(require :sb-introspect)

;; Quicklisp is the one prerequisite this script cannot supply for itself, and
;; not having it is the first thing a newcomer hits. LOAD on a missing file
;; raises through a disabled debugger, which prints thirty frames of SBCL
;; internals -- a stack trace where an instruction belongs. Check first and say
;; the sentence instead.
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file setup)
    (format *error-output* "~&viva needs Quicklisp, and ~a does not exist.

Install it once:

  curl -O https://beta.quicklisp.org/quicklisp.lisp
  sbcl --non-interactive --load quicklisp.lisp \\
       --eval '(quicklisp-quickstart:install)'

Then run this again. Nothing else needs installing by hand -- the first run
fetches the rest, and takes a few minutes.~%" (namestring setup))
    (finish-output *error-output*)
    (sb-ext:exit :code 1 :abort t))
  (load setup))

(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-directory-pathname *load-truename*))))
  (push root (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
  (sb-posix:setenv "VIVA_ROOT" (namestring root) 1))

(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/cli :silent t))

;; COLLECT WHAT LOADING LEFT BEHIND. Compiling and loading the systems is the
;; largest allocation this process ever makes, and most of it is garbage the
;; moment it finishes: fasl buffers, reader structures, the compiler's working
;; set. Left alone the pages stay resident for the life of a daemon that may
;; run for weeks. Measured on this machine: 84 MB of heap and 130 MB of
;; footprint before, 62 MB and 72 MB after, for about a third of a second.
(sb-ext:gc :full t)

;; Ctrl-C should stop a long run, not print two hundred frames of backtrace --
;; frames that include the Authorization header, so a crash leaks the API key
;; to the terminal.
(sb-sys:enable-interrupt
 sb-unix:sigint
 (lambda (&rest ignored)
   (declare (ignore ignored))
   (format *error-output* "~&interrupted~%")
   (finish-output *error-output*)
   (sb-ext:exit :code 130 :abort t)))

(sb-ext:exit :code (funcall (find-symbol "MAIN" "VIVA.CLI")
                            (rest sb-ext:*posix-argv*)))
