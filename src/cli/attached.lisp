;;;; The verbs an attached session answers.
;;;;
;;;; `viva shell` had eighteen verbs and `viva attach` -- the organism,
;;;; the long-lived thing this project is about -- had one. Everything else
;;;; typed with a leading slash was forwarded to the model as a literal prompt:
;;;; a paid request, a confused model, and no error. The flagship had the worst
;;;; interface in the product.
;;;;
;;;; These verbs cannot be the shell's. A shell verb closes over a local agent
;;;; and calls it directly; an attached client holds a socket, and the agent is
;;;; on a worker thread in another process. So each verb here is a REQUEST, and
;;;; what it can ask for is exactly what the protocol offers.
;;;;
;;;; ONE inspection request rather than one per verb. `/tools`, `/skills`,
;;;; `/memory` and `/status` are four questions about one instant, and four
;;;; round trips would answer them from four.

(in-package #:viva.cli)

(defstruct (attached-verb (:conc-name attached-))
  (name "" :type string)
  (argument "" :type string)
  (blurb "" :type string)
  (handler nil))

(defun ask-session (stream id type &rest plist)
  (apply #'daemon:request stream "type" type "session" id plist))

(defparameter +salient-keys+
  '("command" "path" "pattern" "note" "target" "source" "name" "text")
  "The argument worth showing, in the order worth trying. The same idea the
shell has had since it existed -- CONSOLE::SALIENT-ARGUMENT -- reimplemented
against JSON because an attached client sees a wire event rather than a live
TOOL-CALL, and has no way to reach the object.")

(defun call-line (call)
  "`bash cd /x && npm test` rather than `bash`.

An attached session printed the tool NAME alone, so a run showed as twelve
identical lines saying `bash` -- which tells you the agent is busy and nothing
whatever about what it is doing. The shell has never had this problem."
  (let ((name (gethash "name" call))
        (arguments (gethash "arguments" call)))
    (format nil "~a~@[ ~a~]" name
            (when (hash-table-p arguments)
              (a:when-let ((value (or (loop for key in +salient-keys+
                                            for found = (gethash key arguments)
                                            when (stringp found) return found)
                                      (loop for found being the hash-values of arguments
                                            when (stringp found) return found))))
                (one-line value 72))))))

(defun describe-rejoin (reply)
  "Say where you have landed. Reads nothing from the socket.

The first version asked the daemon to REPLAY the session's recent events and
read until it saw the sequence the attach reply named -- and that sequence is
the next one to be assigned, not the last one used, so the read never finished
and rejoining a session hung forever.

Replay is a nicety; hanging is not. The client attaches from NOW, so nothing
is queued into the socket to poison the next prompt, and the history stays
where it has always been: `viva sessions`, and the transcript on disk."
  (let ((session (gethash "session" reply)))
    (format t "~&  ~a~@[, ~a~]~@[, ~d queued~]~%"
            (or (gethash "state" session) "idle")
            (gethash "turn" session)
            (let ((queued (gethash "queued" session)))
              (and queued (plusp queued) queued)))))

(defvar *interrupted-recently* nil
  "Set when a turn was just cancelled from the keyboard.

SBCL's READ-LINE returns NIL once after the signal that interrupted the
syscall, which is indistinguishable from Ctrl-D -- so cancelling a turn exited
the client, and `stay in the session` was the one thing that fix did not do.
This says `that NIL was the signal, not the end of input`, exactly once.")

(defun read-prompt ()
  "The next line typed, or NIL at genuine end of input."
  (format t "› ")
  (finish-output)
  (let ((line (read-line *standard-input* nil nil)))
    (cond (line line)
          (*interrupted-recently*
           (setf *interrupted-recently* nil)
           (read-prompt))
          (t nil))))

(defvar *in-turn* nil
  "True only while draining a turn, so SIGINT knows whether there is work to
stop or a prompt to leave. Without it the handler threw whenever the turn had
already finished, and `attempt to THROW to a tag that does not exist` is what
Ctrl-C printed.")

(defun stream-turn (stream)
  "Print a turn's events until it ends. Returns T if it was interrupted.

Every request that STARTS A TURN must call this. Firing one and not draining
its events leaves them in the socket for whatever reads next -- so the next
prompt would print the previous turn's output and stop at the previous turn's
completion, one behind forever. /retain did exactly that before this existed,
and its answer went nowhere while quietly desynchronising the stream."
  ;; The catch lives here, with the *IN-TURN* it guards, so every caller that
  ;; drains a turn is interruptible without each one remembering to be.
  (catch 'interrupted
    (let ((*in-turn* t))
      (loop for reply = (ignore-errors (jzon:parse (read-line stream nil "")))
            while reply
            for name = (gethash "event" reply)
            do (cond ((equal name "model.delta")
                      (write-string (gethash "text" (gethash "data" reply)))
                      (force-output))
                     ((equal name "tool.started")
                      (format t "~&  · ~a~%" (call-line (gethash "call" (gethash "data" reply)))))
                     ((member name '("turn.completed" "turn.failed" "turn.cancelled")
                              :test #'equal)
                      (terpri)
                      (return))))
      nil)))

(defun show-inspection (reply key label &key detail)
  (let ((items (gethash key reply)))
    (format t "~&~a~@[  (~d)~]~%" label (and (plusp (length items)) (length items)))
    (if (zerop (length items))
        (format t "~&  none~%")
        (loop for item across items
              do (format t "  ~a ~a~24t~a~%"
                         (if (equal "machine" (gethash "scope" item)) "~" " ")
                         (gethash "name" item)
                         (if detail (one-line (gethash "detail" item) 48) ""))))))

(defun inspect-session (stream id &rest sections)
  (let ((reply (ask-session stream id "session.inspect")))
    (if (not (gethash "success" reply))
        (format t "~&~a~%" (gethash "error" reply))
        (dolist (section sections)
          (ecase section
            (:where (format t "~&~a~%  ~a, ~a~%"
                            (gethash "cwd" reply) (gethash "model" reply)
                            (gethash "state" reply)))
            (:notes (show-inspection reply "notes" "notes"))
            (:skills (show-inspection reply "skills" "skills" :detail t))
            (:tools
             (show-inspection reply "tools" "tools" :detail t)
             (let ((refused (gethash "refused" reply)))
               (when (plusp (length refused))
                 (format t "~&refused  (~d)~%" (length refused))
                 (loop for item across refused
                       do (format t "  ~a~24tpresent, but will not run~%" (gethash "name" item)))
                 (unless (eq t (gethash "trusted" reply))
                   (format t "  trust this project to enable them: ~
viva trust ~a~%" (gethash "cwd" reply)))))))))))

(defparameter +attached-verbs+
  (list
   (make-attached-verb
    :name "help" :blurb "this list"
    :handler (lambda (stream id argument)
               (declare (ignore stream id argument))
               (dolist (verb +attached-verbs+)
                 (format t "~&  /~a~@[ ~a~]~22t~a~%" (attached-name verb)
                         (when (plusp (length (attached-argument verb)))
                           (attached-argument verb))
                         (attached-blurb verb)))
               (format t "  anything else~22tgoes to the model as a prompt~%")))
   (make-attached-verb
    :name "status" :blurb "where this session is working, and on what"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (inspect-session stream id :where)))
   (make-attached-verb
    :name "memory" :blurb "what it has written down"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (inspect-session stream id :notes)))
   (make-attached-verb
    :name "skills" :blurb "skills loaded for this directory"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (inspect-session stream id :skills)))
   (make-attached-verb
    :name "tools" :blurb "tools it can call, and any it cannot"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (inspect-session stream id :tools)))
   (make-attached-verb
    :name "learned" :blurb "everything retained here: notes, skills, tools"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (inspect-session stream id :where :notes :skills :tools)))
   (make-attached-verb
    :name "retain" :blurb "decide now what this session's work should keep"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (let ((reply (ask-session stream id "session.retain")))
                 (if (not (gethash "success" reply))
                     (format t "  ~a~%" (gethash "error" reply))
                     (progn
                       ;; The whole value of this verb is seeing what it chose
                       ;; -- including "nothing", which is the policy's most
                       ;; common correct answer and looks identical to a broken
                       ;; feature when it is not shown.
                       (format t "~&  deciding what to keep…~%")
                       (stream-turn stream))))))
   (make-attached-verb
    :name "sessions" :blurb "every session here: live and recorded"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (show-sessions stream id)))
   (make-attached-verb
    :name "switch" :argument "ID|N" :blurb "move this client to another session"
    :handler (lambda (stream id argument)
               (a:if-let ((chosen (listed-choice argument)))
                 (if (eq :live (first chosen))
                     (switch-session stream id (second chosen))
                     (format t "~&  ~a is a saved conversation, not a live session.~%~
  /continue ~a carries it into a new one.~%" (second chosen) argument))
                 (if (zerop (length argument))
                     (format t "~&  usage: /switch <id or number>   (/sessions lists them)~%")
                     (switch-session stream id argument)))))
   (make-attached-verb
    :name "new" :argument "[DIR]" :blurb "start another session and go to it"
    :handler (lambda (stream id argument)
               (declare (ignore id))
               (let* ((where (if (plusp (length argument))
                                 (namestring (truename argument))
                                 (uiop:native-namestring (uiop:getcwd))))
                      (reply (daemon:request stream "type" "session.start"
                                             "cwd" where "model" (option-model))))
                 (if (gethash "success" reply)
                     (setf *attached-to* (gethash "id" (gethash "session" reply)))
                     (format t "  ~a~%" (gethash "error" reply))))))
   (make-attached-verb
    :name "tasks" :blurb "the task tree under this session"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (let ((reply (daemon:request stream "type" "task.list")))
                 (let ((tasks (or (gethash "tasks" reply) #())))
                   (if (zerop (length tasks))
                       (format t "~&  none~%")
                       (loop for each across tasks
                             do (format t "~&  ~a~14t~a~%"
                                        (gethash "id" each) (gethash "state" each))))))))
   (make-attached-verb
    :name "cancel" :blurb "stop the turn now running"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (ask-session stream id "cancel")
               (format t "~&  cancelled~%")))
   (make-attached-verb
    :name "suspend" :blurb "pause this session where it is"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               (ask-session stream id "suspend")
               (format t "~&  suspended~%")))
   (make-attached-verb
    :name "unpause" :blurb "carry on a turn that was suspended"
    :handler (lambda (stream id argument)
               (declare (ignore argument))
               ;; NOT `continue an earlier conversation`, which is what the
               ;; name reads as next to the CLI's --resume. This un-suspends a
               ;; paused turn, and said `resumed` whether or not anything was
               ;; paused -- so it reported success at something you had not
               ;; asked for, and the conversation you wanted stayed empty.
               (ask-session stream id "resume")
               (format t "~&  asked ~a to carry on a suspended turn.~%" id)))
   (make-attached-verb
    :name "continue" :argument "[ID|N]" :blurb "carry a saved conversation into a new session"
    :handler (lambda (stream id argument)
               (declare (ignore id))
               ;; A NEW session that starts holding the old conversation, rather
               ;; than reanimating the old cell -- the recorded session is a
               ;; file, and the thing that reads it is an agent being built.
               ;; HARNESS:RESUME has always been able to do this; nothing in
               ;; the daemon path called it.
               (let ((reply (daemon:request stream "type" "session.start"
                                            "cwd" (uiop:native-namestring (uiop:getcwd))
                                            "model" (option-model)
                                            "resume" (a:if-let ((chosen (listed-choice argument)))
                                                       (second chosen)
                                                       (if (plusp (length argument))
                                                           argument
                                                           "true")))))
                 (if (gethash "success" reply)
                     (let ((session (gethash "session" reply)))
                       (setf *attached-to* (gethash "id" session))
                       (format t "~&  ~a now carries~:[ the most recent~; that~] ~
earlier conversation.~%  Ask it what you said before.~%"
                               (gethash "id" session) (plusp (length argument))))
                     (format t "~&  ~a~%" (gethash "error" reply))))))))

(defun edit-distance (a b)
  "How many single-character edits separate A and B."
  (let ((previous (loop for j to (length b) collect j)))
    (loop for i from 1 to (length a)
          for current = (list i)
          do (loop for j from 1 to (length b)
                   do (push (min (1+ (nth j previous))
                                 (1+ (first current))
                                 (+ (nth (1- j) previous)
                                    (if (char-equal (char a (1- i)) (char b (1- j))) 0 1)))
                            current))
             (setf previous (nreverse current)))
    (car (last previous))))

(defvar *attached-to* nil
  "The session this client should be on after the current verb.

A verb cannot rebind the loop's variable, and returning a value would make
every handler's contract about switching. One place that says `go here next`
is smaller than twelve handlers that each might.")

(defvar *option-model* nil
  "The model this client resolved, for sessions it starts later.")

(defun option-model () *option-model*)

(defvar *listed* '()
  "The last list SHOW-SESSIONS printed, so a number means something.

Numbered because nobody should have to type a timestamp to continue their own
conversation. The id still works -- a position is a convenience, never the only
handle, since a list printed ten minutes ago is not a promise.")

(defun listed-choice (argument)
  "ARGUMENT as a position into the last listing, or NIL if it is an id."
  (a:when-let ((n (and (every #'digit-char-p argument)
                       (plusp (length argument))
                       (parse-integer argument :junk-allowed t))))
    (nth (1- n) *listed*)))

(defun show-sessions (stream current)
  "Live sessions and recorded ones, in one numbered list.

Two lists in two places was the actual problem: /sessions showed the live cells
and the on-entry line counted recorded transcripts, they were different sets
shown differently, and neither could be chosen from -- while both /switch and
/continue wanted an id you had never been shown beside the thing it named."
  (let* ((live (coerce (or (gethash "sessions"
                                    (daemon:request stream "type" "session.list"))
                           #())
                       'list))
         ;; Only conversations. A live session's own transcript is in this
         ;; list too, holding nothing yet, and showing it as a separate
         ;; `saved` row makes one session look like two unrelated things.
         (here (remove-if (lambda (summary) (zerop (session:summary-messages summary)))
                          (or (ignore-errors
                               (session:list-sessions
                                :cwd (uiop:native-namestring (uiop:getcwd)) :limit 10))
                              '())))
         (rows '()))
    (format t "~&")
    (loop for each in live
          for n from 1
          do (push (list :live (gethash "id" each)) rows)
             (format t "  ~2d ~a live ~8t~a~16t~a~26t~a~%"
                     n (if (equal current (gethash "id" each)) "*" " ")
                     (gethash "id" each) (gethash "state" each)
                     (one-line (or (gethash "label" each) "") 40)))
    (loop for summary in (or here '())
          for n from (1+ (length live))
          do (push (list :recorded (session:summary-id summary)) rows)
             (format t "  ~2d   saved~8t~a~16t~3d msg~26t~a~%"
                     n (session:summary-id summary)
                     (session:summary-messages summary)
                     (one-line (or (session:summary-opening summary) "") 40)))
    (setf *listed* (nreverse rows))
    (if (null *listed*)
        (format t "  no sessions here yet~%")
        (format t "~%  /switch N moves to a live one; /continue N carries a saved one in.~%"))))

(defun switch-session (stream from to)
  "Move this client from one session to another.

DETACH FIRST. Subscriptions add rather than replace, so attaching without
detaching leaves the client receiving both sessions' events interleaved --
which is exactly what a switch would have produced."
  (let ((reply (daemon:request stream "type" "session.attach" "session" to "since" 0)))
    (cond ((not (gethash "success" reply))
           (format t "  ~a~%" (gethash "error" reply)))
          (t
           (when (and from (not (equal from to)))
             (daemon:request stream "type" "session.detach" "session" from))
           (setf *attached-to* to)
           (let ((session (gethash "session" reply)))
             (format t "~&  now in ~a~@[  ~a~]~@[  (~a)~]~%"
                     (gethash "id" session) (gethash "label" session)
                     (gethash "state" session)))))))

(defun nearest-verb (name)
  "The verb NAME was probably meant to be, or nothing.

Edit distance rather than a prefix test, because the typo a suggestion exists
for is usually a dropped or doubled letter -- `/tols` shares no useful prefix
with `/tools` and is obviously it. Two edits is the limit: past that the guess
is worse than no guess.

A suggestion, never a correction. Running what somebody nearly typed is how a
/suspend becomes a /shutdown."
  (let ((ranked (sort (mapcar (lambda (verb)
                                (cons (edit-distance name (attached-name verb)) verb))
                              +attached-verbs+)
                      #'< :key #'car)))
    (when (and ranked (<= (car (first ranked)) 2))
      (cdr (first ranked)))))

(defun run-attached-verb (stream id line)
  "Handle a /command. Returns T when LINE was one -- including when it was a
verb that does not exist, which is refused rather than sent to the model.

A slash line reaching the model is not a harmless fallthrough: it is a paid
request whose answer is a language model's guess at what your typo meant."
  (let* ((body (subseq line 1))
         (space (position #\Space body))
         (name (if space (subseq body 0 space) body))
         (argument (if space (string-trim " " (subseq body space)) ""))
         (verb (find name +attached-verbs+ :key #'attached-name :test #'string-equal)))
    (cond (verb
           ;; A dead socket is a fact about this connection, not a crash. The
           ;; caller turns it into a sentence; raising a Lisp condition here
           ;; printed an FD-STREAM object at somebody trying to type /tasks.
           (handler-case (progn (funcall (attached-handler verb) stream id argument) t)
             (stream-error () :connection-lost)
             (sb-int:broken-pipe () :connection-lost)))
          (t (format t "  no such command: /~a~@[  (did you mean /~a?)~]~%~
  /help lists them. To send that text to the model, drop the slash.~%"
                     name (a:when-let ((near (nearest-verb name))) (attached-name near)))
             t))))
