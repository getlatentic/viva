;;;; Compaction: surviving a context window.
;;;;
;;;; Without this a long session does not degrade, it stops -- the provider
;;;; refuses the request and the run ends mid-task. That is the largest
;;;; functional gap between this harness and Pi's, and it is why a session tree
;;;; had to exist first: compaction is written as an ENTRY, so the turns it
;;;; replaces stay on disk and stay reachable from a leaf that predates them.
;;;; Nothing is destroyed; the live branch simply stops walking past the summary.
;;;;
;;;; TWO THINGS ARE EASY TO GET WRONG HERE AND BOTH BREAK THE NEXT REQUEST.
;;;;
;;;; The retained tail must not begin with a tool result whose call has been
;;;; summarised away. Every provider rejects a result with no call, so the tail
;;;; is extended backwards until it starts on a user message or on the assistant
;;;; message that made the calls.
;;;;
;;;; The trigger must use the provider's own token count, not an estimate. The
;;;; estimate is only used to choose how much tail to keep, where being wrong
;;;; costs a few hundred tokens rather than a rejected request.

(in-package #:vivarium.compaction)

(defstruct (settings (:conc-name settings-))
  (enabled-p t :type boolean)
  ;; What the model will accept. Conservative by default: a limit set too high
  ;; fails the request it was meant to prevent, and one set too low costs a
  ;; summary nobody needed.
  (context-limit 128000 :type integer)
  ;; Headroom left for the reply and the next tool results.
  (reserve 24000 :type integer)
  (keep-recent 8000 :type integer))

(defun threshold (settings)
  (- (settings-context-limit settings) (settings-reserve settings)))

(defun due-p (settings tokens)
  "Should the context be compacted before the next request?

TOKENS is what the provider reported for the last request. Nothing is estimated
here -- the decision to spend a summarisation request is made on a measurement."
  (and (settings-enabled-p settings)
       (plusp tokens)
       (>= tokens (threshold settings))))

;;; Choosing the tail

(defun rough-tokens (message)
  "A cheap estimate, used only to decide how much tail to keep.

Four characters per token is wrong in both directions and does not matter: being
out by a third here changes how much history is retained, not whether the next
request is valid."
  (let ((text (msg:text-of message)))
    (+ (ceiling (length text) 4)
       (loop for call in (msg:tool-calls-in message)
             sum (+ 8 (ceiling (length (msg:tool-call-name call)) 4)))
       (if (msg:tool-result-message-p message)
           (ceiling (length (msg:tool-result-message-output message)) 4)
           0))))

(defun dangling-p (messages)
  "Does MESSAGES begin with a tool result whose call is not in it?"
  (let ((first-message (first messages)))
    (and first-message (msg:tool-result-message-p first-message))))

(defun retained-tail (messages budget)
  "The most recent messages fitting in BUDGET, never starting on a dangling
tool result."
  (let ((tail '()) (spent 0))
    (dolist (message (reverse messages))
      (let ((cost (rough-tokens message)))
        (when (and tail (> (+ spent cost) budget)) (return))
        (push message tail)
        (incf spent cost)))
    ;; Extend backwards over any result whose call would have been left behind.
    ;; A single step is not enough: a batch of parallel calls produces several
    ;; results in a row, all belonging to one assistant message.
    (let ((position (- (length messages) (length tail))))
      (loop while (and (plusp position) (dangling-p tail))
            do (decf position)
               (push (nth position messages) tail)))
    tail))

;;; Summarising

(defun render (message)
  "One line per message for the summariser: role, text, and what it called."
  (format nil "[~a] ~a~@[ (called ~{~a~^, ~})~]"
          (string-downcase (symbol-name (msg:message-role message)))
          (let ((text (msg:text-of message)))
            (if (msg:tool-result-message-p message)
                (msg:tool-result-message-output message)
                text))
          (mapcar #'msg:tool-call-name (msg:tool-calls-in message))))

(defparameter +instruction+
  "You are compacting a working session so it can continue in a smaller context.

Write a summary that lets the work carry on with no other memory of what came
before. Keep: what was asked, what has been established about the code, what has
been changed and where, what was tried and failed, and what remains to do. Keep
file paths, function names and exact values -- they cannot be recovered.

Drop the search that found nothing, the file contents already acted on, and the
narration. Do not address anyone; write it as notes to the person continuing.")

(defgeneric summarise (agent messages &key instruction)
  (:documentation "Condense MESSAGES into notes that let the work continue.

Generic for the same reason CLIENT:COMPLETE is: the provider belongs to the
agent, so a test can substitute a scripted summariser without the network, and a
caller with its own summarisation strategy can supply one. The default method
sends the request itself, which is why an override is the only way to test the
surrounding logic offline."))

(defmethod summarise (agent messages &key (instruction +instruction+))
  "One model request, on the agent's own provider, with no tools.

A bare agent rather than the working one: handing the summariser the live tool
set invites it to answer the task instead of describing it."
  (let ((scribe (make-instance 'agent:queued-agent
                               :provider (agent:agent-provider agent)
                               :model (agent:agent-model agent)
                               :max-tokens 2048
                               :system-prompt instruction
                               :tools '())))
    (msg:text-of
     (client:complete
      scribe
      (list (msg:make-user-message
             :content (list (msg:make-text
                             (format nil "~{~a~%~}"
                                     (mapcar #'render messages))))))))))

