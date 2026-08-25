;;;; Server-sent events from an OpenAI-compatible endpoint.
;;;;
;;;; Streaming buys three things the blocking path cannot give:
;;;;
;;;;   - a run that is thinking looks different from a run that has hung. A
;;;;     reasoning model can spend its whole budget before emitting a token, and
;;;;     that failure cost real time here diagnosed from a server log;
;;;;   - abort in flight. A steer that arrives mid-generation can stop the
;;;;     request rather than wait for it, which is the tier above what Pi and
;;;;     Codex do -- both can only preempt a *waiting* tool or land at the next
;;;;     request boundary;
;;;;   - time to first token, which is the honest cost figure for a trial.
;;;;
;;;; The awkward part is tool calls: name and arguments arrive as fragments
;;;; across many chunks, keyed by an index, so they must be reassembled rather
;;;; than read off any single chunk.

(in-package #:viva.stream)

(defstruct (accumulator (:conc-name acc-))
  (text (make-string-output-stream))
  (reasoning (make-string-output-stream))
  ;; index -> (id name . argument-fragments), in arrival order.
  (calls (make-hash-table :test #'eql))
  (order '() :type list)
  (finish-reason nil)
  ;; The provider's own token counts, when it sends them. A streamed response
  ;; carries them in a final chunk that has no choices at all, which is exactly
  ;; the chunk ABSORB used to discard as a keep-alive -- so every streamed run
  ;; reported no usage, and streaming is the path the shell, the IPC server and
  ;; `do` all take. Cost was therefore estimated from character counts when the
  ;; provider had been sending the real number the whole time.
  (usage nil))

(defstruct (partial-call (:conc-name partial-))
  (id "") (name "") (arguments (make-string-output-stream)))

(defun call-at (accumulator index)
  (or (gethash index (acc-calls accumulator))
      (progn (push index (acc-order accumulator))
             (setf (gethash index (acc-calls accumulator)) (make-partial-call)))))

;;; One chunk

(defun absorb-tool-calls (accumulator deltas)
  (unless (vectorp deltas) (return-from absorb-tool-calls))
  (map nil
       (lambda (delta)
         (let* ((index (or (wire:field delta "index") 0))
                (partial (call-at accumulator index))
                (function (wire:field delta "function")))
           (a:when-let ((id (wire:text-field delta "id")))
             (setf (partial-id partial) id))
           (when function
             (a:when-let ((name (wire:text-field function "name")))
               (setf (partial-name partial) name))
             (a:when-let ((fragment (wire:text-field function "arguments")))
               (write-string fragment (partial-arguments partial))))))
       deltas))

(defun absorb (accumulator chunk)
  "Fold one parsed SSE payload into ACCUMULATOR. Returns the delta, or NIL for a
chunk that carries no choice -- a usage summary, or a keep-alive."
  (a:when-let ((usage (wire:field chunk "usage")))
    (setf (acc-usage accumulator) usage))
  (let ((choices (wire:field chunk "choices")))
    (when (and (vectorp choices) (plusp (length choices)))
      (let* ((choice (aref choices 0))
             (delta (or (wire:field choice "delta") (make-hash-table :test #'equal))))
        (a:when-let ((reason (wire:text-field choice "finish_reason")))
          (setf (acc-finish-reason accumulator) reason))
        (a:when-let ((text (wire:text-field delta "content")))
          (write-string text (acc-text accumulator)))
        (a:when-let ((reasoning (wire:reasoning-field delta)))
          (write-string reasoning (acc-reasoning accumulator)))
        (a:when-let ((calls (wire:field delta "tool_calls")))
          (absorb-tool-calls accumulator calls))
        delta))))

;;; The line protocol
;;;
;;; Events are `data: <json>` lines terminated by `data: [DONE]`. Comment lines
;;; and blanks are keep-alives and carry nothing.

(defun payload-of (line)
  "The JSON text of an SSE data line, :DONE, or NIL for anything else."
  (cond ((< (length line) 6) nil)
        ((not (string= "data: " line :end2 6)) nil)
        (t (let ((body (string-trim '(#\Return #\Space) (subseq line 6))))
             (if (string= body "[DONE]") :done body)))))

(defun consume (input accumulator &key on-delta abort-p)
  "Read SSE events from INPUT until [DONE], end of stream, or ABORT-P.
Returns :DONE, :EOF or :ABORTED."
  (loop
    (when (and abort-p (funcall abort-p))
      (return :aborted))
    (let ((line (read-line input nil nil)))
      (when (null line) (return :eof))
      (let ((payload (payload-of line)))
        (cond ((null payload))
              ((eq payload :done) (return :done))
              (t (let ((chunk (handler-case (jzon:parse payload)
                                (error () nil))))
                   (when chunk
                     (let ((delta (absorb accumulator chunk)))
                       (when on-delta (funcall on-delta delta)))))))))))

;;; Result

(defun finished-calls (accumulator)
  (loop for index in (reverse (acc-order accumulator))
        for partial = (gethash index (acc-calls accumulator))
        collect (msg:make-tool-call
                 :id (partial-id partial)
                 :name (partial-name partial)
                 :arguments (let ((text (get-output-stream-string
                                         (partial-arguments partial))))
                              (handler-case (jzon:parse (if (plusp (length text)) text "{}"))
                                (error () (make-hash-table :test #'equal)))))))

(defun stop-reason (accumulator outcome content)
  (cond ((eq outcome :aborted) :aborted)
        ((equal (acc-finish-reason accumulator) "length") :length)
        ((some #'msg:tool-call-p content) :tool-calls)
        (t :stop)))

(defun assistant-message (accumulator outcome)
  (let* ((reasoning (get-output-stream-string (acc-reasoning accumulator)))
         (text (get-output-stream-string (acc-text accumulator)))
         (content (append (when (plusp (length reasoning)) (list (msg:make-thinking reasoning)))
                          (when (plusp (length text)) (list (msg:make-text text)))
                          (finished-calls accumulator))))
    (msg:make-assistant-message
     :content content
     :usage (acc-usage accumulator)
     :stop-reason (stop-reason accumulator outcome content))))

(defun collect (input &key on-delta abort-p)
  "Drive a stream to completion and return (values assistant-message outcome)."
  (let ((accumulator (make-accumulator)))
    (let ((outcome (consume input accumulator :on-delta on-delta :abort-p abort-p)))
      (values (assistant-message accumulator outcome) outcome))))
