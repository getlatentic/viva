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
        collect (cons (gethash "id" cell)
                      (format nil "~a~@[  ~a~]"
                              (subseq (gethash "id" cell) 0
                                      (min 8 (length (gethash "id" cell))))
                              (gethash "label" cell)))))

(defun absorb-reply (view reply)
  "Fold one line from the daemon into VIEW, whether event or response."
  (let ((event (gethash "event" reply)))
    (cond (event (tui:absorb view event (gethash "data" reply)))
          ((equal "response" (gethash "type" reply))
           (cond ((gethash "sessions" reply)
                  (setf (tui:view-sessions view) (session-entries reply)))
                 ((not (gethash "success" reply))
                  (setf (tui:view-status view)
                        (or (gethash "error" reply) "request failed"))))))))

(defun fit-screen (screen)
  "A screen the size of the terminal, remade only when the size changed.

Remade rather than resized: the front buffer describes a terminal that no
longer exists, and keeping it would diff this frame against a layout the
terminal has already discarded -- which draws nothing and looks like a hang."
  (let ((size (tui:terminal-size)))
    (if (and screen
             (= (tui::screen-height screen) (car size))
             (= (tui::screen-width screen) (cdr size)))
        screen
        (tui:make-blank-screen :width (cdr size) :height (car size)))))

(defun next-session-after (id sessions)
  "The session after ID, wrapping at the end. NIL if there is nowhere to go.

Wrapping rather than stopping, because Tab in a list of four should reach all
four and come back, not walk to the end and go quiet."
  (let ((ids (mapcar (lambda (entry) (if (consp entry) (car entry) entry)) sessions)))
    (cond ((null ids) nil)
          ((null (rest ids)) nil)
          (t (or (second (member id ids :test #'equal)) (first ids))))))

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
       (let ((next (next-session-after id (tui:view-sessions view))))
         (when (and next (not (equal next id)))
           (send-line stream "type" "session.attach" "session" next "since" 0)
           (setf (tui:view-current view) next
                 (tui:view-lines view) '()
                 (tui:view-partial view) ""))
         nil))
      (t nil))))

(defun live-loop (stream view)
  "Poll the socket and the keyboard until asked to leave."
  (let ((screen nil) (dirty t))
    (loop
      (when (tui:take-resize) (setf screen nil dirty t))
      (setf screen (fit-screen screen))
      ;; Everything the daemon has said, before drawing: one frame for a burst
      ;; of twenty events rather than twenty frames.
      (loop while (listen stream)
            for line = (read-line stream nil nil)
            while line
            do (a:when-let ((reply (ignore-errors (jzon:parse line))))
                 (absorb-reply view reply)
                 (setf dirty t)))
      (when (listen *standard-input*)
        (a:when-let ((key (tui:read-key *standard-input*)))
          (let ((action (tui:type-key view key)))
            (setf dirty t)
            (when (eq :quit (live-act action stream view))
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
             (reply (if wanted
                        (daemon:request stream "type" "session.attach" "session" wanted
                                        "since" (current-sequence stream wanted))
                        (daemon:request stream "type" "session.start" "cwd" cwd
                                        "model" (option parsed "model")))))
        (unless (gethash "success" reply)
          (format t "~&~a~%" (gethash "error" reply))
          (return-from command-live 1))
        (let ((id (gethash "id" (gethash "session" reply)))
              (view (tui:make-view)))
          (setf (tui:view-current view) id
                (tui:view-status view) "ready -- Tab switches, Ctrl-C stops a turn")
          (send-line stream "type" "session.list")
          (tui:with-resize-notice
            (tui:with-raw-terminal
              (tui:with-kitty-keyboard ()
                (with-full-screen
                  (live-loop stream view)))))
          (format t "~&detached; ~a is still running~%" id)
          0)))))
