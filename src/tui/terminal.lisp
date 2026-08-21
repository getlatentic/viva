;;;; Putting the terminal into raw mode, and putting it back.
;;;;
;;;; A terminal in its ordinary state is doing three things a full-screen
;;;; program does not want: buffering a line until Enter, echoing what is
;;;; typed, and turning Ctrl-C into a signal rather than a byte. Raw mode turns
;;;; those off, and a program that turns them off owes the person their shell
;;;; back afterwards -- including when it crashes.
;;;;
;;;; That is the whole risk here. A TUI that exits without restoring leaves a
;;;; shell with no echo and no line editing, which looks like the machine has
;;;; broken, and the fix a person reaches for is closing the window.

(in-package #:vivarium.tui)

(defun terminal-p (&optional (stream *standard-input*))
  (and (interactive-stream-p stream)
       (ignore-errors (sb-posix:tcgetattr 0) t)))

(defun raw-attributes ()
  "The terminal's current attributes, with canonical mode, echo and signal
generation switched off.

A SECOND TCGETATTR rather than a copy of the saved one. The saved object is
what gets restored, and modifying it in place would restore the modification --
a bug that hides until the first time somebody presses Ctrl-C in their shell
afterwards. SB-POSIX has no copier, so the way to get an independent object is
to ask the kernel twice."
  (let ((raw (sb-posix:tcgetattr 0)))
    (setf (sb-posix:termios-lflag raw)
          (logandc2 (sb-posix:termios-lflag raw)
                    (logior sb-posix:icanon sb-posix:echo sb-posix:isig)))
    ;; Read returns as soon as one byte is there, and never blocks forever:
    ;; VMIN 1 VTIME 0 is `give me a byte when there is one`, which is what the
    ;; key reader above already assumes.
    (setf (aref (sb-posix:termios-cc raw) sb-posix:vmin) 1
          (aref (sb-posix:termios-cc raw) sb-posix:vtime) 0)
    raw))

(defmacro with-raw-terminal (&body body)
  "Run BODY with the terminal raw, and RESTORE IT WHATEVER HAPPENS.

The restore is in an UNWIND-PROTECT and it is the point of the macro. A crash
that leaves the terminal raw leaves a person with no echo and no line editing
-- looking like the machine broke, when what broke was this program.

On anything that is not a terminal, BODY simply runs: a piped run is a real
way to use this and should not need a special case at the call site."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (and (terminal-p) (ignore-errors (sb-posix:tcgetattr 0)))))
       (unwind-protect
            (progn
              (when ,saved
                (ignore-errors
                 (sb-posix:tcsetattr 0 sb-posix:tcsanow (raw-attributes))))
              ,@body)
         (when ,saved
           (ignore-errors (sb-posix:tcsetattr 0 sb-posix:tcsanow ,saved)))))))
