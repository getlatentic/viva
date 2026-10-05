;;;; Carrying on a turn the daemon died during.
;;;;
;;;; The transcript is written as the turn goes -- the prompt, each answer with
;;;; the calls it asked for, an intent record before each call runs, and each
;;;; result -- so a crash leaves the conversation at a known point. From there
;;;; the turn picks up the way Pi Durable's tasks do: a model request cut off is
;;;; made again, and a tool call cut off runs again only when running it twice
;;;; is harmless. Every other call is answered as interrupted, and the model,
;;;; which can see what it asked for, decides what to do about it.

(in-package #:viva.harness)

(defparameter +interrupted+
  "Interrupted: the daemon stopped while this call was running, and it was not
run again because running it twice may not be harmless. It may or may not have
taken effect. Check before running it again."
  "What a tool call cut off by a crash answers with when it is not run again.")

(defun unanswered-calls (messages)
  "The calls of the last answer in MESSAGES that asked for any, with no result
after it, in the order they were asked for."
  (a:when-let ((at (position-if (lambda (message)
                                  (and (msg:assistant-message-p message)
                                       (msg:tool-calls-in message)))
                                messages :from-end t)))
    (let ((answered (loop for message in (nthcdr (1+ at) messages)
                          when (msg:tool-result-message-p message)
                            collect (msg:tool-result-message-call-id message))))
      (remove-if (lambda (call) (member (msg:tool-call-id call) answered :test #'equal))
                 (msg:tool-calls-in (nth at messages))))))

(defun recorded-replay (session call-id)
  "The replay class written down for CALL-ID before it ran. :UNSAFE when there
is no record: a call whose intent did not reach the disk is not known to be
harmless."
  (let ((record (find call-id (session:records-of session :intent)
                      :key (lambda (entry) (gethash "call" (session:entry-payload entry)))
                      :test #'equal)))
    (if (and record (equal "safe" (gethash "replay" (session:entry-payload record))))
        :safe
        :unsafe)))

(defun replayable-p (agent call)
  "May CALL run again? Only when the class written down before it ran AND the
tool's class now both say it is harmless. A tool that stopped being safe since
must not be run again on the strength of what an older build believed, and
one that became safe since did not run as a safe call."
  (and (eq :safe (recorded-replay (agent-session agent) (msg:tool-call-id call)))
       (a:when-let ((tool (loop*:find-tool agent (msg:tool-call-name call))))
         (eq :safe (tool:tool-replay tool)))))

(defun interrupt-call (agent call)
  "Answer CALL as interrupted, in the transcript and on the event stream."
  (let ((result (tool:make-tool-result :output +interrupted+ :error-p t)))
    (agent:emit agent (list :type :tool-end :call call :result result))
    (msg:make-tool-result-message :call-id (msg:tool-call-id call)
                                  :output +interrupted+
                                  :error-p t)))

(defun settle-unanswered (agent &key (rerun t))
  "Give every call the conversation left without a result exactly one: run it
again when RERUN and it is harmless to, answer it as interrupted otherwise.
Returns (values RERUN INTERRUPTED), the calls each way.

A CONVERSATION ENDING IN AN UNANSWERED CALL IS ONE NO PROVIDER ACCEPTS, so this
runs on every restored session, whether or not a turn resumes."
  (let* ((context (agent-context agent))
         (calls (unanswered-calls (loop*:context-messages context)))
         (rerun-calls '())
         (interrupted '()))
    (when calls
      (let ((results
              (agent:call-in-tool-context
               agent
               (lambda ()
                 (loop for call in calls
                       collect (if (and rerun (replayable-p agent call))
                                   (progn (push call rerun-calls)
                                          (first (loop*:execute-batch agent (list call) context)))
                                   (progn (push call interrupted)
                                          (interrupt-call agent call))))))))
        (setf (loop*:context-messages context)
              (append (loop*:context-messages context) results))))
    (values (nreverse rerun-calls) (nreverse interrupted))))

(defun turn-entered-p (agent turn)
  "Did TURN reach the conversation? Its prompt is written as its first entry."
  (and turn
       (a:when-let ((session (agent-session agent)))
         (and (find turn (session:entries-of session) :key #'session:entry-turn :test #'equal)
              t))))

(defun answered-p (messages)
  "Does MESSAGES end in an answer that asked for nothing more? Then the turn had
done its work, and only its ending went unrecorded."
  (let ((last (car (last messages))))
    (and (msg:assistant-message-p last)
         (null (msg:tool-calls-in last))
         (not (member (msg:assistant-message-stop-reason last) '(:error :aborted))))))

(defun carry-on (agent turn)
  "Run AGENT on from the conversation as it stands, adding nothing to it."
  (setf (agent-requests agent) 0
        (agent-aborting agent) nil)
  (extension:fire :agent-start (list :agent agent :text nil :resumed t))
  (let ((produced (in-turn (agent turn)
                    (agent:call-in-tool-context
                     agent
                     (lambda () (loop*:run agent '() :context (agent-context agent)))))))
    (extension:fire :agent-end (list :agent agent :messages produced))
    (values (last-assistant-text produced) produced)))

(defun resume-turn (agent &key turn text retain)
  "Carry on TURN, which the daemon died during. Values as ASK returns them.

THREE PLACES A CRASH CAN LEAVE A TURN, told apart by the transcript:

  not entered   the prompt never reached the conversation: run the turn as it
                would have run, from its prompt
  answered      the final answer was written and the ending was not: nothing
                to ask again
  in the middle a request or a tool batch was cut off: settle the calls, then
                ask the model again from where the conversation stands"
  (cond ((not (turn-entered-p agent turn))
         (settle-unanswered agent :rerun nil)
         (if retain (reflect agent :turn turn) (ask agent text :turn turn)))
        (t
         (in-turn (agent turn) (settle-unanswered agent))
         (let ((messages (loop*:context-messages (agent-context agent))))
           (if (answered-p messages)
               (values (msg:text-of (car (last messages))) '())
               (carry-on agent turn))))))
