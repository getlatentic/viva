;;;; How big the terminal is, and noticing when it changes.
;;;;
;;;; SB-UNIX:UNIX-IOCTL rather than a hand-written DEFINE-ALIEN-ROUTINE for
;;;; `ioctl`. C declares ioctl variadic, and on arm64 Darwin variadic arguments
;;;; are passed on the stack while fixed ones are passed in registers -- so a
;;;; fixed-arity alien declaration puts the pointer somewhere the callee never
;;;; looks. It does not fail loudly: it returns -1 and leaves the struct
;;;; holding whatever was on the stack, which reads as a plausible terminal
;;;; size. The same C program on the same pty returns the right answer, which
;;;; is how this was found.
;;;;
;;;; tools/pty-size-check.sh re-runs that comparison against a pty of a known
;;;; size, because "we read the real size" should be checkable rather than
;;;; believed.

(in-package #:vivarium.tui)

(defconstant +tiocgwinsz+
  #+darwin #x40087468
  #+linux #x5413
  #-(or darwin linux) nil
  "TIOCGWINSZ, which is _IOR('t', 104, struct winsize) and therefore encodes
the struct's size in the constant -- so it differs per platform rather than
being a number one can carry across.")

(sb-alien:define-alien-type nil
  (sb-alien:struct winsize
    (rows sb-alien:unsigned-short)
    (columns sb-alien:unsigned-short)
    (xpixels sb-alien:unsigned-short)
    (ypixels sb-alien:unsigned-short)))

(defparameter *fallback-size* '(24 . 80)
  "What to report when nobody can say: a pipe, a cron job, a platform without
the constant. Eighty by twenty-four is the size everything else assumes too.")

(defun size-from-environment ()
  "LINES and COLUMNS, when a shell exported them and the kernel cannot say."
  (flet ((number-in (name)
           (let ((value (ignore-errors (sb-posix:getenv name))))
             (and value (ignore-errors (parse-integer value :junk-allowed t))))))
    (let ((rows (number-in "LINES")) (columns (number-in "COLUMNS")))
      (when (and rows columns (plusp rows) (plusp columns))
        (cons rows columns)))))

(defun terminal-size (&optional (fd 0))
  "The terminal's size as (ROWS . COLUMNS).

The return code is checked before the struct is read. It has to be: on a
failed call the memory holds whatever was there before, and a garbage size is
worse than a wrong one -- it is a wrong one that looks measured."
  (or (and +tiocgwinsz+
           (sb-alien:with-alien ((ws (sb-alien:struct winsize)))
             (setf (sb-alien:slot ws 'rows) 0
                   (sb-alien:slot ws 'columns) 0)
             (let ((ok (ignore-errors
                        (sb-unix:unix-ioctl fd +tiocgwinsz+
                                            (sb-alien:alien-sap (sb-alien:addr ws))))))
               (let ((rows (sb-alien:slot ws 'rows))
                     (columns (sb-alien:slot ws 'columns)))
                 (when (and ok (plusp rows) (plusp columns))
                   (cons rows columns))))))
      (size-from-environment)
      *fallback-size*))

(defvar *resized* nil
  "Set by the SIGWINCH handler, cleared by whoever acts on it.

A flag rather than work in the handler. A signal arrives on whichever thread
the kernel picks, at whatever point it happens to be at, and repainting from
there means drawing from two threads at once.")

(defun note-resize ()
  (setf *resized* t))

(defmacro with-resize-notice (&body body)
  "Run BODY with SIGWINCH setting *RESIZED*, and the old handler restored after.

Restoring matters for the same reason raw mode does: this program is a guest
in somebody's process group."
  (let ((previous (gensym "PREVIOUS")))
    `(let ((,previous (ignore-errors
                       (sb-sys:enable-interrupt sb-unix:sigwinch
                                                (lambda (&rest ignored)
                                                  (declare (ignore ignored))
                                                  (note-resize))))))
       (unwind-protect (progn ,@body)
         (when ,previous
           (ignore-errors (sb-sys:enable-interrupt sb-unix:sigwinch ,previous)))))))

(defun take-resize ()
  "T once after each SIGWINCH, NIL otherwise."
  (when *resized* (setf *resized* nil) t))
