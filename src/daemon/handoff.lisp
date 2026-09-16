;;;; The handoff: what one image writes down for the next, and how the next
;;;; image takes it over.
;;;;
;;;; An upgrade replaces the daemon's image in the same process (exec.lisp).
;;;; The descriptors survive -- the listener, the instance lock, each client's
;;;; connection, each job's pipe -- and so does every child. Everything else is
;;;; memory: which descriptor is which, what each connection watched and had
;;;; not yet been sent, each session's place in its conversation. It is written
;;;; here, and read back before the new image serves anyone.

(in-package #:viva.daemon)

(defparameter +handoff-format+ 1
  "The shape of the state file. An image checks, before it stops anything, that
the program it is about to become reads this shape: `viva daemon handoff`
prints the formats a build reads.")

(defparameter +handoff-variable+ "VIVA_HANDOFF"
  "Names the state file for the image an upgrade starts.")

(defparameter +handoff-descriptors-variable+ "VIVA_HANDOFF_DESCRIPTORS"
  "The descriptors the old image kept, apart from the state file. If the file
cannot be read, the new image closes these and starts the way a restart does,
rather than holding connections nothing will answer.")

(defun handoff-path ()
  (format nil "~ahandoff-~d.json" (actor:journal-root) (sb-posix:getpid)))

;;; Writing it down

(defun outbound-json (item)
  (if (event:event-p item) (event:as-json item) item))

(defun client-record (client reply)
  "What CLIENT's connection carries across: its descriptor, the sessions it
watches and from where, what was queued for it and not yet sent, and the reply
it is owed when REPLY is the upgrade it asked for."
  (object "fd" (sockets:socket-file-descriptor (client-socket client))
          "watching" (coerce (loop for id in (client-watching client)
                                   for cell = (actor:find-cell id)
                                   when (and cell (actor:subscribed-p cell (client-key client)))
                                     collect (object "session" id
                                                     "from" (getf (actor:snapshot cell) :sequence)))
                             'vector)
          "outbound" (coerce (loop for item in (mailbox:list-mailbox-messages
                                                (client-outbound client))
                                   unless (keywordp item)
                                     collect (outbound-json item))
                             'vector)
          "reply" reply))

(defun handoff-state (instance clients requester reply started)
  "Everything the next image needs and cannot read back from disk. Taken with
every session at rest, every connection and pump stopped at a safe point, and
the journal synced."
  (object "format" +handoff-format+
          "from" *version*
          "started" started
          "listener" (sockets:socket-file-descriptor (instance-socket instance))
          "path" (instance-path instance)
          "lock" (instance-fd instance)
          "sessions" (coerce (mapcar #'actor:cell-record (actor:all-cells)) 'vector)
          "clients" (coerce (mapcar (lambda (client)
                                      (client-record client (and (eq client requester) reply)))
                                    clients)
                            'vector)
          "jobs" (coerce (jobs:handoff-records) 'vector)
          "tasks" (actor:tasks-record)
          "evolution" (actor:evolution-record)
          "diagnostics" (multiple-value-bind (kept failures hangups) (diagnostics)
                          (object "recent" (coerce kept 'vector)
                                  "failures" failures
                                  "hangups" hangups))))

(defun write-handoff (state path)
  "Write STATE to PATH, readable by this user alone: it holds queued prompts and
events not yet delivered, which is conversation."
  ;; The journal's directory, which a daemon that never had a session has not
  ;; made yet.
  (ensure-directories-exist path)
  (let ((fd (sb-posix:open path (logior sb-posix:o-creat sb-posix:o-wronly sb-posix:o-trunc)
                           #o600)))
    (with-open-stream (out (sb-sys:make-fd-stream fd :output t :external-format :utf-8
                                                     :auto-close t))
      (jzon:stringify state :stream out))
    path))

(defun handoff-descriptors (state)
  "Every descriptor STATE names, which are the ones the exec must keep."
  (append (list (gethash "listener" state) (gethash "lock" state))
          (map 'list (lambda (client) (gethash "fd" client)) (gethash "clients" state))
          (loop for job across (gethash "jobs" state)
                when (gethash "fd" job) collect it)))

;;; Taking it over

(defun adopt-instance (state token)
  "This process's listener and instance lock, as the running generation. Both
are already held: the exec kept the descriptors, and a POSIX record lock
belongs to the process, which did not change."
  (let* ((socket (make-instance 'sockets:local-socket :type :stream
                                                      :descriptor (gethash "listener" state)))
         (instance (make-daemon-instance :socket socket
                                         :path (gethash "path" state)
                                         :fd (gethash "lock" state))))
    (bt:with-lock-held (*lock*)
      (unless (eq token *starting*)
        (error 'daemon-error :detail "Startup was cancelled."))
      (setf *current* instance
            *starting* nil
            *state* :running))
    instance))

(defun adopt-session (record)
  "Continue the session RECORD describes, or say why it could not be."
  (let ((id (gethash "id" record))
        (cwd (gethash "cwd" record)))
    (handler-case
        (if (null (session:find-session id :cwd cwd))
            (note-failure "upgrade"
                          (make-condition 'simple-error
                                          :format-control "~a has no transcript under ~a; not carried over"
                                          :format-arguments (list id cwd)))
            (let ((command (make-hash-table :test #'equal)))
              (setf (gethash "cwd" command) cwd
                    (gethash "resume" command) id
                    (gethash "label" command) (gethash "label" record))
              (let ((model (gethash "model" record)))
                (when (and (stringp model) (plusp (length model)))
                  (setf (gethash "model" command) model)))
              (actor:adopt-cell record (session-agent command))))
      (error (condition)
        (note-failure "upgrade"
                      (make-condition 'simple-error
                                      :format-control "~a not carried over: ~a"
                                      :format-arguments (list id condition)))))))

(defun job-output-sink (owner)
  "Where a handed-over job's output goes: the session that owns it, through its
agent, the way a job started in this image reports."
  (a:when-let ((cell (and owner (actor:find-cell owner))))
    (let ((agent (viva.actor::cell-agent cell)))
      (lambda (chunk)
        (agent:emit agent (list :type :tool-output :text chunk))))))

(defun adopt-client (record reply)
  "Serve the connection RECORD describes: what it was owed first, then the
sessions it watched from where it had reached, then its own requests."
  (let* ((fd (gethash "fd" record))
         (socket (make-instance 'sockets:local-socket :type :stream :descriptor fd))
         (client (make-client :socket socket
                              :stream (sockets:socket-make-stream socket :input t :output nil
                                                                         :element-type 'character
                                                                         :external-format :utf-8)
                              :key (gensym "CLIENT"))))
    (register-client client)
    (bt:make-thread
     (lambda ()
       (handler-case
           (serve-lines client
                        (lambda ()
                          (start-writer client)
                          (loop for item across (or (gethash "outbound" record) #())
                                do (say client item))
                          (loop for watched across (or (gethash "watching" record) #())
                                for cell = (actor:find-cell (gethash "session" watched))
                                when cell
                                  do (watch client cell :from (gethash "from" watched)))
                          (a:when-let ((owed (gethash "reply" record)))
                            (say client (funcall reply owed)))))
         (error (condition) (note-failure "client" condition))))
     :name "viva-client")
    client))

(defun upgrade-reply (state)
  "The answer the client that asked for the upgrade is owed, said by this image."
  (lambda (owed)
    (object "id" (or (gethash "id" owed) :omit)
            "type" "response"
            "command" "upgrade"
            "success" t
            "from" (gethash "from" state)
            "to" *version*
            "pid" (sb-posix:getpid)
            "sessions" (length (actor:all-cells))
            "jobs" (length (jobs:all-jobs))
            "seconds" (- (get-universal-time) (gethash "started" state)))))

(defun serve-handed-over (state background announce token)
  "Serve as the image an upgrade started: the generation, the sessions, the
jobs, the task tree and the connections the old image wrote down, in that order
-- a connection is served only once what it watches exists."
  (let ((instance (adopt-instance state token)))
    (setf *started-at* (get-universal-time))
    (handler-case (start-sweeper instance)
      (error (condition) (note-failure "sweeper" condition)))
    (let ((diagnostics (gethash "diagnostics" state)))
      (bt:with-lock-held (*diagnostics-lock*)
        (setf *diagnostics* (coerce (or (gethash "recent" diagnostics) #()) 'list)
              *failures* (or (gethash "failures" diagnostics) 0)
              *hangups* (or (gethash "hangups" diagnostics) 0))))

    ;; THE EVOLVER BEFORE THE SESSIONS. Building a session's agent can ask for
    ;; one, and an evolver born then would restore from the ledger alone,
    ;; without the candidates the sessions were part-way through.
    (handler-case (actor:adopt-evolution (gethash "evolution" state))
      (error (condition) (note-failure "upgrade" condition)))
    ;; HELD FROM THE START. A session whose queued prompt started now would run
    ;; a turn while the others are still arriving.
    (setf actor:*holding* t)
    (loop for record across (gethash "sessions" state)
          do (adopt-session record))
    (loop for record across (gethash "jobs" state)
          do (handler-case (jobs:adopt record
                                       :on-output (job-output-sink (gethash "owner" record)))
               (error (condition) (note-failure "upgrade" condition))))
    (handler-case (actor:adopt-tasks (gethash "tasks" state))
      (error (condition) (note-failure "upgrade" condition)))
    (let ((reply (upgrade-reply state)))
      (loop for record across (gethash "clients" state)
            do (handler-case (adopt-client record reply)
                 (error (condition)
                   (ignore-errors (sb-posix:close (gethash "fd" record)))
                   (note-failure "upgrade" condition)))))
    (actor:release-sessions)
    (note-progress "upgrade" (format nil "~a -> ~a" (gethash "from" state) *version*))
    (when announce
      (handler-case (funcall announce (instance-path instance))
        (error (condition) (note-failure "announce" condition))))
    (run-accepting instance background)
    (instance-path instance)))

(defun read-handoff ()
  "The state an upgrade left for this image, or NIL when it was not started by
one. The variables are cleared either way: a child this image starts must not
believe it is the image an upgrade started."
  (let ((path (sb-posix:getenv +handoff-variable+))
        (kept (sb-posix:getenv +handoff-descriptors-variable+)))
    (sb-posix:unsetenv +handoff-variable+)
    (sb-posix:unsetenv +handoff-descriptors-variable+)
    (when (and path (plusp (length path)))
      (handler-case
          (prog1 (let ((state (with-open-file (in path :external-format :utf-8)
                                (jzon:parse in))))
                   (unless (eql +handoff-format+ (gethash "format" state))
                     (error "handoff format ~a, this build reads ~a"
                            (gethash "format" state) +handoff-format+))
                   state)
            (ignore-errors (delete-file path)))
        (error (condition)
          ;; Nothing will answer the connections the old image kept, so they
          ;; are closed and this starts the way a restart does.
          (dolist (fd (and kept (uiop:split-string kept :separator ",")))
            (a:when-let ((number (parse-integer fd :junk-allowed t)))
              (ignore-errors (sb-posix:close number))))
          (ignore-errors (delete-file path))
          (note-failure "upgrade" condition)
          nil)))))
