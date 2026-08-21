;;;; Bytes from a terminal, turned into a key.
;;;;
;;;; Two dialects, one answer. A terminal speaking the kitty protocol sends
;;;;
;;;;     CSI <code> ; <modifiers> [: <event>] u
;;;;
;;;; where the code is a unicode codepoint and the modifiers are a bitmask
;;;; plus one. A terminal that is not sends what terminals have sent since the
;;;; VT100: a bare byte, a C0 control for Ctrl, an escape sequence for arrows,
;;;; and no way at all to tell Ctrl-I from Tab -- they are the same byte, 9.
;;;;
;;;; That ambiguity is why the protocol is worth speaking, and why this returns
;;;; the same KEY structure either way: everything above should be written once
;;;; against a key, not twice against two dialects.

(in-package #:vivarium.tui)

(defstruct (key (:conc-name key-))
  ;; A character, or a keyword for the ones that are not: :up :down :left
  ;; :right :home :end :enter :tab :backspace :escape :delete
  (value nil)
  (control nil)
  (alt nil)
  (shift nil))

(defparameter +kitty-modifiers+
  '((1 . :shift) (2 . :alt) (4 . :control))
  "The bits, as the protocol defines them. The wire carries the mask PLUS ONE,
so that a terminal sending no modifiers still sends a 1 and the field is never
empty -- which is why every decoder that forgets the subtraction reports shift
on every unmodified key.")

(defparameter +legacy-finals+
  '((#\A . :up) (#\B . :down) (#\C . :right) (#\D . :left)
    (#\H . :home) (#\F . :end))
  "CSI sequences a terminal sends when it has nothing better.")

(defun modifiers-from (encoded)
  "The kitty modifier field to (values CONTROL ALT SHIFT)."
  (let ((bits (max 0 (1- (or encoded 1)))))
    (values (logtest bits 4) (logtest bits 2) (logtest bits 1))))

(defun decode-kitty (body)
  "BODY is what sat between CSI and the final `u`. Returns a KEY, or NIL.

The event type after a colon is READ AND IGNORED for now: press, repeat and
release are three things and this is one. Dropping the field silently would
make a release look like a press, which is worse than not supporting release."
  (let* ((colon (position #\: body))
         (without-event (if colon (subseq body 0 colon) body))
         (parts (uiop:split-string without-event :separator ";"))
         (code (parse-integer (or (first parts) "") :junk-allowed t))
         (modifiers (parse-integer (or (second parts) "1") :junk-allowed t)))
    (when code
      (multiple-value-bind (control alt shift) (modifiers-from modifiers)
        (make-key :value (case code
                           (13 :enter) (9 :tab) (127 :backspace) (27 :escape)
                           (t (code-char code)))
                  :control control :alt alt :shift shift)))))

(defun decode (bytes)
  "One key from BYTES, or NIL if they are not a key this understands.

Deliberately total on the inputs it claims and NIL on everything else: a
decoder that guesses at a sequence it does not know turns an unrecognised key
into a wrong one, and a wrong key is acted on."
  (let ((length (length bytes)))
    (cond
      ((zerop length) nil)
      ;; CSI ... u  -- the kitty dialect
      ((and (> length 3) (char= #\Escape (char bytes 0)) (char= #\[ (char bytes 1))
            (char= #\u (char bytes (1- length))))
       (decode-kitty (subseq bytes 2 (1- length))))
      ;; CSI <final> -- the legacy arrows and friends
      ((and (= length 3) (char= #\Escape (char bytes 0)) (char= #\[ (char bytes 1)))
       (a:when-let ((named (cdr (assoc (char bytes 2) +legacy-finals+))))
         (make-key :value named)))
      ;; A bare byte, in the dialect that cannot tell Ctrl-I from Tab.
      ((= length 1)
       (let ((code (char-code (char bytes 0))))
         (cond ((= code 13) (make-key :value :enter))
               ((= code 9) (make-key :value :tab))
               ((= code 127) (make-key :value :backspace))
               ((= code 27) (make-key :value :escape))
               ;; C0: Ctrl-A is 1. The information that it was Ctrl is
               ;; recoverable here; which letter it was is not, beyond this.
               ((< 0 code 27) (make-key :value (code-char (+ 96 code)) :control t))
               (t (make-key :value (char bytes 0))))))
      (t nil))))

(defun describe-key (key)
  "A key as a person writes it: C-x, M-x, or the character itself."
  (when key
    (format nil "~@[~a~]~@[~a~]~a"
            (and (key-control key) "C-") (and (key-alt key) "M-")
            (let ((value (key-value key)))
              (if (characterp value) (string value) (string-downcase (symbol-name value)))))))

;;; Reading one key
;;;
;;; A key is one byte or several, and nothing in the bytes says which until you
;;; have them. ESC alone is the Escape key; ESC [ A is Up; ESC [ 105;5 u is
;;; Ctrl-I. So the reader takes ESC, then looks -- and the looking must be
;;; bounded, because a person pressing Escape and nothing else must not wait
;;; for a sequence that will never arrive.

(defparameter *sequence-timeout* 0.05
  "Seconds to wait for the rest of an escape sequence.

Escape alone is a key people press, and a terminal sends the rest of a real
sequence in one write -- so anything that has not arrived by now is not coming.
Too long and Escape feels broken; too short and a slow link splits a real
sequence into a false Escape plus rubbish.")

(defun read-key (stream &key (timeout *sequence-timeout*))
  "One key from STREAM, or NIL at end of input.

Blocks for the FIRST byte -- there is nothing to do until a person types -- and
only then bounds the wait, because by then the question is `is there more of
this sequence`, which has an answer that arrives immediately or not at all."
  (let ((first (read-char stream nil nil)))
    (when first
      (if (char/= #\Escape first)
          (decode (string first))
          (let ((deadline (+ (get-internal-real-time)
                             (round (* timeout internal-time-units-per-second))))
                (collected (make-string-output-stream)))
            (write-char first collected)
            (loop
              (let ((next (read-char-no-hang stream nil nil)))
                (cond
                  ((null next)
                   (when (> (get-internal-real-time) deadline)
                     ;; Nothing more came: Escape on its own.
                     (return (decode (get-output-stream-string collected))))
                   (sleep 0.002))
                  (t
                   (write-char next collected)
                   ;; A CSI sequence ends at its final byte -- an alphabetic
                   ;; character or `~`. Stopping there rather than on the
                   ;; timeout is what makes a fast keypress feel instant.
                   (when (and (alpha-char-p next) (char/= #\[ next))
                     (return (decode (get-output-stream-string collected))))
                   (when (char= #\~ next)
                     (return (decode (get-output-stream-string collected)))))))))))))
