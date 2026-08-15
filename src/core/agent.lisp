;;;; The agent object.
;;;;
;;;; Everything the loop needs to build a request is read through a generic
;;;; function at the moment the request is built, never captured when the run
;;;; starts. That is the one deliberate difference from Pi, where the system
;;;; prompt and tool set are resolved before the loop begins: here another
;;;; thread can change what the agent is while it is mid-run, and the next
;;;; request already carries it.

(in-package #:vivarium.agent)

(defclass agent ()
  ((model :initarg :model :accessor agent-model :initform "local"
          :type string)
   (temperature :initarg :temperature :accessor agent-temperature :initform 0.0)
   ;; A fixed seed is what makes a scored trial repeatable. Temperature 0 is not
   ;; enough on its own once a sampler has any tie-breaking left in it.
   (seed :initarg :seed :accessor agent-seed :initform 42)
   (max-tokens :initarg :max-tokens :accessor agent-max-tokens :initform 4096)
   ;; Pi's thinking level. On a reasoning model this is not a nicety: at high
   ;; effort gpt-oss-20b spends its whole token budget thinking and emits no
   ;; tool call at all, so the run looks silent while the model works.
   (reasoning-effort :initarg :reasoning-effort :accessor agent-reasoning-effort
                     :initform nil
                     :documentation "\"low\", \"medium\", \"high\", or NIL to leave it to the model.")
   (parallel-tools-p :initarg :parallel-tools :accessor agent-parallel-tools-p
                     :initform nil :type boolean)
   ;; A GBNF sent with the request. Constrains the sampler to a shape the harness
   ;; can always read -- the same guarantee llama.cpp gives JSON tool calls for
   ;; free, made available to s-expression output which nothing generates one for.
   (grammar :initarg :grammar :accessor agent-grammar :initform nil)
   ;; Which server this agent talks to. An agent carries its own so a scored
   ;; trial can point one arm at a local model and another at a hosted one
   ;; without the loop or the tools knowing.
   (provider :initarg :provider :accessor agent-provider :initform nil)
   (stream-p :initarg :stream :accessor agent-stream-p :initform nil :type boolean
             :documentation "Stream the response, so it can be watched and aborted.")
   (%system-prompt :initarg :system-prompt :initform "" :type string)
   (%tools :initarg :tools :initform '() :type list)))

(defgeneric system-prompt (agent)
  (:documentation "The system prompt for the NEXT request, read at request time.")
  (:method ((agent agent)) (slot-value agent '%system-prompt)))

(defgeneric (setf system-prompt) (value agent)
  (:method (value (agent agent)) (setf (slot-value agent '%system-prompt) value)))

(defgeneric tools (agent)
  (:documentation "The tools available on the NEXT request, read at request time.")
  (:method ((agent agent)) (slot-value agent '%tools)))

(defgeneric (setf tools) (value agent)
  (:method (value (agent agent)) (setf (slot-value agent '%tools) value)))

;;; Loop hooks. Each corresponds to a callback in Pi's AgentLoopConfig.

(defgeneric steering-messages (agent)
  (:documentation "Messages to inject before the next assistant response.
Polled at the end of every inner iteration, matching agent-loop.ts:259.")
  (:method ((agent agent)) '()))

(defgeneric follow-up-messages (agent)
  (:documentation "Messages that restart the loop after it would have stopped.")
  (:method ((agent agent)) '()))

(defgeneric prepare-next-turn (agent message tool-results context)
  (:documentation "Chance to swap model or context between iterations.
Return NIL to keep everything, matching Pi's optional prepareNextTurn.")
  (:method ((agent agent) message tool-results context)
    (declare (ignore message tool-results context))
    nil))

(defgeneric should-stop-after-turn (agent message tool-results context)
  (:method ((agent agent) message tool-results context)
    (declare (ignore message tool-results context))
    nil))

;;; Decision points.
;;;
;;; EMIT tells an agent what happened; these ask it what should happen, and the
;;; difference is the whole difference between an observer and a participant. An
;;; extension that can only watch a tool call cannot refuse a destructive one,
;;; cannot redact a credential out of a result, and cannot sandbox anything --
;;; which was true here until these existed.
;;;
;;; Each returns NIL to mean "carry on unchanged", so the default costs nothing
;;; and the loop needs no conditional for the ordinary case.

(defgeneric before-tool (agent call)
  (:documentation "Asked before CALL runs.

NIL proceeds. A TOOL-RESULT short-circuits, and the tool never runs -- which is
how a refusal is expressed, and why the refusal reaches the model as an ordinary
result it can read and respond to rather than as a crash. A TOOL-CALL replaces
the call, so arguments can be rewritten.")
  (:method ((agent agent) call) (declare (ignore call)) nil))

(defgeneric after-tool (agent call result)
  (:documentation "Asked after CALL ran. NIL keeps RESULT; a TOOL-RESULT replaces it.")
  (:method ((agent agent) call result) (declare (ignore call result)) nil))

(defgeneric before-request (agent messages)
  (:documentation "Asked with the conversation about to be sent.
NIL sends it unchanged; a list of messages replaces it.")
  (:method ((agent agent) messages) (declare (ignore messages)) nil))

(defgeneric after-response (agent message)
  (:documentation "Asked with the assistant message just received.
NIL keeps it; a message replaces it.")
  (:method ((agent agent) message) (declare (ignore message)) nil))

(defgeneric call-in-tool-context (agent thunk)
  (:documentation "Call THUNK with whatever dynamic state a tool needs.

The loop runs a parallel batch in spawned threads, and a dynamic REBINDING does
not cross into one -- a thread sees the global value, not the caller's. So an
agent whose tools read a special bound per run would have every tool in a
parallel batch fail, and PARALLEL-TOOLS is a supported setting.

The loop must not know WHICH specials matter; it knows only that the agent does.")
  (:method ((agent agent) thunk) (funcall thunk)))

(defgeneric emit (agent event)
  (:documentation "Receive one loop event, a plist beginning with :TYPE.")
  (:method ((agent agent) event) (declare (ignore event)) nil))

(defgeneric should-abort-p (agent)
  (:documentation "Checked between streamed events. True stops the request in
flight, rather than at the next request boundary.")
  (:method ((agent agent)) nil))

;;; The concrete agent used by both arms: steering and follow-up come from two
;;; queues an outside thread can push to.

(defclass queued-agent (agent)
  ((lock :initform (bt:make-lock "vivarium.agent") :reader agent-lock)
   (abort-on-steer-p :initarg :abort-on-steer :accessor agent-abort-on-steer-p
                     :initform nil :type boolean)
   (steering :initform '() :accessor %steering)
   (follow-up :initform '() :accessor %follow-up)))

(defun drain (agent accessor)
  (bt:with-lock-held ((agent-lock agent))
    (prog1 (nreverse (funcall accessor agent))
      (funcall (fdefinition `(setf ,accessor)) '() agent))))

(defmethod steering-messages ((agent queued-agent))
  (drain agent '%steering))

(defmethod follow-up-messages ((agent queued-agent))
  (drain agent '%follow-up))

(defun queue-steering (agent message)
  "Deliver MESSAGE before the agent's next request in this run."
  (bt:with-lock-held ((agent-lock agent))
    (push message (%steering agent))))

(defun queue-follow-up (agent message)
  "Deliver MESSAGE only once the agent would otherwise have stopped."
  (bt:with-lock-held ((agent-lock agent))
    (push message (%follow-up agent))))

(defmethod should-abort-p ((agent queued-agent))
  "A steer queued mid-generation aborts the request it interrupts. Pi and Codex
both deliver a steer no earlier than the next request; this delivers it into the
one already running."
  (and (agent-abort-on-steer-p agent)
       (bt:with-lock-held ((agent-lock agent))
         (and (%steering agent) t))))
