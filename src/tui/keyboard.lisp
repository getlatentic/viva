;;;; Does this terminal speak the kitty keyboard protocol?
;;;;
;;;; The protocol is a PROTOCOL, not a library: a terminal that supports it
;;;; reports keys unambiguously -- Ctrl-I distinguishable from Tab, key release
;;;; events, modifiers that survive -- and one that does not sends the same
;;;; overloaded bytes terminals have sent since VT100. Speaking it costs one
;;;; escape sequence and buys correctness; embedding a terminal EMULATOR to get
;;;; the same thing is building a terminal, which #17 ratified against.
;;;;
;;;; Detection is a question and an answer, and the answer may never come: a
;;;; terminal that does not know the query ignores it, so the read must be
;;;; bounded. A detector that hangs on an old terminal is worse than one that
;;;; assumes the old terminal.
;;;;
;;;;     CSI ? u          "what are your current flags?"
;;;;     CSI ? <flags> u  the reply, from a terminal that understands
;;;;     CSI > <flags> u  push our flags   CSI < u   pop them back

(in-package #:viva.tui)

(defparameter *query* (format nil "~c[?u" #\Escape))
(defparameter *push-flags* (format nil "~c[>1u" #\Escape)
  "Bit 1: disambiguate escape codes. The one flag worth having before any
others -- it is what makes Ctrl-I not Tab -- and asking for less is easier to
support than asking for everything.")
(defparameter *pop-flags* (format nil "~c[<u" #\Escape))

(defparameter *reply-timeout* 0.15
  "Seconds to wait for a reply. Generous for a local terminal, short enough that
a terminal which ignores the query costs a person a blink rather than a pause.")

(defun read-reply (input deadline)
  "Read a CSI reply, or NIL if none arrives before DEADLINE.

READ-CHAR-NO-HANG in a bounded loop rather than READ-CHAR: the whole hazard is
a terminal that will never answer, and a blocking read against one is the hang
this function exists to avoid."
  (let ((seen (make-string-output-stream)))
    (loop
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (let ((character (read-char-no-hang input nil nil)))
        (cond ((null character) (sleep 0.005))
              (t (write-char character seen)
                 ;; A CSI reply ends at its final byte; `u` is this one's.
                 (when (char= #\u character)
                   (return (get-output-stream-string seen)))))))))

(defun supported-p (&key (input *standard-input*) (output *standard-output*))
  "Does the terminal on these streams speak the kitty keyboard protocol?

NIL for anything that is not a terminal at all -- a pipe cannot answer, and
asking costs a stray escape sequence in somebody's log file."
  (when (and (interactive-stream-p input) (interactive-stream-p output))
    (ignore-errors
     (write-string *query* output)
     (finish-output output)
     (let ((reply (read-reply input (+ (get-internal-real-time)
                                       (round (* *reply-timeout*
                                                 internal-time-units-per-second))))))
       (and reply (search "[?" reply) t)))))

(defmacro with-kitty-keyboard ((&key (input '*standard-input*) (output '*standard-output*))
                               &body body)
  "Run BODY with the protocol enabled, and POP IT BACK whatever happens.

The pop is in an UNWIND-PROTECT because the flags are the terminal's state, not
ours: a crash that leaves them pushed leaves the person's shell reporting keys
in a format it does not understand, and the fix is to close the window."
  (let ((on (gensym "ON")) (out (gensym "OUT")))
    `(let* ((,out ,output)
            (,on (supported-p :input ,input :output ,out)))
       (unwind-protect
            (progn (when ,on (write-string *push-flags* ,out) (finish-output ,out))
                   ,@body)
         (when ,on
           (ignore-errors (write-string *pop-flags* ,out) (finish-output ,out)))))))
