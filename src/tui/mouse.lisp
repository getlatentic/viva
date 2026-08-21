;;;; Clicks, drags and the wheel.
;;;;
;;;; The same shape as the kitty keyboard protocol and for the same reason:
;;;; mouse reporting is a MODE we ask the host to turn on, and sequences we
;;;; decode. Nothing is emulated. A terminal that does not offer it simply
;;;; sends nothing and the keyboard path carries on.
;;;;
;;;; SGR (mode 1006) rather than the original encoding, which packs the
;;;; coordinates into single bytes and therefore cannot express a column past
;;;; 223. That is not an edge case on a wide screen; it is the right-hand third
;;;; of an ordinary one.
;;;;
;;;; This also works inside herdr, and not by accident: it asks its emulator
;;;; whether the program in a pane has enabled mouse tracking, and forwards
;;;; clicks instead of consuming them when it has. Speaking the protocol is
;;;; what makes a multiplexer hand the mouse over.

(in-package #:vivarium.tui)

(defparameter *enable-mouse*
  (format nil "~c[?1000h~c[?1002h~c[?1006h" #\Escape #\Escape #\Escape)
  "Button events, drag reporting, and SGR coordinates.

1003 -- report ALL motion -- is deliberately not here. It sends a sequence for
every cell the pointer crosses, which is a great deal of traffic to answer a
question nothing asks.")

(defparameter *disable-mouse*
  (format nil "~c[?1006l~c[?1002l~c[?1000l" #\Escape #\Escape #\Escape))

(defstruct (mouse (:conc-name mouse-))
  (action :press :type keyword)   ; :press :release :drag :wheel-up :wheel-down
  (button :left :type keyword)
  (row 0 :type fixnum)            ; zero-based, like everything else here
  (column 0 :type fixnum)
  (control nil) (alt nil) (shift nil))

(defun mouse-button-of (code)
  (case (logand code 3) (0 :left) (1 :middle) (2 :right) (t :none)))

(defun decode-mouse (body final)
  "One SGR mouse report. BODY is the digits between `<` and the final byte.

The final byte is the whole difference between a press and a release, which is
why it is passed in rather than recovered: `M` and `m` differ by one bit and
reading the wrong one turns every click into a click-and-never-release."
  (let ((fields '()) (start 0))
    (loop for index = (position #\; body :start start)
          do (push (parse-integer body :start start :end (or index (length body))
                                       :junk-allowed t)
                   fields)
             (unless index (return))
             (setf start (1+ index)))
    (let ((parsed (nreverse fields)))
      (when (and (= 3 (length parsed)) (every #'identity parsed))
        (destructuring-bind (code column row) parsed
          (make-mouse
           :action (cond ((logtest code 64) (if (zerop (logand code 1)) :wheel-up :wheel-down))
                         ((logtest code 32) :drag)
                         ((char= final #\m) :release)
                         (t :press))
           :button (if (logtest code 64) :none (mouse-button-of code))
           ;; ONE-BASED on the wire, zero-based everywhere in this package.
           ;; Converting at the boundary rather than at each use is what stops
           ;; half the callers being off by one.
           :row (max 0 (1- row))
           :column (max 0 (1- column))
           :shift (logtest code 4)
           :alt (logtest code 8)
           :control (logtest code 16)))))))

(defmacro with-mouse-reporting ((&optional (output '*standard-output*)) &body body)
  "Run BODY with the mouse reported, and TURN IT OFF whatever happens.

Left on, a terminal keeps sending click sequences to whatever runs next, which
appears as garbage typed into the person's shell by an invisible hand."
  (let ((out (gensym "OUT")))
    `(let ((,out ,output))
       (unwind-protect
            (progn (write-string *enable-mouse* ,out) (finish-output ,out)
                   ,@body)
         (write-string *disable-mouse* ,out)
         (finish-output ,out)))))
