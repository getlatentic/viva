;;;; Save viva as one executable.
;;;;
;;;; Without this, "the binary" is the Rust client and nothing else: the daemon
;;;; is source that needs SBCL and Quicklisp on the machine that runs it, so an
;;;; artifact somebody downloads is a client with nothing to talk to.
;;;;
;;;; A saved image carries the whole system, which is what makes an artifact an
;;;; answer. It also removes the quickload from every start: the launcher spent
;;;; that on each invocation, which is why the Rust client is reached before
;;;; SBCL rather than from inside it.
(require :sb-posix)
(require :sb-introspect)

(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file setup)
    (format *error-output* "~&viva needs Quicklisp to build an image.~%")
    (sb-ext:exit :code 1 :abort t))
  (load setup))

(push (truename ".") (symbol-value (find-symbol "*LOCAL-PROJECT-DIRECTORIES*" "QL")))
(handler-bind ((warning #'muffle-warning))
  (funcall (find-symbol "QUICKLOAD" "QL") :viva/cli :silent t))

(defun entry ()
  ;; The same interrupt handling bin/entry.lisp installs: Ctrl-C ends the run
  ;; rather than printing two hundred frames of backtrace, which include the
  ;; Authorization header.
  (sb-sys:enable-interrupt
   sb-unix:sigint
   (lambda (&rest ignored)
     (declare (ignore ignored))
     (format *error-output* "~&interrupted~%")
     (finish-output *error-output*)
     (sb-ext:exit :code 130 :abort t)))
  (sb-ext:exit :code (funcall (find-symbol "MAIN" "VIVA.CLI")
                              (rest sb-ext:*posix-argv*))))

(sb-ext:save-lisp-and-die
 (or (second sb-ext:*posix-argv*) "viva")
 :executable t
 :toplevel #'entry
 ;; Compression would halve the file and cost a second of every start. A
 ;; daemon starts once and a client starts constantly.
 :save-runtime-options t)
