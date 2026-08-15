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

(defvar *socket* nil "The listening socket, while serving.")
(defvar *socket-file* nil "The path SERVE bound, so STOP unlinks that one.")
(defvar *instance-fd* nil "The single-instance lock, held for as long as we serve.")
(defvar *lock* (bt:make-lock "vivarium.daemon"))

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
    (values (copy-list *diagnostics*) *failures*)))

;;; One connection

(defstruct (client (:conc-name client-))
  (stream nil)
  (lock (bt:make-lock "vivarium.client"))
  (key nil)
  (live t :type boolean)
  (watching '() :type list))

(defun say (client table)
  "One JSON object, one line, under a lock: the reader thread and a session's
own thread both write here."
  (bt:with-lock-held ((client-lock client))
    (when (client-live client)
      (handler-case
          (progn (jzon:with-writer* (:stream (client-stream client))
                   (jzon:write-value* table))
                 (terpri (client-stream client))
                 (force-output (client-stream client))
                 t)
        ;; A client that went away is not an error worth reporting to anyone in
        ;; particular; it is the ordinary end of a connection, and the session
        ;; carries on without it. It is still worth counting.
        ;;
        ;; The connection is finished either way. A write that failed part way
        ;; through has left half an object on the wire, and a truncated line
        ;; followed by a whole one is not parseable by anyone.
        (error (condition)
          (note-failure "write" condition)
          (setf (client-live client) nil))))))

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
         (dolist (event (actor:since cell from))
           (say client (event:as-json event))))
        (t
         (push (actor:cell-id cell) (client-watching client))
         (actor:subscribe-since cell (client-key client) from
                                (lambda (event) (say client (event:as-json event)))))))

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
            "cwd" (env:env-cwd (harness:agent-environment (getf now :agent)))
            "model" (agent:agent-model (getf now :agent)))))

(defun text-of (command key &optional default)
  (let ((value (gethash key command)))
    (if (stringp value) value default)))

(defun start-session (command)
  (let* ((cwd (or (text-of command "cwd") (uiop:native-namestring (uiop:getcwd))))
         (choice (models:resolve-model (text-of command "model")))
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

        ((string= "diagnostics" type)
         (multiple-value-bind (kept total) (diagnostics)
           (ok "failures" total "recent" (coerce kept 'vector))))

        ((string= "shutdown" type) (ok) (stop))

        (t (no (format nil "Unknown command ~a." type)))))))

(defun serve-client (stream)
  (let ((client (make-client :stream stream :key (gensym "CLIENT"))))
    (unwind-protect
         (progn
           (say client (object "type" "ready" "pid" (sb-posix:getpid)
                               "sessions" (coerce (mapcar #'cell-json (actor:all-cells)) 'vector)))
           (loop for line = (and (client-live client) (next-line client))
                 while line
                 do (unless (zerop (length (string-trim '(#\Space #\Tab #\Return) line)))
                      (handler-case (handle client (jzon:parse line))
                        (error (condition)
                          (say client (object "type" "response" "success" nil
                                              "error" (princ-to-string condition))))))))
      (unwatch-all client)
      (ignore-errors (close stream)))))

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
                                                   :input t :output t
                                                   :element-type 'character
                                                   :external-format :utf-8))
       (error (condition) (note-failure "client" condition))))
   :name "vivarium-client"))

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
             (unwind-protect (progn (sockets:socket-connect socket path) t)
               (ignore-errors (sockets:socket-close socket))))
         (error () nil))))

(defun stop ()
  (bt:with-lock-held (*lock*)
    (when *socket*
      (ignore-errors (sockets:socket-close *socket*))
      (setf *socket* nil))
    ;; The path SERVE bound, not the default one. This unlinked (SOCKET-PATH)
    ;; whatever it had been told to listen on, so a daemon on a second socket
    ;; deleted the first one's file on its way out and left its own behind.
    (when *socket-file*
      (ignore-errors (delete-file *socket-file*))
      (setf *socket-file* nil))
    ;; Released last: while this is held, another daemon must not get as far as
    ;; binding, and closing it is what releases it.
    (when *instance-fd*
      (ignore-errors (sb-posix:close *instance-fd*))
      (setf *instance-fd* nil)))
  t)

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
  ;; The OS lock is owned by the process, so it says nothing about this process
  ;; asking twice -- and a second SERVE here would overwrite *SOCKET* and orphan
  ;; the listener it replaced.
  (when *socket*
    (error 'daemon-error :detail "This process is already serving."))
  (let ((fd (acquire-instance path)))
    (unless fd
      (error 'daemon-error :detail (format nil "A daemon is already running on ~a." path)))
    (setf *instance-fd* fd))
  ;; We hold the lock, so nothing else is serving, so any file here is what a
  ;; crash left behind. This is the only place that unlinks a socket.
  (ignore-errors (delete-file path))
  (let ((socket (make-instance 'sockets:local-socket :type :stream)))
    (sockets:socket-bind socket path)
    ;; SOMAXCONN, not a token depth. A full backlog answers ECONNREFUSED, which
    ;; is the same answer as no daemon at all -- so a burst of clients did not
    ;; queue, it reported the organism missing. Measured: 24 simultaneous
    ;; connects against a backlog of 16 refused two of them.
    (sockets:socket-listen socket 128)
    (setf *socket* socket
          *socket-file* path)
    (when announce (funcall announce path))
    (flet ((accept-loop ()
             (unwind-protect
                  (loop with failures = 0
                        while *socket*
                        do (let ((connection (handler-case (sockets:socket-accept socket)
                                               (error () nil))))
                             (cond (connection
                                    (setf failures 0)
                                    (serve-connection connection))
                                   ;; STOP closed the listener: the ordinary
                                   ;; exit. Anything else is one refused
                                   ;; connection -- a client hanging up between
                                   ;; connecting and being served must not
                                   ;; retire the listener, which is what
                                   ;; leaving the loop does, since unwinding
                                   ;; here deletes the socket.
                                   ((or (null *socket*) (> (incf failures) 32))
                                    (loop-finish)))))
               (stop))))
      (if background
          (bt:make-thread #'accept-loop :name "vivariumd")
          (accept-loop)))
    path))

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
