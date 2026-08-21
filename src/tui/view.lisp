;;;; What the client knows, and how an event changes it.
;;;;
;;;; Separated from both the socket and the screen on purpose. A full-screen
;;;; client fails by drawing the wrong thing, not by crashing -- and a wrong
;;;; frame is invisible to a compiler, a type check and a smoke test alike. The
;;;; only way to catch it is to feed a known event stream in and assert on what
;;;; comes out, which requires that neither end touch I/O.
;;;;
;;;; So: ABSORB folds one event into a view and returns nothing but a changed
;;;; view. No socket, no terminal, no clock.

(in-package #:vivarium.tui)

(defparameter *scrollback* 2000
  "Output lines kept. A long-running session would otherwise grow without
limit, and the lines above the fold cannot be seen anyway.")

(defstruct (view (:conc-name view-))
  (sessions '())          ; (id . label), newest first
  (current nil)           ; the session whose output is shown
  (lines '())             ; finished output lines, oldest first
  (partial "")            ; the line being streamed, not yet ended
  (tasks '())             ; (id state . label)
  (input "")              ; what is being typed
  (status "")             ; the one-line message under the input
  (busy nil)              ; is a turn running
  (scroll 0)              ; lines back from the bottom, 0 = following
  (tabs '())              ; workspace names, in the order they are shown
  (tab 0)                 ; which one is active
  (tab-ranges '()))       ; (name start end) per tab, from the last paint

(defun field (data key)
  "Read KEY from an event's data, whether it arrived as a hash table from the
wire or an alist from a test. The client should not have to convert one into
the other just to be testable."
  (etypecase data
    (null nil)
    (hash-table (gethash key data))
    (list (cdr (assoc key data :test #'equal)))))

(defun add-line (view text)
  (let ((lines (append (view-lines view) (list text))))
    (setf (view-lines view)
          (if (> (length lines) *scrollback*)
              (nthcdr (- (length lines) *scrollback*) lines)
              lines))))

(defun absorb-text (view text)
  "Add streamed TEXT, ending lines where newlines arrive.

Streamed output arrives split at arbitrary byte boundaries -- a line can come
in five pieces and a piece can hold three lines. Holding the tail in PARTIAL is
what stops one logical line being drawn as several."
  (let ((buffer (concatenate 'string (view-partial view) (or text ""))))
    (loop for break = (position #\Newline buffer)
          while break
          do (add-line view (subseq buffer 0 break))
             (setf buffer (subseq buffer (1+ break))))
    (setf (view-partial view) buffer)))

(defun end-line (view)
  (when (plusp (length (view-partial view)))
    (add-line view (view-partial view))
    (setf (view-partial view) "")))

(defun note-task (view id state label)
  (let ((existing (assoc id (view-tasks view) :test #'equal)))
    (if existing
        (setf (cdr existing) (cons state label))
        (setf (view-tasks view)
              (append (view-tasks view) (list (list* id state label)))))))

(defun absorb (view name data)
  "Fold one daemon event into VIEW. Returns the view.

Unknown events are ignored rather than signalled: a client one version behind
its daemon should lose a feature, not fall over."
  (let ((text (field data "text")))
    (cond
      ((equal name "model.delta") (absorb-text view text))
      ((equal name "tool.started")
       (end-line view)
       (add-line view (format nil "  · ~a" (or (field data "call") text ""))))
      ((equal name "turn.started")
       (setf (view-busy view) t (view-status view) "working"))
      ((member name '("turn.completed" "turn.failed" "turn.cancelled") :test #'equal)
       (end-line view)
       (setf (view-busy view) nil
             (view-status view)
             (cond ((equal name "turn.failed") (or text "failed"))
                   ((equal name "turn.cancelled") "cancelled")
                   (t "ready"))))
      ((equal name "session.list")
       (setf (view-sessions view) (field data "sessions")))
      ((equal name "task.started") (note-task view (field data "id") :running (or text "")))
      ((equal name "task.completed") (note-task view (field data "id") :done (or text "")))
      ((equal name "task.failed") (note-task view (field data "id") :failed (or text "")))
      ((equal name "error") (setf (view-status view) (or text "error")))))
  view)

;;; Typing.

(defun type-key (view key)
  "Apply one keypress to the input line. Returns an action or NIL.

The actions are what the LOOP must do and the view cannot: :send, :quit,
:cancel, :next-session. Keeping them as returned values rather than callbacks
is what lets a test press a key and assert on the outcome."
  (let ((value (key-value key)))
    (cond
      ((and (key-control key) (eql value #\c))
       (if (view-busy view) :cancel :quit))
      ((and (key-control key) (eql value #\d))
       (if (plusp (length (view-input view))) nil :quit))
      ((eql value :tab) :next-session)
      ((eql value :page-up) (incf (view-scroll view) 10) nil)
      ((eql value :page-down)
       (setf (view-scroll view) (max 0 (- (view-scroll view) 10))) nil)
      ((member value '(:enter #\Return #\Newline))
       (and (plusp (length (string-trim " " (view-input view)))) :send))
      ((member value '(:backspace #\Rubout #\Backspace))
       (let ((input (view-input view)))
         (when (plusp (length input))
           (setf (view-input view) (subseq input 0 (1- (length input))))))
       nil)
      ((and (characterp value) (graphic-char-p value))
       (setf (view-input view) (format nil "~a~a" (view-input view) value))
       nil)
      (t nil))))

(defun take-input (view)
  "The typed line, cleared from the view."
  (prog1 (view-input view)
    (setf (view-input view) ""
          (view-scroll view) 0)))
