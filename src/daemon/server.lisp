;;;; The socket: one protocol, several transports, none of them owning the
;;;; organism's lifetime.
;;;;
;;;; A local-domain socket rather than stdin and stdout. The distinction is the
;;;; architecture: a daemon whose protocol lives on stdio is a daemon whose life
;;;; ends when its parent's terminal does, and `vivarium ipc` becomes a bridge
;;;; into this rather than the thing itself.
;;;;
;;;; JSON lines both ways, as the IPC mode already uses -- requests carry an id
;;;; and get a response, events arrive unbidden. No length prefixes and no
;;;; handshake: a line is atomic enough for this traffic and `nc -U` is a
;;;; debugger.

(in-package #:vivarium.daemon)

(define-condition daemon-error (error)
  ((detail :initarg :detail :reader daemon-error-detail))
  (:report (lambda (condition stream)
             (write-string (daemon-error-detail condition) stream))))

(defstruct (daemon-instance (:conc-name instance-))
  "One generation of the daemon: everything it owns, under one identity.

The daemon used to be three globals -- socket, socket file, lock fd -- and
every lifecycle bug it has had was some thread acting on whichever values
happened to inhabit them at the time: an accept loop retiring its successor, a
failed startup poised to close a fd its successor had installed. Cleanup now
names the generation it is cleaning up, and acts only while that generation is
current."
  (socket nil)
  (path "" :type string)
  (fd nil))

(defvar *current* nil "The running generation, or NIL. Owned by *LOCK*.")
(defvar *lock* (bt:make-lock "vivarium.daemon"))
(defvar *state* :stopped "One of :STOPPED :STARTING :RUNNING, owned by *LOCK*.

    OS lock     protects this process from another process
    this state  protects this process from its own threads

A POSIX record lock is held by the process, so it says nothing at all about two
threads here both deciding to serve.")
(defvar *starting* nil "A token for the startup in flight, so STOP can cancel
it and a failed startup can clean up itself and only itself.")

(defun claim-startup ()
  "Move :STOPPED to :STARTING and return a token, or NIL. One transition."
  (bt:with-lock-held (*lock*)
    (when (eq :stopped *state*)
      (setf *state* :starting)
      (setf *starting* (gensym "STARTUP")))))

(defun release-startup (token)
  "Unwind a startup that did not finish -- but only THIS startup. A failed
generation A running its cleanup after generation B claimed must change
nothing: everything A held was still thread-local, so there is nothing of A's
to release beyond the claim itself."
  (bt:with-lock-held (*lock*)
    (when (eq token *starting*)
      (setf *starting* nil *state* :stopped))))

(defun socket-path ()
  (or (sb-posix:getenv "VIVARIUM_SOCKET")
      (namestring (merge-pathnames ".vivarium/vivariumd.sock" (user-homedir-pathname)))))

(defun object (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          unless (eq value :omit) do (setf (gethash key table) value))
    table))

;;; Contained failures, kept where they can be seen
;;;
;;; Swallowing an error at the client boundary is right: a broken client must
;;; not take the organism down. But containment that leaves no trace is how the
;;; next race hides -- a daemon that survived four hundred failed client threads
;;; and cannot say so looks exactly like one that had no trouble at all.

(defparameter +diagnostics-kept+ 100)
(defvar *diagnostics* '() "Recent contained failures, newest first.")
(defvar *diagnostics-lock* (bt:make-lock "vivarium.diagnostics"))
(defvar *failures* 0 "How many there have been, which the kept ones do not say.")

(defvar *started-at* (get-universal-time)
  "When this image began serving, for the staleness check.")

(defvar *hangups* 0
  "Clients that went away mid-write. Counted, never reported as failures.")

(defparameter +hangup-errnos+
  (list sb-posix:epipe sb-posix:econnreset)
  "A peer that closed first. Distinguishing these from a genuine write failure
is what stops ordinary use from looking like trouble: a person hosting vivarium
in a multiplexer closes panes, and every close hangs up a client mid-greeting.")

(defun hangup-p (condition)
  "Did the peer close first, or did the write genuinely fail?

SB-BSD-SOCKETS does not export its errno reader, and the alternative -- matching
the printed message -- is a string comparison against another library's report
format. The internal reader is used behind FBOUNDP so that an SBCL which renames
it degrades to calling everything a failure: noisier than it should be, which is
the safe direction. Silently classifying a real failure as a hangup is not."
  (and (typep condition 'sockets:socket-error)
       (fboundp 'sockets::socket-error-errno)
       (member (funcall 'sockets::socket-error-errno condition) +hangup-errnos+)))

(defun note-hangup ()
  (bt:with-lock-held (*diagnostics-lock*) (incf *hangups*))
  nil)

(defun note-failure (where condition)
  (bt:with-lock-held (*diagnostics-lock*)
    (incf *failures*)
    (push (object "where" where
                  "condition" (string (type-of condition))
                  "detail" (princ-to-string condition)
                  "time" (get-universal-time))
          *diagnostics*)
    (when (> (length *diagnostics*) +diagnostics-kept+)
      (setf *diagnostics* (subseq *diagnostics* 0 +diagnostics-kept+))))
  nil)

(defun diagnostics ()
  (bt:with-lock-held (*diagnostics-lock*)
    (values (copy-list *diagnostics*) *failures* *hangups*)))

;;; One connection

(defstruct (client (:conc-name client-))
  (socket nil)
  (stream nil)
  (key nil)
  ;; Everything bound for the socket, and the one thread allowed to write it.
  ;; A session's own worker used to write here, so a terminal that stopped
  ;; reading stopped the turn publishing to it.
  (outbound (mailbox:make-mailbox))
  (writer nil)
  ;; Signalled by the writer when it has stopped touching the descriptor.
  ;; The close waits for this, not for a join with a timeout: a timed join
  ;; that gives up lets the close land mid-send (EBADF on a recycled number),
  ;; and an untimed one once waited an hour and fifty minutes on a writer
  ;; nothing was going to finish.
  (finished (bt:make-semaphore :count 0))
  (watching '() :type list))

(defparameter +outbound-limit+ 20000
  "Messages a client may fall behind by before it is disconnected.

Enqueueing cannot block, which is what keeps the organism out of a slow
terminal's way -- and is exactly why the queue must be bounded instead. A UI
reading one event a second while an agent produces a hundred is otherwise an
unbounded allocation with a polite name. Dropping the client is the right
answer because the journal makes it recoverable: it reconnects and asks for
everything after the last sequence it saw.")

(defvar *clients* '() "Connections currently served, for the sweeper.")
(defvar *clients-lock* (bt:make-lock "vivarium.clients"))

(defun register-client (client)
  (bt:with-lock-held (*clients-lock*) (push client *clients*)))

(defun forget-client (client)
  (bt:with-lock-held (*clients-lock*) (setf *clients* (remove client *clients*))))

(defun wake (client)
  "Break this connection out of whatever it is blocked in, without freeing the
descriptor.

SHUTDOWN, never CLOSE. A blocked SOCKET-SEND is not interruptible by a deadline
-- measured: SB-SYS:WITH-DEADLINE does not reach it, and the send simply
continues -- but shutting the socket down returns it with an error, and so does
a blocked READ-LINE. Closing here instead would free a descriptor that the
reader still owns and is about to close itself, and a double close on a number
the kernel has since reused is the worst bug in this file's history."
  (ignore-errors (sockets:socket-shutdown (client-socket client) :direction :io)))

(defun say (client table)
  "Queue one object for this client. Never blocks, never fails, never waits."
  (mailbox:send-message (client-outbound client) table)
  t)

(defun send-all (socket octets)
  "Send every byte, or return NIL. Nothing is buffered anywhere."
  (let ((total (length octets)) (sent 0))
    (loop while (< sent total)
          do (let ((n (sockets:socket-send socket (subseq octets sent) nil)))
               (unless (and n (plusp n)) (return-from send-all nil))
               (incf sent n)))
    t))

(defun write-one (client item)
  "One object, one line, straight to the descriptor.

Not through an output stream. An fd-stream keeps what it could not write, and a
peer that hangs up before its greeting can be sent makes exactly that happen --
those bytes then reached a LATER connection, which read the front of somebody
else's greeting before its own. Measured: 12 corrupted greetings in 3600
connections when clients hung up immediately, and none when the same clients
read their greeting first."
  (handler-case
      (send-all (client-socket client)
                (sb-ext:string-to-octets
                 (concatenate 'string
                              (jzon:stringify (if (event:event-p item)
                                                  (event:as-json item)
                                                  item))
                              (string #\Newline))
                 :external-format :utf-8))
    (error (condition)
      (if (hangup-p condition)
          (note-hangup)
          (note-failure "write" condition)))))

(defun start-writer (client)
  "The outbound side has one owner: this thread. The descriptor has another.

The writer must NOT close the socket: SOCKET-MAKE-STREAM caches a stream on the
socket object and SOCKET-CLOSE closes that stream -- so a writer closing `its`
socket was closing the stream the reader was blocked reading, a cross-thread
closure wearing single-ownership's clothes. The writer only writes; when it is
finished -- :DONE, or a send that failed -- it signals FINISHED and exits. The
reader closes, once, after that signal. A blocked send cannot stall the signal,
because WAKE's shutdown forces the send to return first."
  (setf (client-writer client)
        (bt:make-thread
         (lambda ()
           (unwind-protect
                (loop for item = (mailbox:receive-message (client-outbound client))
                      until (eq item :done)
                      do (unless (write-one client item)
                           (wake client)
                           (return)))
             (bt:signal-semaphore (client-finished client) :count 1000)))
         :name "vivarium-client-writer")))

(defun stop-writer (client)
  "Returns T once the writer has confirmed it will never touch the socket
again, NIL if that confirmation never came."
  ;; Woken first: a writer blocked in SOCKET-SEND never reaches the mailbox to
  ;; see :DONE, and shutdown makes the send return.
  (wake client)
  (mailbox:send-message (client-outbound client) :done)
  (and (bt:wait-on-semaphore (client-finished client) :timeout 30) t))

(defun sweep-clients ()
  "Disconnect anyone too far behind to be worth waiting for."
  (dolist (client (bt:with-lock-held (*clients-lock*) (copy-list *clients*)))
    (let ((behind (mailbox:mailbox-count (client-outbound client))))
      (when (> behind +outbound-limit+)
        (note-failure "backpressure"
                      (make-condition 'simple-error
                                      :format-control "client fell ~d messages behind"
                                      :format-arguments (list behind)))
        (wake client)))))

(defun next-line (client)
  "The next line, or NIL when this connection is over for any reason at all.

A broken socket is how a connection ends, not a condition to signal. READ-LINE
raises on a bad descriptor rather than returning its EOF value, and this runs
under `sbcl --script`, where an unhandled condition in any thread quits the
whole process -- one hung-up client used to take the organism with it."
  (handler-case (read-line (client-stream client) nil nil)
    (error (condition) (note-failure "read" condition))))

(defun watch (client cell &key (from 0))
  "Send CELL's events to CLIENT, starting with whatever it missed.

Replaying and then subscribing loses anything published in between. FROM is a
barrier established with the subscription in one critical section, so no event
falls in the gap and none arrives twice."
  (cond ((member (actor:cell-id cell) (client-watching client) :test #'string=)
         (dolist (event (actor:since cell from)) (say client event)))
        (t
         (push (actor:cell-id cell) (client-watching client))
         ;; The mailbox itself is the subscriber. Nothing of ours runs inside
         ;; the session's lock, so nothing of ours can hold it.
         (actor:subscribe-since cell (client-key client) from
                                (client-outbound client)))))

(defun unwatch (client cell)
  "Stop sending CELL's events to CLIENT."
  (actor:unsubscribe cell (client-key client))
  (setf (client-watching client)
        (remove (actor:cell-id cell) (client-watching client) :test #'string=)))

(defun unwatch-all (client)
  (dolist (id (client-watching client))
    (a:when-let ((cell (actor:find-cell id)))
      (actor:unsubscribe cell (client-key client))))
  (setf (client-watching client) '()))

;;; Requests

(defun cell-json (cell)
  "One coherent instant of a cell, not six field reads racing the coordinator."
  (let ((now (actor:snapshot cell)))
    (object "id" (getf now :id)
            "label" (getf now :label)
            "state" (string-downcase (symbol-name (getf now :state)))
            "seq" (getf now :sequence)
            "turn" (getf now :turn)
            ;; A prompt waiting behind a running turn is otherwise invisible,
            ;; and `idle with two queued` is a different thing to explain.
            "queued" (getf now :queued)
            ;; From the snapshot, which is plain values. This read the live
            ;; agent out of a getf the snapshot no longer supplies -- so every
            ;; RPC that rendered a session signalled, including the GREETING
            ;; whenever any session existed at connect time. The suite stayed
            ;; green because almost every daemon test connects with zero
            ;; sessions: the primary public path was untested and broken.
            "cwd" (getf now :cwd)
            "model" (getf now :model))))

(defun text-of (command key &optional default)
  (let ((value (gethash key command)))
    (if (stringp value) value default)))

(defun start-session (command)
  (let* ((cwd (or (text-of command "cwd") (uiop:native-namestring (uiop:getcwd))))
         (choice (models:resolve-model (text-of command "model")))
         ;; BEFORE OPEN-SESSION. Opening writes this session's own file, so
         ;; `the most recent session here` resolved to the empty one being
         ;; created -- and resuming from it succeeded at loading nothing. The
         ;; verb reported success, the conversation stayed blank, and the only
         ;; way to see it was to ask the model what you had said.
         (earlier (a:when-let ((wanted (text-of command "resume")))
                    (if (string= "true" wanted)
                        (session:latest-session cwd)
                        (session:find-session wanted :cwd cwd))))
         (session (session:open-session :directory (session:session-directory cwd) :cwd cwd))
         (agent (harness:make-workspace-agent
                 :cwd cwd
                 :provider (models:choice-provider choice)
                 :model (models:choice-model choice)
                 :reasoning-effort (models:choice-effort choice)
                 :session session
                 :request-limit 60)))
    (setf (agent:agent-stream-p agent) t
          (vivarium.compaction:settings-context-limit (harness:agent-compaction agent))
          (models:choice-context-limit choice))
    ;; Carry an earlier conversation in, when asked. Until this existed the
    ;; organism could list the sessions it had recorded and could not continue
    ;; one -- so `what did I say before?` was answered by an empty context, and
    ;; the on-entry message advertising --resume was pointing at a flag this
    ;; command never read.
    (a:when-let ((wanted (text-of command "resume")))
      ;; Say what happened either way. A resume that silently finds nothing is
      ;; indistinguishable from one that worked, which is how this shipped
      ;; twice looking fine.
      (if (null earlier)
          (note-failure "resume"
                        (make-condition 'simple-error
                                        :format-control "asked for ~s in ~a, found no session there"
                                        :format-arguments (list wanted cwd)))
          (handler-case
              (progn (harness:resume agent (session:summary-path earlier))
                     (note-failure "resume"
                                   (make-condition 'simple-error
                                                   :format-control "loaded ~a (~d message~:p)"
                                                   :format-arguments (list (session:summary-id earlier)
                                                                           (session:summary-messages earlier)))))
            (error (condition) (note-failure "resume" condition)))))
    (actor:spawn :label (or (text-of command "label") cwd) :agent agent)))

(defun handle (client command)
  (let* ((id (gethash "id" command))
         (type (text-of command "type" ""))
         (cell (a:when-let ((session (text-of command "session")))
                 (actor:find-cell session))))
    (flet ((ok (&rest plist) (say client (apply #'object "id" (or id :omit)
                                                "type" "response" "command" type
                                                "success" t plist)))
           (no (detail) (say client (object "id" (or id :omit) "type" "response"
                                            "command" type "success" nil "error" detail))))
      (cond
        ((string= "ping" type) (ok "pong" t))

        ((string= "session.start" type)
         (let ((cell (start-session command)))
           (watch client cell)
           (ok "session" (cell-json cell))))

        ((string= "session.list" type)
         (ok "sessions" (coerce (mapcar #'cell-json (actor:all-cells)) 'vector)))

        ((string= "session.attach" type)
         (if cell
             (progn (watch client cell :from (or (gethash "since" command) 0))
                    (ok "session" (cell-json cell)))
             (no "No such session.")))

        ;; Stop sending one session's events to this client. WATCH adds a
        ;; subscription rather than replacing one, so a client that attached to
        ;; a second session would receive both streams interleaved -- which is
        ;; what switching sessions would have done. Additive rather than
        ;; changing what attach means, so a client that never switches is
        ;; unaffected.
        ((string= "session.detach" type)
         (if (null cell)
             (no "No such session.")
             (progn (unwatch client cell) (ok))))

        ((string= "session.stop" type)
         (if cell (progn (actor:shutdown cell) (ok)) (no "No such session.")))

        ;; The whole point of the actor model: this returns at once, and the
        ;; work continues whether or not the caller stays connected. The turn
        ;; id comes back so a caller can name what it started -- to wait for
        ;; that turn, or to cancel that turn and not its successor.
        ((string= "prompt" type)
         (cond ((null cell) (no "No such session."))
               ((null (text-of command "text")) (no "prompt needs text."))
               (t (ok "accepted" t "turn" (actor:submit cell (text-of command "text"))))))

        ((string= "steer" type)
         (if cell (progn (actor:tell cell :steer :text (text-of command "text")
                                                 :turn (text-of command "turn"))
                         (ok))
             (no "No such session.")))

        ((string= "cancel" type)
         (if cell (progn (actor:tell cell :cancel :turn (text-of command "turn")) (ok))
             (no "No such session.")))

        ((string= "suspend" type)
         (if cell (progn (actor:tell cell :suspend :turn (text-of command "turn")) (ok))
             (no "No such session.")))

        ((string= "resume" type)
         (if cell (progn (actor:tell cell :resume :turn (text-of command "turn")) (ok))
             (no "No such session.")))

        ((string= "events" type)
         (if cell
             (ok "events" (coerce (mapcar #'event:as-json
                                          (actor:since cell (or (gethash "since" command) 0)))
                                  'vector))
             (no "No such session.")))

        ;; The task tree. Spawn returns the identity the task WILL have, so a
        ;; caller can await or cancel exactly what it asked for; events flow
        ;; through the owning session's stream, which WATCH already covers.
        ((string= "task.spawn" type)
         (cond ((null cell) (no "No such session."))
               ((null (text-of command "text")) (no "task.spawn needs text."))
               (t (a:if-let ((id (actor:spawn-task
                                  cell (text-of command "text")
                                  :parent (gethash "parent" command)
                                  :scoped (not (eq (gethash "detached" command) t)))))
                    (ok "task" id)
                    (no "spawn refused")))))

        ((string= "task.list" type)
         (ok "tasks" (coerce (mapcar (lambda (task)
                                       (object "id" (getf task :id)
                                               "state" (string-downcase (symbol-name (getf task :state)))
                                               "parent" (getf task :parent)
                                               "scoped" (and (getf task :scoped) t)))
                                     (actor:task-tree-snapshot))
                             'vector)))

        ((string= "task.cancel" type)
         (a:if-let ((id (gethash "task" command)))
           (progn (actor:cancel-task id) (ok))
           (no "task.cancel needs a task.")))

        ;; What this session has accumulated: notes, skills, tools. Answered
        ;; FROM DISK by the germline reader, never by reading the cell's live
        ;; agent -- that agent belongs to a worker thread, and reading its
        ;; slots from this one is the ownership violation ACTOR:SNAPSHOT
        ;; exists to prevent. Reading files also means the question can be
        ;; answered while a turn is running, instead of queueing behind work
        ;; that may take minutes.
        ((string= "session.inspect" type)
         (if (null cell)
             (no "No such session.")
             (let* ((now (actor:snapshot cell))
                    (view (germline:inspect-directory (getf now :cwd))))
               (flet ((items (list)
                        (coerce (mapcar (lambda (item)
                                          (object "name" (germline:item-name item)
                                                  "detail" (germline:item-detail item)
                                                  "scope" (string-downcase
                                                           (symbol-name (germline:item-scope item)))))
                                        list)
                                'vector)))
                 (ok "cwd" (getf now :cwd)
                     "model" (getf now :model)
                     "state" (string-downcase (symbol-name (getf now :state)))
                     "trusted" (and (germline:view-trusted-p view) t)
                     "notes" (items (germline:view-notes view))
                     "skills" (items (germline:view-skills view))
                     "tools" (items (germline:view-tools view))
                     "refused" (items (germline:view-refused view)))))))

        ;; The retention policy, in the organism. HARNESS:REFLECT had no caller
        ;; outside `do --retain` and an experiment driver, so the long-lived
        ;; process -- the thing the manifesto is about -- could not decide what
        ;; its work had taught it.
        ;;
        ;; Posted to the cell, never run here: reflection is a TURN, it uses
        ;; the same agent the worker owns, and running it on a client thread
        ;; would be two threads in one agent's conversation. Refusing while
        ;; busy is the honest answer rather than queueing, because the point is
        ;; to reflect on work that has finished.
        ((string= "session.retain" type)
         (cond ((null cell) (no "No such session."))
               ((actor:busy-p cell)
                (no "This session is working. Retention reflects on finished work; try again when it is idle."))
               (t (ok "turn" (actor:submit-retention cell)))))

        ((string= "diagnostics" type)
         (multiple-value-bind (kept total hangups) (diagnostics)
           (ok "failures" total "hangups" hangups "recent" (coerce kept 'vector))))

        ;; Jobs first: they are children of THIS process, and a process that
        ;; exits without stopping them orphans them -- still running, holding
        ;; ports, with the only record of them in the process that just died.
        ((string= "shutdown" type)
         (a:when-let ((stopped (ignore-errors (jobs:stop-all))))
           (when (plusp stopped)
             (note-failure "shutdown"
                           (make-condition 'simple-error
                                           :format-control "stopped ~d background job~:p"
                                           :format-arguments (list stopped)))))
         (ok)
         (stop))

        (t (no (format nil "Unknown command ~a." type)))))))

(defun serve-client (stream socket)
  "The reader thread, which owns this connection's lifecycle.

There is no shared liveness boolean. The writer wakes the connection when it
can no longer write, READ-LINE returns, and cleanup happens here -- in one
place, on one thread, with exactly one close."
  (let ((client (make-client :stream stream :socket socket :key (gensym "CLIENT"))))
    (register-client client)
    (unwind-protect
         (progn
           (start-writer client)
           (say client (object "type" "ready" "pid" (sb-posix:getpid)
                               ;; When this generation started. A long-lived
                               ;; process keeps the code it was built from, so
                               ;; a person who edits vivarium and reattaches is
                               ;; talking to the old one -- which looks exactly
                               ;; like the change not working. The client
                               ;; compares this against the source on disk.
                               "started" *started-at*
                               "sessions" (coerce (mapcar #'cell-json (actor:all-cells)) 'vector)))
           (loop for line = (next-line client)
                 while line
                 do (unless (zerop (length (string-trim '(#\Space #\Tab #\Return) line)))
                      (handler-case (handle client (jzon:parse line))
                        (error (condition)
                          (say client (object "type" "response" "success" nil
                                              "error" (princ-to-string condition))))))))
      ;; Unsubscribe before stopping the writer: a session publishing into a
      ;; mailbox nobody drains would queue for a client that has gone.
      (unwatch-all client)
      (forget-client client)
      (if (stop-writer client)
          ;; Confirmed: the writer will never touch this descriptor again, so
          ;; this is the one close, and it also closes the cached stream.
          (ignore-errors (sockets:socket-close socket :abort t))
          ;; Never confirmed. Closing now would race whatever the writer is
          ;; still doing, which is how EBADF lands on a recycled descriptor --
          ;; so the descriptor is deliberately leaked, and loudly: a leaked fd
          ;; is a bounded cost, a corrupted stranger's connection is not.
          (note-failure "close"
                        (make-condition 'simple-error
                                        :format-control "writer never confirmed; descriptor leaked"
                                        :format-arguments '()))))))

(defun serve-connection (connection)
  "Hand one accepted connection to its own thread.

CONNECTION is taken as an argument on purpose. LOOP's iteration variable is a
single binding updated in place, so a closure made inside the accept loop reads
whatever the *next* accept stored there -- two threads then built streams from
one socket, SBCL handed them the same stream, and they wrote interleaved JSON
onto one descriptor while the first to finish closed it under the other. That
is both of the daemon's observed failures: a client that could not parse the
greeting, and a `Bad file descriptor` that quit the entire organism."
  (bt:make-thread
   (lambda ()
     ;; Nothing a client does may reach the top level: --script disables the
     ;; debugger, and an unhandled condition in any thread ends the process.
     (handler-case
         (serve-client (sockets:socket-make-stream connection
                                                   :input t :output nil
                                                   :element-type 'character
                                                   :external-format :utf-8)
                       connection)
       (error (condition) (note-failure "client" condition))))
   :name "vivarium-client"))

(defun start-sweeper (instance)
  "One sweeper per generation, ending with that generation.

Looping on a bare global meant looping on `is ANY daemon up`, so every daemon
this process ever started left a sweeper alive for the next one -- a hundred
and twenty of them after a test that cycles daemons. Threads that outlive the
thing they belong to are the same unowned lifetime as every other bug here."
  (bt:make-thread
   (lambda ()
     (loop while (current-p instance)
           do (sleep 1)
              (ignore-errors (sweep-clients))))
   :name "vivarium-sweeper"))

;;; The daemon

(defun running-p (&optional (path (socket-path)))
  "Is something answering on the socket?

Answers the question and does nothing else. This used to delete the file
whenever a connection failed for any reason, on the theory that only a stale
file can refuse -- but a full backlog refuses too, so one badly timed probe
unlinked a live daemon's socket and left a running process nobody could reach.
Clearing a stale file is a repair, and repair belongs in SERVE, which already
does it before binding."
  (and (probe-file path)
       (handler-case
           (let ((socket (make-instance 'sockets:local-socket :type :stream)))
             (unwind-protect
                  (progn
                    (sockets:socket-connect socket path)
                    ;; READ the greeting rather than hanging up on it. Answering
                    ;; is what `answering` means, so this is the better probe --
                    ;; and connecting without reading made the daemon write into
                    ;; a closed descriptor, so every probe left a broken pipe
                    ;; behind. `daemon start --background` reported two contained
                    ;; client failures it had caused itself.
                    (let ((stream (sockets:socket-make-stream socket :input t :output t)))
                      (and (read-line stream nil nil) t)))
               (ignore-errors (sockets:socket-close socket))))
         (error () nil))))

(defun %stop (instance)
  "Tear down INSTANCE. Callers hold *LOCK* and have checked it is current."
  (ignore-errors (sockets:socket-close (instance-socket instance)))
  ;; The path THIS generation bound: a daemon on a second socket once deleted
  ;; the first one's file on the way out and left its own behind.
  (ignore-errors (delete-file (instance-path instance)))
  ;; Released last: while held, another daemon cannot get as far as binding.
  (a:when-let ((fd (instance-fd instance)))
    (ignore-errors (sb-posix:close fd)))
  (setf *current* nil *state* :stopped)
  t)

(defun stop ()
  "Stop whatever this process is currently serving, or cancel a startup in
flight -- STOP during :STARTING must actually stop it, not report success while
the bind proceeds to completion behind it."
  (bt:with-lock-held (*lock*)
    (cond (*current* (%stop *current*))
          ((eq :starting *state*)
           (setf *starting* nil *state* :stopped)
           t)
          (t t))))

(defun retire (instance)
  "Stop INSTANCE, but only while it is still the current generation.

The accept loop unwinds into this when it ends, and by then the generation it
served may already have been stopped and replaced. Acting unconditionally
closed the NEXT daemon's socket and deleted its file -- about once in ten
suite runs, as a daemon that had just reported itself listening being found
not to be."
  (bt:with-lock-held (*lock*)
    (when (eq instance *current*)
      (%stop instance))))

(defun instance-lock-path (&optional (path (socket-path)))
  (concatenate 'string path ".lock"))

(defun acquire-instance (path)
  "Take the lock that says `I am the daemon`, or NIL if another process holds it.

Held by the kernel for the lifetime of the process, so it cannot go stale the
way a file someone has to remember to delete can. Asking RUNNING-P and then
binding is a decision about a moment that has already passed: two daemons
starting together could each find nothing listening, and the second could
unlink the socket the first had just bound."
  (let ((fd (ignore-errors
             (sb-posix:open (instance-lock-path path)
                            (logior sb-posix:o-creat sb-posix:o-rdwr) #o600))))
    (when fd
      (handler-case (progn (sb-posix:lockf fd sb-posix:f-tlock 0) fd)
        (error () (ignore-errors (sb-posix:close fd)) nil)))))

(defun serve (&key (path (socket-path)) (background nil) announce)
  "Listen until stopped. One thread per connection; sessions outlive all of them.

ANNOUNCE is called once the socket is actually bound. A caller cannot do this
itself: in the foreground SERVE does not return, so anything printed beforehand
is printed by every process that is about to be refused -- five racing daemons
all reported `listening on`, and four of them were not."
  (ensure-directories-exist path)
  ;; Claimed as one transition, not read-then-act: two threads that both saw
  ;; nothing serving both went on to bind, a race the OS lock cannot see -- a
  ;; POSIX record lock is held by the process and grants itself the same lock
  ;; twice.
  (let ((token (or (claim-startup)
                   (error 'daemon-error :detail "This process is already serving.")))
        (started nil))
    (unwind-protect
         (progn (serve-bound path background announce token)
                (setf started t))
      (unless started (release-startup token)))))

(defun serve-bound (path background announce token)
  "Everything stays thread-local until the one installing transition.

Acquisition is inside UNWIND-PROTECT from the first descriptor: a signal from
socket creation, bind, listen or a cancelled install dismantles exactly what
this startup acquired -- fd, socket, path -- and nothing else, because nothing
global refers to any of it until the instance publishes. The old shape only
dismantled in the explicit cancelled branch, so a bind that signalled leaked
the held OS lock and its descriptor, and the next startup found the lock
taken by a daemon that did not exist.

ANNOUNCE runs after publication and under its own guard: a callback that
signals must not convert a started daemon into an apparent failure -- the
daemon IS running by then, and unwinding would tell the caller otherwise
while the accept loop serves on."
  (let ((fd nil) (socket nil) (published nil))
    (unwind-protect
         (progn
           (setf fd (acquire-instance path))
           (unless fd
             (error 'daemon-error :detail (format nil "A daemon is already running on ~a." path)))
           ;; We hold the OS lock, so nothing else is serving: any file here is
           ;; what a crash left behind. The only place that unlinks a socket.
           (ignore-errors (delete-file path))
           (setf socket (make-instance 'sockets:local-socket :type :stream))
           (sockets:socket-bind socket path)
           ;; SOMAXCONN, not a token depth. A full backlog answers
           ;; ECONNREFUSED, which is the same answer as no daemon at all.
           ;; Measured: 24 simultaneous connects against a backlog of 16
           ;; refused two.
           (sockets:socket-listen socket 128)
           (let ((instance (make-daemon-instance :socket socket :path path :fd fd)))
             (bt:with-lock-held (*lock*)
               (unless (eq token *starting*)
                 (error 'daemon-error :detail "Startup was cancelled."))
               (setf *current* instance
                     *starting* nil
                     *state* :running))
             (setf published t)
             (handler-case (start-sweeper instance)
               (error (condition) (note-failure "sweeper" condition)))
             (when announce
               (handler-case (funcall announce path)
                 (error (condition) (note-failure "announce" condition))))
             (flet ((accept-loop ()
                      (unwind-protect
                           (loop with failures = 0
                                 ;; This generation, not `some daemon`.
                                 while (current-p instance)
                                 do (let ((connection (handler-case (sockets:socket-accept socket)
                                                        (error () nil))))
                                      (cond (connection
                                             (setf failures 0)
                                             (serve-connection connection))
                                            ;; STOP closed the listener: the
                                            ;; ordinary exit. Anything else is
                                            ;; one refused connection, which
                                            ;; must not retire the listener.
                                            ((or (not (current-p instance))
                                                 (> (incf failures) 32))
                                             (loop-finish)))))
                        (retire instance))))
               (if background
                   (bt:make-thread #'accept-loop :name "vivariumd")
                   (accept-loop)))
             path))
      (unless published
        (when socket
          (ignore-errors (sockets:socket-close socket))
          (ignore-errors (delete-file path)))
        (when fd (ignore-errors (sb-posix:close fd)))))))

(defun current-p (instance)
  (bt:with-lock-held (*lock*) (eq instance *current*)))

;;; Talking to one

(defun connect (&optional (path (socket-path)))
  "One connection, and no probe first.

Asking RUNNING-P here opened and closed a whole extra connection for every one
that mattered: churn against the accept loop, and a second chance to be told no
between the asking and the connecting."
  (let ((socket (make-instance 'sockets:local-socket :type :stream)))
    (handler-case (sockets:socket-connect socket path)
      (error ()
        (ignore-errors (sockets:socket-close socket))
        (error 'daemon-error :detail (format nil "No daemon listening on ~a." path))))
    (sockets:socket-make-stream socket :input t :output t
                                       :element-type 'character :external-format :utf-8)))

(defmacro with-connection ((stream &optional (path '(socket-path))) &body body)
  `(let ((,stream (connect ,path)))
     (unwind-protect (progn ,@body) (ignore-errors (close ,stream)))))

(defun request (stream &rest plist)
  "One request, one response. Events arriving meanwhile are returned alongside,
because a caller that discarded them would lose the only account of what
happened between asking and being answered."
  (jzon:with-writer* (:stream stream) (jzon:write-value* (apply #'object plist)))
  (terpri stream)
  (force-output stream)
  (loop with events = '()
        for line = (read-line stream nil nil)
        while line
        for reply = (ignore-errors (jzon:parse line))
        when (and reply (equal "response" (gethash "type" reply)))
          return (values reply (nreverse events))
        when (and reply (gethash "event" reply)) do (push reply events)))
