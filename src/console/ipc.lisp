;;;; IPC mode: JSON objects in on stdin, JSON objects out on stdout.
;;;;
;;;; One object per line, which is the whole framing protocol. No length
;;;; prefixes, no CBOR, no handshake: a line is atomic enough for the traffic
;;;; here, `head -1` is a debugger, and the transcript of a session is a file
;;;; another program can replay.
;;;;
;;;; A prompt runs on its own thread so the reader keeps working while the model
;;;; does. That is what makes STEER and ABORT mean anything -- a steer queued
;;;; here lands in the request already in flight, not after it.

(in-package #:vivarium.console)

(defstruct (server (:conc-name server-))
  (agent nil)
  (out *standard-output* :type stream)
  (lock (bt:make-lock "vivarium.ipc"))
  (worker nil)
  (running t :type boolean))

(defun object (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          unless (eq value :omit) do (setf (gethash key table) value))
    table))

(defun emit-line (server table)
  "One JSON object, one line, under a lock. Two threads write here."
  (bt:with-lock-held ((server-lock server))
    (jzon:with-writer* (:stream (server-out server))
      (jzon:write-value* table))
    (terpri (server-out server))
    (force-output (server-out server))))

(defun event (server name &rest plist)
  (emit-line server (apply #'object "type" "event" "event" name plist)))

(defun respond (server id command &rest plist)
  (emit-line server (apply #'object "type" "response" "id" (or id :omit)
                           "command" command "success" t plist)))

(defun fail (server id command detail)
  (emit-line server (object "type" "response" "id" (or id :omit)
                            "command" command "success" nil "error" detail)))

;;; Events out

(defun call-object (call)
  (object "id" (msg:tool-call-id call)
          "name" (msg:tool-call-name call)
          "arguments" (or (msg:tool-call-arguments call) (make-hash-table :test #'equal))))

(defun message-object (message)
  (etypecase message
    (msg:assistant-message
     (object "role" "assistant"
             "text" (msg:text-of message)
             "tool_calls" (coerce (mapcar #'call-object (msg:tool-calls-in message)) 'vector)
             "stop_reason" (string-downcase (symbol-name (msg:assistant-message-stop-reason message)))))
    (msg:message
     (object "role" (string-downcase (symbol-name (msg:message-role message)))
             "text" (msg:text-of message)))))

(defun ipc-listener (server)
  (lambda (loop-event)
    (case (getf loop-event :type)
      (:delta (a:when-let ((text (wire:text-field (getf loop-event :delta) "content")))
                (when (plusp (length text)) (event server "delta" "text" text))))
      (:turn-start (event server "turn_start"))
      (:message (event server "message" "message" (message-object (getf loop-event :message))))
      (:tool-start (event server "tool_start" "call" (call-object (getf loop-event :call))))
      (:tool-end (let ((result (getf loop-event :result)))
                   (event server "tool_end"
                          "call" (call-object (getf loop-event :call))
                          "output" (tool:tool-result-output result)
                          "error" (tool:tool-result-error-p result))))
      (:run-end (event server "run_end")))))

;;; Commands in

(defun busy-p (server)
  (let ((worker (server-worker server)))
    (and worker (bt:thread-alive-p worker))))

(defun start-prompt (server id text)
  (setf (server-worker server)
        (bt:make-thread
         (lambda ()
           (handler-case
               (multiple-value-bind (reply) (harness:ask (server-agent server) text)
                 (respond server id "prompt" "reply" (or reply "")))
             (error (condition)
               (fail server id "prompt" (princ-to-string condition)))))
         :name "vivarium-prompt")))

(defun state-object (server)
  (let ((agent (server-agent server)))
    (object "model" (agent:agent-model agent)
            "cwd" (env:env-cwd (harness:agent-environment agent))
            "busy" (busy-p server)
            "tools" (coerce (mapcar #'tool:tool-name (agent:tools agent)) 'vector)
            "skills" (coerce (mapcar #'skill:skill-name (harness:agent-skills agent)) 'vector)
            "extensions" (coerce (mapcar #'extension:extension-name
                                         (harness:agent-extensions agent)) 'vector)
            "session" (a:if-let ((s (harness:agent-session agent)))
                        (session:session-path s)
                        :null))))

(defun text-argument (command key)
  (let ((value (gethash key command)))
    (if (stringp value) value "")))

(defun handle (server command)
  (let* ((id (gethash "id" command))
         (type (gethash "type" command))
         (agent (server-agent server)))
    (flet ((message () (or (gethash "message" command) (gethash "text" command))))
      (cond
        ((null type) (fail server id "?" "Every command needs a type."))

        ((string= "prompt" type)
         (cond ((null (message)) (fail server id type "prompt needs a message."))
               ((busy-p server)
                ;; A second prompt while one runs is a follow-up, not an error.
                ;; Rejecting it makes every client implement its own queue.
                (agent:queue-follow-up agent (msg:make-user-message
                                              :content (list (msg:make-text (message)))))
                (respond server id type "queued" "follow_up"))
               (t (start-prompt server id (message))
                  (respond server id type "queued" "now"))))

        ((string= "steer" type)
         (if (message)
             (progn (setf (agent:agent-abort-on-steer-p agent) t)
                    (agent:queue-steering agent (msg:make-user-message
                                                 :content (list (msg:make-text (message)))))
                    (respond server id type))
             (fail server id type "steer needs a message.")))

        ((string= "follow_up" type)
         (if (message)
             (progn (agent:queue-follow-up agent (msg:make-user-message
                                                  :content (list (msg:make-text (message)))))
                    (respond server id type))
             (fail server id type "follow_up needs a message.")))

        ((string= "abort" type)
         (setf (harness:agent-aborting agent) t)
         (respond server id type))

        ((string= "get_state" type) (respond server id type "state" (state-object server)))

        ((string= "get_tools" type)
         (respond server id type "tools"
                  (coerce (mapcar (lambda (each)
                                    (object "name" (tool:tool-name each)
                                            "description" (tool:tool-description each)
                                            "parameters" (schema:parameter-schema
                                                          (tool:tool-parameters each))))
                                  (agent:tools agent))
                          'vector)))

        ((string= "get_skills" type)
         (respond server id type "skills"
                  (coerce (mapcar (lambda (each)
                                    (object "name" (skill:skill-name each)
                                            "description" (skill:skill-description each)
                                            "path" (skill:skill-path each)))
                                  (harness:agent-skills agent))
                          'vector)))

        ((string= "get_messages" type)
         (respond server id type "messages"
                  (coerce (mapcar #'message-object
                                  (loop*:context-messages (harness:agent-context agent)))
                          'vector)))

        ((string= "set_model" type)
         (handler-case
             (let ((choice (models:resolve-model (text-argument command "model"))))
               (setf (agent:agent-provider agent) (models:choice-provider choice)
                     (agent:agent-reasoning-effort agent) (models:choice-effort choice))
               (harness:set-model agent (models:choice-model choice))
               (respond server id type "model" (models:choice-model choice)))
           (error (condition) (fail server id type (princ-to-string condition)))))

        ((string= "set_active_tools" type)
         (let ((names (gethash "tools" command)))
           (harness:set-active-tools agent (and names (coerce names 'list)))
           (respond server id type "tools"
                    (coerce (mapcar #'tool:tool-name (agent:tools agent)) 'vector))))

        ((string= "compact" type)
         (a:if-let ((context (harness:compact-now agent :reason :requested)))
           (respond server id type "messages" (length (loop*:context-messages context)))
           (fail server id type "Nothing to compact.")))

        ;; Everything invocable by name, from all three sources, so a client
        ;; can build a picker without knowing where a command came from.
        ((string= "get_commands" type)
         (respond server id type "commands"
                  (coerce (append
                           (mapcar (lambda (each)
                                     (object "name" (extension:command-name each)
                                             "description" (extension:command-description each)
                                             "source" "extension"))
                                   (extension:all-commands))
                           (mapcar (lambda (each)
                                     (object "name" (template:template-name each)
                                             "description" (template:template-description each)
                                             "source" "prompt"))
                                   (harness:agent-templates agent))
                           (mapcar (lambda (each)
                                     (object "name" (skill:skill-name each)
                                             "description" (skill:skill-description each)
                                             "source" "skill"))
                                   (harness:agent-skills agent)))
                          'vector)))

        ((string= "run_template" type)
         (a:if-let ((found (template:find-template (harness:agent-templates agent)
                                                   (text-argument command "name"))))
           (progn (start-prompt server id (template:expand found (text-argument command "arguments")))
                  (respond server id type "queued" "now"))
           (fail server id type (format nil "No prompt template ~a." (text-argument command "name")))))

        ((string= "list_sessions" type)
         (respond server id type "sessions"
                  (coerce (mapcar (lambda (each)
                                    (object "id" (session:summary-id each)
                                            "messages" (session:summary-messages each)
                                            "opening" (session:summary-opening each)))
                                  (session:list-sessions
                                   :cwd (env:env-cwd (harness:agent-environment agent))))
                          'vector)))

        ((string= "new_session" type)
         (setf (harness:agent-context agent) (loop*:make-context))
         (respond server id type))

        ((string= "reload" type)
         (respond server id type "complaints"
                  (coerce (harness:refresh-resources agent) 'vector)))

        ((string= "run_skill" type)
         (a:if-let ((found (skill:find-skill (harness:agent-skills agent)
                                             (text-argument command "name"))))
           (progn (start-prompt server id (skill:invocation found (text-argument command "instructions")))
                  (respond server id type "queued" "now"))
           (fail server id type (format nil "No skill called ~a." (text-argument command "name")))))

        ((string= "command" type)
         (a:if-let ((found (extension:find-command (text-argument command "name"))))
           (handler-case
               (respond server id type "result"
                        (princ-to-string (or (funcall (extension:command-handler found)
                                                      agent (text-argument command "argument"))
                                             "")))
             (error (condition) (fail server id type (princ-to-string condition))))
           (fail server id type (format nil "No command ~a." (text-argument command "name")))))

        ((string= "exit" type)
         (setf (server-running server) nil)
         (respond server id type))

        (t (fail server id type (format nil "Unknown command type ~a." type)))))))

(defun run-ipc (&key model cwd root (in *standard-input*) (out *standard-output*)
                  (request-limit 200) extra-prompt extension-directories resume)
  "Serve one agent over stdin/stdout until EOF or an exit command."
  (let ((server (make-server :out out)))
    (multiple-value-bind (agent choice complaints)
        (build-agent :model model :cwd cwd :root root :resume resume
                     :extra-prompt extra-prompt :extension-directories extension-directories
                     :listener (ipc-listener server) :request-limit request-limit)
      (setf (server-agent server) agent)
      (emit-line server (object "type" "ready"
                                "model" (models:choice-model choice)
                                "provider" (models:choice-label choice)
                                "state" (state-object server)
                                "complaints" (coerce complaints 'vector)))
      (unwind-protect
           (loop while (server-running server)
                 for line = (read-line in nil nil)
                 while line
                 do (unless (zerop (length (string-trim '(#\Space #\Tab #\Return) line)))
                      (handler-case (handle server (jzon:parse line))
                        (error (condition)
                          (emit-line server (object "type" "response" "success" nil
                                                    "error" (princ-to-string condition)))))))
        (a:when-let ((worker (server-worker server)))
          (when (bt:thread-alive-p worker)
            ;; Ask, wait, then leave. JOIN-THREAD has no timeout, and a request
            ;; wedged in the provider would otherwise hold the process open for
            ;; as long as the socket does.
            (setf (harness:agent-aborting agent) t)
            (loop repeat 100
                  while (bt:thread-alive-p worker)
                  do (sleep 0.1))))
        (a:when-let ((s (harness:agent-session agent))) (session:close-session s)))
      0)))
