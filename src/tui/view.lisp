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

(in-package #:viva.tui)

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
  (tab-ranges '())        ; (name start end) per tab, from the last paint
  ;; WHERE THE KEYBOARD GOES. Without this the sidebar could only be reached
  ;; by Tab, because arrow keys had nowhere to be interpreted: every key was
  ;; the prompt's, so a list on screen was a list you could not walk.
  (cwd "" :type string)          ; where a new session started from here works
  (focus :input :type keyword)   ; :input or :sessions
  (selection 0 :type fixnum))    ; which session the sidebar has highlighted

(defun field (data key)
  "Read KEY from an event's data, whether it arrived as a hash table from the
wire or an alist from a test. The client should not have to convert one into
the other just to be testable."
  (etypecase data
    (null nil)
    (hash-table (gethash key data))
    (list (cdr (assoc key data :test #'equal)))))

(defparameter *salient-keys*
  '("command" "path" "pattern" "note" "target" "source" "name" "text")
  "The argument worth showing, in the order worth trying.")

(defun one-line (text limit)
  "TEXT with newlines flattened, cut to LIMIT."
  (let* ((flat (substitute #\Space #\Newline (or text "")))
         (trimmed (string-trim " " flat)))
    (if (> (length trimmed) limit)
        (concatenate 'string (subseq trimmed 0 limit) "...")
        trimmed)))

(defun any-string-value (arguments)
  "Any string in ARGUMENTS, whichever shape it arrived in.

Both shapes, because the wire brings a hash table and a test writes an alist --
and a fallback that handles only one of them is a fallback that works in
production and not in the test, or the reverse. Either way it is not tested."
  (etypecase arguments
    (null nil)
    (hash-table (loop for found being the hash-values of arguments
                      when (stringp found) return found))
    (list (loop for (nil . found) in arguments
                when (stringp found) return found))))

(defun call-summary (call)
  "`bash npm test` rather than a printed hash table.

The event's `call` is a JSON object, and a client that formats it with ~a gets
`#<HASH-TABLE :TEST EQUAL :COUNT 3 {800910C643}>` in the middle of the
conversation -- which is not merely ugly: it is the client showing its own
internals to somebody who asked what the agent was doing. The line client has
rendered this properly since it existed; this is that, ported rather than
reinvented, because two renderings of one event drift.

Falls back to the tool NAME alone, never to the object. A name with no
argument is uninformative; a printed structure is worse than uninformative."
  (if (or (stringp call) (null call))
      ;; A daemon that sends the call already rendered, or nothing at all. Both
      ;; are things a client one version apart will see, and neither is a
      ;; reason to signal in the middle of drawing a frame.
      (or call "")
      (let ((name (field call "name"))
            (arguments (field call "arguments")))
        (format nil "~a~@[ ~a~]"
                (or name "tool")
                (a:when-let ((value (or (loop for key in *salient-keys*
                                              for found = (field arguments key)
                                              when (stringp found) return found)
                                        (any-string-value arguments))))
                  (one-line value 72))))))

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
      ;; What the person said, from the daemon rather than from a local echo.
      ;; Echoing locally shows it once and loses it on the next attach; this
      ;; way the transcript reads the same however you arrived at it.
      ((equal name "user.message")
       (end-line view)
       (add-line view "")
       (add-line view (format nil "> ~a" (or text ""))))
      ((equal name "tool.started")
       (end-line view)
       (add-line view (format nil "  · ~a"
                             (a:if-let ((call (field data "call")))
                               (call-summary call)
                               (or text "")))))
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

(defun move-selection (view step)
  "Move the sidebar highlight, staying inside the list."
  (let ((count (length (view-sessions view))))
    (when (plusp count)
      (setf (view-selection view)
            (mod (+ (view-selection view) step) count)))
    nil))

(defun selected-session (view)
  (nth (view-selection view) (view-sessions view)))

(defun type-key (view key)
  "Apply one keypress to the input line. Returns an action or NIL.

The actions are what the LOOP must do and the view cannot: :send, :quit,
:cancel, :next-session, :open-selected. Keeping them as returned values rather
than callbacks is what lets a test press a key and assert on the outcome.

FOCUS DECIDES WHAT A KEY MEANS. With the sidebar focused, Up and Down walk the
session list and Enter opens one; with the input focused they are the prompt's.
Escape always returns to the prompt, because a person who is lost should be
able to get back to typing without knowing where they were."
  (let ((value (key-value key)))
    (cond
      ((and (key-control key) (eql value #\c))
       (if (view-busy view) :cancel :quit))
      ((eql value :escape) (setf (view-focus view) :input) nil)
      ;; The sidebar's keys, live only while it has the keyboard.
      ((eq :sessions (view-focus view))
       (case value
         (:up (move-selection view -1))
         (:down (move-selection view 1))
         ((:enter #\Return #\Newline) :open-selected)
         (:tab :next-session)
         (t (setf (view-focus view) :input)
            ;; A printable key with the sidebar focused means the person has
            ;; started typing, so the prompt takes it rather than dropping it.
            (when (and (characterp value) (graphic-char-p value))
              (setf (view-input view) (format nil "~a~a" (view-input view) value)))
            nil)))
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
