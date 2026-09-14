;;;; Working on past the end of a turn.
;;;;
;;;; A turn ends when the model stops calling tools, and that is the right
;;;; default: the person asked something, it was answered, the floor goes back.
;;;; But some work is not one question. A long refactor, a test suite being
;;;; driven to green, a queue being emptied -- each of those is the same turn
;;;; asked again until it is done, and the only thing standing between the
;;;; agent and the next iteration is a person pressing return.
;;;;
;;;; So: the agent writes down what it would want asked next, and whatever owns
;;;; turns asks it once this one has ended.
;;;;
;;;; NOT A STEER AND NOT A FOLLOW-UP, both of which already exist and are the
;;;; wrong shape. A steer lands inside the running turn. A follow-up restarts
;;;; the loop without the turn ever having ended -- so nothing outside sees a
;;;; boundary, the request limit that bounds a turn never resets, and a client
;;;; watching sees one turn that will not finish. A continuation ends the turn
;;;; properly and starts another, which is what makes the loop legible from
;;;; outside and stoppable by the ordinary cancel.
;;;;
;;;; THE STOP IS THE FEATURE. A loop with no brake is not a capability, it is a
;;;; bill. There are three, and they are deliberately all the obvious ones:
;;;; the agent clears it, a person cancels the session, or the limit runs out.

(in-package #:viva.harness)

(defparameter +continue-capability+ "loop"
  "The name `config` asks for to put CONTINUE in front of the model.")

(defparameter +max-continuations+ 1000
  "The largest bound this tool will accept.

Not a policy about how long work may take -- an unbounded loop is still
available and is what `until you stop me` means. It is a guard against a model
that meant `keep going` and typed a number with the digits of a phone number,
which is a mistake nobody notices until the invoice.")

(defun continuation-status (agent)
  (multiple-value-bind (text left) (continuation-of agent)
    (cond ((null text) "No continuation is set. This turn will be the last one.")
          (left (format nil "Continuing for ~d more turn~:p with: ~a" left text))
          (t (format nil "Continuing until stopped, with: ~a" text)))))

(defun arm-continuation (agent args)
  (let ((message (gethash "message" args))
        (turns (gethash "turns" args)))
    (cond
      ((or (null message) (zerop (length (string-trim '(#\Space #\Newline #\Tab) message))))
       (tool:make-tool-result
        :output "`start` needs a message: the prompt to send yourself when this turn ends."
        :error-p t))
      ((and turns (or (not (integerp turns)) (< turns 1) (> turns +max-continuations+)))
       (tool:make-tool-result
        :output (format nil "turns must be between 1 and ~d, or left out to continue ~
until something stops it." +max-continuations+)
        :error-p t))
      (t
       (set-continuation agent message :limit turns)
       (format nil "Set. When this turn ends you will be asked: ~a~%~%~a~%~%~
Call this tool again with action \"stop\" once the work is done -- nothing else ~
will end the loop except the person cancelling the session."
               message
               (if turns
                   (format nil "It will repeat at most ~d more time~:p." turns)
                   "It will repeat until you stop it or the session is cancelled."))))))

(tool:define-tool continue-tool (args context)
  :name "continue"
  :description "Keep working after this turn ends, without being asked again.

Normally a turn ends when you stop calling tools and the person has to say
something before you do any more. Call this with action \"start\" and a message,
and that message is sent to you as the next prompt the moment this turn ends --
so a long piece of work carries on by itself.

USE IT FOR WORK YOU CAN CHECK YOURSELF: driving a test suite to green, applying
the same change across many files, emptying a queue. The message should say what
to do next and how you will know you are done -- you are writing it for yourself
with none of this turn's reasoning to hand, only the conversation.

STOP IT YOURSELF when the work is finished. Call action \"stop\". A loop nobody
stops keeps spending money on a job that is already done, and the person is not
obliged to notice on your behalf. If you cannot tell whether you are finished,
stop and say so rather than going round again."
  :parameters (("action" :string "start, stop, or status" :required-p t)
               ("message" :string "For `start`: the prompt to send yourself when
this turn ends. Self-contained." :required-p nil)
               ("turns" :integer "For `start`: how many more turns at most. Leave
it out to continue until you stop it or the session is cancelled." :required-p nil))
  (a:if-let ((agent *agent*))
    (let ((action (string-trim " " (or (gethash "action" args) ""))))
      (cond ((string-equal "start" action) (arm-continuation agent args))
            ((string-equal "stop" action)
             (clear-continuation agent)
             "Stopped. This turn will be the last one unless somebody says otherwise.")
            ((string-equal "status" action) (continuation-status agent))
            (t (tool:make-tool-result
                :output (format nil "no such action: ~a. Use start, stop or status." action)
                :error-p t))))
    (tool:make-tool-result :output "No agent to continue." :error-p t)))

;;; Registered at load time, asked for by name in `config`.
;;;
;;; A CAPABILITY RATHER THAN A TOOL IN THE DEFAULT SET, because an agent that
;;; can extend its own turn indefinitely has changed what running it costs, and
;;; that is a thing an installation says yes to rather than discovers.
(extension:register-builtin
 +continue-capability+
 (lambda () (list :tools (list continue-tool)))
 :description "Let the agent send itself the next prompt, so work continues past the end of a turn.")
