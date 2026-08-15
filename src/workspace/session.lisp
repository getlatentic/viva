;;;; The transcript, on disk, one JSON object per line.
;;;;
;;;; JSONL because the two properties that matter are append-without-rewrite and
;;;; survives-a-crash-mid-write. A session killed in the middle of a line loses
;;;; that line and nothing else, which is the difference between resuming work
;;;; and losing it.
;;;;
;;;; Messages are stored structurally, not as rendered text. A transcript that
;;;; can only be read back as prose cannot be resumed into a live context: the
;;;; tool call ids stop matching their results and the provider rejects the
;;;; conversation.

(in-package #:vivarium.session)

(defstruct (entry (:conc-name entry-))
  (kind :message :type keyword)
  (time 0 :type integer)
  (payload nil))

(defstruct (session (:conc-name session-))
  (id "" :type string)
  (path "" :type string)
  (stream nil)
  (entries '() :type list))

(defun session-directory ()
  (merge-pathnames ".vivarium/sessions/" (user-homedir-pathname)))

(defun new-id ()
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (get-universal-time))
    (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d-~4,'0x"
            year month day hour minute second (random 65536 (make-random-state t)))))

(defparameter +format-version+ 1)

(defun open-session (&key (directory (session-directory)) (id (new-id)) cwd parent)
  "Open a new session file for appending. Existing entries are not read.

The first line is a header, so a file found on disk says what it is without a
reader having to infer it from the shape of line two."
  (let* ((path (merge-pathnames (format nil "~a.jsonl" id) directory))
         (fresh (not (probe-file path)))
         (session (progn (ensure-directories-exist path)
                         (make-session :id id :path (namestring path)
                                       :stream (open path :direction :output :if-exists :append
                                                          :if-does-not-exist :create
                                                          :external-format :utf-8)))))
    (when fresh
      (write-line* session (object "kind" "header" "version" +format-version+
                                   "id" id "time" (get-universal-time)
                                   "cwd" (or cwd (uiop:native-namestring (uiop:getcwd)))
                                   "parent" (or parent :null))))
    session))

(defun close-session (session)
  (when (session-stream session)
    (close (session-stream session))
    (setf (session-stream session) nil))
  session)

(defun object (&rest plist)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash key table) value))
    table))

;;; Encoding

(defun encode-content (block*)
  (etypecase block*
    (msg:text (object "type" "text" "text" (msg:text-value block*)))
    (msg:thinking (object "type" "thinking" "text" (msg:thinking-value block*)))
    (msg:tool-call (object "type" "tool_call"
                           "id" (msg:tool-call-id block*)
                           "name" (msg:tool-call-name block*)
                           "arguments" (or (msg:tool-call-arguments block*)
                                           (make-hash-table :test #'equal))))))

(defun encode-message (message)
  (etypecase message
    (msg:assistant-message
     ;; USAGE is the provider's own token count. Recorded because the
     ;; alternative is estimating cost from character counts, and an estimate
     ;; presented as a bill is worse than no number.
     (object "role" "assistant"
             "content" (coerce (mapcar #'encode-content (msg:message-content message)) 'vector)
             "usage" (or (msg:assistant-message-usage message) :null)
             "stop_reason" (string-downcase (symbol-name (msg:assistant-message-stop-reason message)))))
    (msg:tool-result-message
     (object "role" "tool"
             "call_id" (msg:tool-result-message-call-id message)
             "output" (msg:tool-result-message-output message)
             "error" (msg:tool-result-message-error-p message)))
    (msg:message
     (object "role" (string-downcase (symbol-name (msg:message-role message)))
             "content" (coerce (mapcar #'encode-content (msg:message-content message)) 'vector)))))

(defun write-line* (session table)
  (a:when-let ((stream (session-stream session)))
    (jzon:with-writer* (:stream stream)
      (jzon:write-value* table))
    (terpri stream)
    (force-output stream)))

(defun record-entry (session kind payload)
  "Append one entry. KIND is :MESSAGE, or a RECORD kind, or an extension's own."
  (let ((entry (make-entry :kind kind :time (get-universal-time)
                           :payload (if (msg:message-p payload) (encode-message payload) payload))))
    (push entry (session-entries session))
    (write-line* session (object "kind" (string-downcase (symbol-name kind))
                                 "time" (entry-time entry)
                                 "payload" (entry-payload entry)))
    entry))

;;; Records
;;;
;;; Pi's distinction, and it earns its place immediately: an ENTRY is part of
;;; the conversation and may be sent to a model, a RECORD is what happened
;;; around the conversation and never is. Tool timings, token usage and an
;;; extension's own bookkeeping are all records -- writing them as entries would
;;; put telemetry into the next request, and keeping them in a separate file
;;; would lose the interleaving that makes them worth reading.
;;;
;;; SESSION-MESSAGES already selects on :MESSAGE, so a record cannot reach a
;;; provider by accident.

(defun append-record (session kind &rest plist)
  "Write an operational record. KIND is a keyword; PLIST becomes its payload."
  (when session
    (record-entry session kind (apply #'object plist))))

(defun records-of (entries &optional kind)
  (remove-if (lambda (entry)
               (or (eq :message (entry-kind entry))
                   (eq :header (entry-kind entry))
                   (and kind (not (eq kind (entry-kind entry))))))
             entries))

(defun entries-of (session)
  (reverse (session-entries session)))

;;; Decoding

(defun decode-content (table)
  (let ((type (gethash "type" table)))
    (cond ((equal "text" type) (msg:make-text (gethash "text" table)))
          ((equal "thinking" type) (msg:make-thinking (gethash "text" table)))
          ((equal "tool_call" type)
           (msg:make-tool-call :id (gethash "id" table)
                               :name (gethash "name" table)
                               :arguments (gethash "arguments" table)))
          (t nil))))

(defun decode-message (table)
  (let ((role (gethash "role" table)))
    (flet ((content () (remove nil (map 'list #'decode-content (or (gethash "content" table) #())))))
      (cond ((equal "assistant" role)
             (msg:make-assistant-message
              :content (content)
              :stop-reason (a:make-keyword (string-upcase (or (gethash "stop_reason" table) "stop")))))
            ((equal "tool" role)
             (msg:make-tool-result-message :call-id (gethash "call_id" table)
                                           :output (or (gethash "output" table) "")
                                           :error-p (and (gethash "error" table) t)))
            (t (msg:make-user-message :content (content)))))))

(defun load-session (path)
  "Read a session file back. A truncated final line is dropped, not fatal."
  (with-open-file (in path :external-format '(:utf-8 :replacement #\replacement_character))
    (loop for line = (read-line in nil nil)
          while line
          for table = (ignore-errors (jzon:parse line))
          when table
            collect (make-entry :kind (a:make-keyword (string-upcase (gethash "kind" table)))
                                :time (or (gethash "time" table) 0)
                                :payload (gethash "payload" table)))))

(defun usage-of (entries)
  "Total prompt and completion tokens across ENTRIES, as reported by the
provider. Returns (values PROMPT COMPLETION REQUESTS-WITH-USAGE)."
  (let ((prompt 0) (completion 0) (counted 0))
    (dolist (entry entries (values prompt completion counted))
      (let ((payload (entry-payload entry)))
        (when (hash-table-p payload)
          (let ((usage (gethash "usage" payload)))
            (when (hash-table-p usage)
              (incf prompt (or (gethash "prompt_tokens" usage) 0))
              (incf completion (or (gethash "completion_tokens" usage) 0))
              (incf counted))))))))

(defun session-messages (entries)
  "The conversation from ENTRIES, ready to hand back to the loop."
  (loop for entry in entries
        when (and (eq :message (entry-kind entry)) (hash-table-p (entry-payload entry)))
          collect (decode-message (entry-payload entry))))

(defun latest-session (&optional (directory (session-directory)))
  (a:when-let ((files (ignore-errors (directory (merge-pathnames "*.jsonl" directory)))))
    (first (sort files #'string> :key #'namestring))))
