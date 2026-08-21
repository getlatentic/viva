;;;; The full-screen client.
;;;;
;;;; One connection and one thread. A reader thread would be the obvious
;;;; shape and it is wrong here: `daemon:request` writes a request and then
;;;; reads until it finds the response, so a second reader on the same socket
;;;; steals replies from it. Polling both sources in one loop cannot race with
;;;; itself.
;;;;
;;;; This adds nothing to the protocol. Everything on screen comes from
;;;; `session.list`, `session.attach` and the event stream those already
;;;; produce -- which is the test of whether the daemon's interface was
;;;; actually general or merely enough for one client.

(in-package #:vivarium.cli)

(defparameter *idle-poll* 0.02
  "Seconds to wait when neither the socket nor the keyboard has anything.
Short enough that typing feels immediate, long enough that an idle client is
not a spinning core.")

(defun send-line (stream &rest plist)
  "Write one request and do not wait for its answer.

The loop reads every line that arrives anyway, so waiting here would only stop
it drawing until the daemon replied."
  (jzon:with-writer* (:stream stream) (jzon:write-value* (apply #'daemon::object plist)))
  (terpri stream)
  (force-output stream))

(defun session-entries (reply)
  "The session list as (id . label) pairs, as the view wants them."
  (loop for cell across (or (gethash "sessions" reply) #())
        ;; (id label state) -- the state was in the reply all along and the
        ;; first client threw it away, then drew a session list that could not
        ;; say which session wanted something.
        collect (list (gethash "id" cell)
                      (or (gethash "label" cell) (gethash "id" cell))
                      (gethash "state" cell))))

(defun absorb-reply (view reply)
  "Fold one line from the daemon into VIEW, whether event or response."
  (let ((event (gethash "event" reply)))
    (cond (event (tui:absorb view event (gethash "data" reply)))
          ((equal "response" (gethash "type" reply))
           (cond ((gethash "sessions" reply)
                  (setf (tui:view-sessions view) (session-entries reply)
                        ;; One tab per workspace, in the order they appear.
                        (tui:view-tabs view)
                        (remove-duplicates
                         (mapcar (lambda (entry) (tui:short-label (second entry)))
                                 (session-entries reply))
                         :test #'equal :from-end t)))
                 ((not (gethash "success" reply))
                  (setf (tui:view-status view)
                        (or (gethash "error" reply) "request failed"))))))))

(defparameter +clear-screen+ (format nil "~c[2J" #\Escape))

(defun fit-screen (screen stream)
  "A screen the size of the terminal, remade only when the size changed.

Remade rather than resized: the front buffer describes a terminal that no
longer exists.

AND THE REAL TERMINAL IS CLEARED when it is remade, which is the half that was
missing. A fresh screen's front buffer is blank, so the diff writes only the
cells that are not blank -- and every stale cell the terminal still holds from
the old layout is left exactly where it was, because our model says that space
is already empty. The result is the old frame and the new frame on screen at
once: borders crossing text, panes drawn twice, a display that looks corrupted
because the program is confidently drawing the difference between a screen it
imagines and one that does not exist.

Clearing costs four bytes and makes the model true again."
  (let ((size (tui:terminal-size)))
    (if (and screen
             (= (tui::screen-height screen) (car size))
             (= (tui::screen-width screen) (cdr size)))
        screen
        (progn (write-string +clear-screen+ stream)
               (force-output stream)
               (tui:make-blank-screen :width (cdr size) :height (car size))))))

(defun next-session-after (id sessions)
  "The session after ID, wrapping at the end. NIL if there is nowhere to go.

Wrapping rather than stopping, because Tab in a list of four should reach all
four and come back, not walk to the end and go quiet."
  (let ((ids (mapcar (lambda (entry) (if (consp entry) (car entry) entry)) sessions)))
    (cond ((null ids) nil)
          ((null (rest ids)) nil)
          (t (or (second (member id ids :test #'equal)) (first ids))))))

(defun switch-to (stream view id)
  "Point this client at another session, and forget the one it was showing."
  (when (and id (not (equal id (tui:view-current view))))
    ;; SINCE 0 so the conversation comes with it. A client that switches to a
    ;; session and shows an empty pane has not switched to anything a person
    ;; recognises.
    (send-line stream "type" "session.attach" "session" id "since" 0)
    (setf (tui:view-current view) id
          (tui:view-lines view) '()
          (tui:view-partial view) ""
          (tui:view-scroll view) 0))
  nil)

(defun act-on-click (stream view screen mouse)
  "Route one mouse report to whatever was under it."
  (let* ((regions (tui:regions-for screen))
         (hit (tui:region-at regions (tui:mouse-row mouse) (tui:mouse-column mouse)))
         (where (car hit)))
    (case (tui:mouse-action mouse)
      ;; The wheel scrolls whatever it is over, which is the one mouse
      ;; behaviour people do not think about before using.
      (:wheel-up (incf (tui:view-scroll view) 3) nil)
      (:wheel-down (setf (tui:view-scroll view) (max 0 (- (tui:view-scroll view) 3))) nil)
      (:press
       (case where
         (:tabs (a:when-let ((index (tui:tab-at view (tui:mouse-column mouse))))
                  (setf (tui:view-tab view) index)
                  ;; A tab is a workspace; selecting one shows its first session.
                  (a:when-let ((name (nth index (tui:view-tabs view))))
                    (a:when-let ((entry (find name (tui:view-sessions view)
                                              :key (lambda (e)
                                                     (tui:short-label (tui:session-label e)))
                                              :test #'equal)))
                      (switch-to stream view (tui:session-id entry)))))
                nil)
         (:sessions (a:when-let ((entry (tui:session-row-at
                                         view (cdr hit) (tui:mouse-row mouse))))
                      (switch-to stream view (tui:session-id entry)))
                    nil)
         (t nil)))
      (t nil))))

(defun live-act (action stream view)
  "Do what a keypress asked for. Returns :quit to leave, NIL to carry on.

The session is read from the VIEW rather than passed in. It used to be a
parameter, and the loop kept its own copy: switching set the view's current
session and left the loop's variable pointing at the old one, so the second Tab
computed the next session from a stale answer and landed on the same session
forever -- Tab appeared to work once and then stop. Two places holding one fact
is the bug; deleting one of them is the fix."
  (let ((id (tui:view-current view)))
    (case action
      (:quit :quit)
      (:cancel (send-line stream "type" "cancel" "session" id) nil)
      (:send (let ((text (tui:take-input view)))
               (tui:absorb view "model.delta"
                           (list (cons "text" (format nil "~%> ~a~%" text))))
               (send-line stream "type" "prompt" "session" id "text" text)
               nil))
      (:next-session
       ;; Switching is a request, not a local change: the daemon decides what
       ;; this client is subscribed to, and pretending otherwise shows one
       ;; session's name over another's output.
       (switch-to stream view (next-session-after id (tui:view-sessions view))))
      (t nil))))

(defun live-loop (stream view)
  "Poll the socket and the keyboard until asked to leave."
  (let ((screen nil) (dirty t))
    (loop
      (when (tui:take-resize) (setf screen nil dirty t))
      (setf screen (fit-screen screen *standard-output*))
      ;; Everything the daemon has said, before drawing: one frame for a burst
      ;; of twenty events rather than twenty frames.
      (loop while (listen stream)
            for line = (read-line stream nil nil)
            while line
            do (a:when-let ((reply (ignore-errors (jzon:parse line))))
                 (absorb-reply view reply)
                 (setf dirty t)))
      (when (listen *standard-input*)
        (a:when-let ((event (tui:read-key *standard-input*)))
          (setf dirty t)
          (if (tui:mouse-p event)
              (act-on-click stream view screen event)
              (when (eq :quit (live-act (tui:type-key view event) stream view))
                (return)))))
      (when dirty
        (tui:paint view screen)
        (tui:flush screen *standard-output*)
        (let ((place (tui:cursor-for view screen)))
          (write-string (tui::move-to (car place) (cdr place)) *standard-output*))
        (force-output *standard-output*)
        (setf dirty nil))
      (unless (or (listen stream) (listen *standard-input*))
        (sleep *idle-poll*)))))

(defparameter +enter-full-screen+
  (format nil "~c[?1049h~c[?25l~c[2J" #\Escape #\Escape #\Escape)
  "Switch to the alternate screen, hide the cursor, clear it.

The alternate screen is why a full-screen program can exit and leave the
scrollback it found. Without it this client would overwrite the history of the
terminal it was invited into.")

(defparameter +leave-full-screen+
  (format nil "~c[?25h~c[?1049l" #\Escape #\Escape))

(defmacro with-full-screen (&body body)
  "Run BODY on the alternate screen, and give the terminal back whatever happens."
  `(unwind-protect
        (progn (write-string +enter-full-screen+ *standard-output*)
               (force-output *standard-output*)
               ,@body)
     (write-string +leave-full-screen+ *standard-output*)
     (force-output *standard-output*)))

(defun command-live (parsed)
  "The full-screen client: sessions, the running turn and tasks at once."
  (unless (tui:terminal-p)
    (format t "~&vivarium live needs a terminal. Use `vivarium attach` when piping.~%")
    (return-from command-live 1))
  (unless (ensure-daemon)
    (format t "~&could not start a daemon~%")
    (return-from command-live 1))
  (let ((cwd (namestring (truename (or (flag parsed "cwd") ".")))))
    (daemon:with-connection (stream)
      (read-line stream nil "")            ; the greeting
      (let* ((wanted (or (first (args-positional parsed))
                         (unless (option-true-p parsed "new")
                           (live-session-here stream cwd))))
             (earlier '()))
        (multiple-value-bind (reply events)
            (if wanted
                ;; SINCE 0: the conversation so far, not just what happens next.
                ;; The line client attaches from NOW on purpose -- it prints
                ;; events as they arrive and a replay would scroll the terminal.
                ;; A full-screen client has the opposite need: opening a session
                ;; and seeing an empty pane is indistinguishable from opening
                ;; the wrong one.
                (daemon:request stream "type" "session.attach" "session" wanted
                                       "since" 0)
                (daemon:request stream "type" "session.start" "cwd" cwd
                                       "model" (option parsed "model")))
          (setf earlier events)
        (unless (gethash "success" reply)
          (format t "~&~a~%" (gethash "error" reply))
          (return-from command-live 1))
        (let ((id (gethash "id" (gethash "session" reply)))
              (view (tui:make-view)))
          (setf (tui:view-current view) id
                (tui:view-status view) "ready -- Tab switches, Ctrl-C stops a turn")
          ;; The replay arrived while REQUEST was waiting for its response.
          ;; Dropping it is how the first version showed an empty conversation
          ;; for a session with a hundred turns in it.
          (dolist (event earlier)
            (absorb-reply view event))
          (send-line stream "type" "session.list")
          (tui:with-resize-notice
            (tui:with-raw-terminal
              (tui:with-kitty-keyboard ()
                (tui:with-mouse-reporting ()
                  (with-full-screen
                    (live-loop stream view))))))
          (format t "~&detached; ~a is still running~%" id)
          0))))))
