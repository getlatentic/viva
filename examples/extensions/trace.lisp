;;;; trace -- write what happened around the conversation, into the session.
;;;;
;;;; Written after a measurement was reported from aggregates and three separate
;;;; claims had to be corrected once the wire was actually read: a tool whose
;;;; description was truncated in every prompt ever sent, agents paying half a
;;;; call per run to re-open memory they had already been given, and tool
;;;; results never reaching the transcript at all. None of those were visible in
;;;; a mean; all of them were obvious in a trace.
;;;;
;;;; It writes RECORDS, not entries. A record sits in the same file as the
;;;; conversation, interleaved with it, and is never sent to a model -- which is
;;;; the only arrangement that gives both properties worth having: telemetry you
;;;; can line up against the turn that produced it, and a context window it
;;;; cannot contaminate.
;;;;
;;;; Deliberately an extension rather than harness code. If the harness had to
;;;; grow a tracing subsystem to answer questions like these, the extension API
;;;; would be the wrong shape.

(in-package #:viva.extension)

(defvar *trace-started* (make-hash-table :test #'equal)
  "Tool call id -> internal real time when it began.")

(defun trace-now () (get-internal-real-time))

(defun trace-milliseconds (since)
  (round (* 1000 (- (trace-now) since)) internal-time-units-per-second))

(defun trace-tool-start (event)
  (let ((call (getf event :call)))
    (setf (gethash (viva.message:tool-call-id call) *trace-started*) (trace-now))
    (viva.harness:record
     :tool-started
     "id" (viva.message:tool-call-id call)
     "name" (viva.message:tool-call-name call)
     "arguments" (or (viva.message:tool-call-arguments call)
                     (make-hash-table :test #'equal))))
  nil)

(defun trace-tool-end (event)
  (let* ((call (getf event :call))
         (result (getf event :result))
         (id (viva.message:tool-call-id call))
         (began (gethash id *trace-started*))
         (output (viva.tool:tool-result-output result)))
    (remhash id *trace-started*)
    (viva.harness:record
     :tool-finished
     "id" id
     "name" (viva.message:tool-call-name call)
     "error" (viva.tool:tool-result-error-p result)
     ;; The size, not the text. The output is already in the transcript as a
     ;; tool result, and a record that duplicated it would double the file.
     "output_bytes" (length output)
     "ms" (if began (trace-milliseconds began) :null)))
  nil)

(defun trace-turn-end (event)
  "Token usage for the request that just finished, as the provider reported it.

Recorded per turn rather than summed at the end, because a run that is cut off
by the request limit still has to be costable."
  (let ((message (getf event :message)))
    (a:when-let ((usage (and message (viva.message:assistant-message-usage message))))
      (viva.harness:record
       :usage
       "prompt_tokens" (or (gethash "prompt_tokens" usage) 0)
       "completion_tokens" (or (gethash "completion_tokens" usage) 0)
       "cached_tokens" (let ((details (gethash "prompt_tokens_details" usage)))
                         (if (hash-table-p details)
                             (or (gethash "cached_tokens" details) 0)
                             0)))))
  nil)

(defun trace-run-end (event)
  (viva.harness:record
   :run-finished
   "messages" (length (or (getf event :messages) #())))
  nil)

(defextension "trace"
  :description "Records tool timings and token usage into the session, as records."
  (on :before-tool #'trace-tool-start)
  (on :after-tool #'trace-tool-end)
  (on :turn-end #'trace-turn-end)
  (on :run-end #'trace-run-end)
  (register-command "cost"
                    :description "Tokens this session has spent, as the provider counted them."
                    :handler (lambda (agent argument)
                               (declare (ignore argument))
                               (a:if-let ((session (viva.harness:agent-session agent)))
                                 (multiple-value-bind (prompt completion counted)
                                     (viva.session:usage-of
                                      (viva.session:entries-of session))
                                   (format nil "~d prompt + ~d completion tokens over ~d request~:p"
                                           prompt completion counted))
                                 "not recording"))))
