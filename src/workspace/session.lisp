;;;; The session: a tree of entries, a stream of records, one JSONL file.
;;;;
;;;; JSONL because the two properties that matter are append-without-rewrite and
;;;; survives-a-crash-mid-write. A session killed in the middle of a line loses
;;;; that line and nothing else.
;;;;
;;;; The shape is Pi's, because Pi's is right and a harness that stores a flat
;;;; list has quietly decided it will never fork, never branch and never compact:
;;;;
;;;;   ENTRY   part of the conversation. Carries ID and PARENT, so entries form
;;;;           a tree rather than a list. Two entries with the same parent are
;;;;           two branches, in one file, with nothing copied.
;;;;   RECORD  what happened AROUND the conversation -- tool timings, token
;;;;           usage, an extension's bookkeeping. Has an id, has no parent, is
;;;;           not in the tree, and is never sent to a model.
;;;;
;;;; The tree is what makes the rest possible. ANCESTRY walks a leaf back to the
;;;; root, which is how a session resumes; a COMPACTION entry stops that walk and
;;;; substitutes its summary, which is how a long session survives; and forking
;;;; is just a second child, which is why it needs no second file.
;;;;
;;;; Messages are stored structurally, never as rendered text. A transcript that
;;;; reads back only as prose cannot be resumed: the tool call ids stop matching
;;;; their results and the provider rejects the conversation.

(in-package #:vivarium.session)

(defparameter +format-version+ 2)

(defstruct (entry (:conc-name entry-))
  (id "" :type string)
  ;; NIL for the root of the tree, and for every record -- a record is not part
  ;; of the conversation and has nowhere to hang.
  (parent nil)
  (kind :message :type keyword)
  (time 0 :type integer)
  (payload nil))

(defstruct (session (:conc-name session-))
  (id "" :type string)
  (path "" :type string)
  (stream nil)
  (cwd "" :type string)
  ;; PARENT is the session this was forked from. ENTRIES is newest first, so an
  ;; append is a push. LEAF is where the next entry attaches, and moving it is
  ;; the whole of branching.
  (parent nil)
  (entries '() :type list)
  (index (make-hash-table :test #'equal) :type hash-table)
  (leaf nil))

(defparameter +conversation-kinds+ '(:message :compaction :branch-summary :custom)
  "Kinds that live in the tree. Everything else is a record.")

(defun record-p (entry)
  (not (member (entry-kind entry) +conversation-kinds+)))

(defun session-directory ()
  (merge-pathnames ".vivarium/sessions/" (user-homedir-pathname)))

(defun new-id ()
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (get-universal-time))
    (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d-~4,'0x"
            year month day hour minute second (random 65536 (make-random-state t)))))

(defvar *entry-counter* 0)

(defun next-entry-id ()
  "Eight hex characters, as Pi does: short enough to read in a file and to name
in a fork command. Ids only have to be unique within one session, so a UUID here
would be unreadable and buy nothing."
  (format nil "~8,'0x" (logand (+ (* 65536 (incf *entry-counter*))
                                  (random 65536 (make-random-state t)))
                               #xffffffff)))

(defun object (&rest plist)
  "A JSON object. A key whose value is NIL is OMITTED, never written as null.

jzon renders the keyword :NULL as the *string* \"NULL\", so a placeholder here
does not round-trip -- a root entry came back with the parent \"NULL\" rather
than no parent, which happens to stop a tree walk for the wrong reason and would
have stopped meaning anything the moment an entry was legitimately named NULL.
Absence is unambiguous and costs a byte."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          unless (null value) do (setf (gethash key table) value))
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
             "usage" (msg:assistant-message-usage message)
             "stop_reason" (string-downcase (symbol-name (msg:assistant-message-stop-reason message)))))
    (msg:tool-result-message
     (object "role" "tool"
             "call_id" (msg:tool-result-message-call-id message)
             "output" (msg:tool-result-message-output message)
             "error" (msg:tool-result-message-error-p message)))
    (msg:message
     (object "role" (string-downcase (symbol-name (msg:message-role message)))
             "content" (coerce (mapcar #'encode-content (msg:message-content message)) 'vector)))))

;;; Opening and writing

(defun write-line* (session table)
  (a:when-let ((stream (session-stream session)))
    (jzon:with-writer* (:stream stream)
      (jzon:write-value* table))
    (terpri stream)
    (force-output stream)))

(defun open-session (&key (directory (session-directory)) (id (new-id))
                       (cwd (uiop:native-namestring (uiop:getcwd))) parent)
  "Open a session file for appending.

The first line is a header, so a file found on disk says what it is rather than
leaving a reader to infer it from the shape of line two."
  (let* ((path (merge-pathnames (format nil "~a.jsonl" id) directory))
         (fresh (not (probe-file path))))
    (ensure-directories-exist path)
    (let ((session (make-session
                    :id id :path (namestring path) :cwd cwd :parent parent
                    :stream (open path :direction :output :if-exists :append
                                       :if-does-not-exist :create :external-format :utf-8))))
      (when fresh
        (write-line* session (object "kind" "header" "version" +format-version+
                                     "id" id "time" (get-universal-time)
                                     "cwd" cwd "parent" parent)))
      session)))

(defun close-session (session)
  (when (session-stream session)
    (close (session-stream session))
    (setf (session-stream session) nil))
  session)

(defun remember-entry (session entry)
  (push entry (session-entries session))
  (setf (gethash (entry-id entry) (session-index session)) entry)
  entry)

(defun append-entry (session kind payload &key (parent (session-leaf session)))
  "Add one entry to the conversation tree and make it the new leaf.

PARENT defaults to the current leaf, so ordinary appends form a line. Passing an
older entry's id starts a branch there -- which is the whole of forking, and
needs no second file."
  (let ((entry (make-entry :id (next-entry-id) :parent parent :kind kind
                           :time (get-universal-time)
                           :payload (if (msg:message-p payload) (encode-message payload) payload))))
    (remember-entry session entry)
    (setf (session-leaf session) (entry-id entry))
    (write-line* session (object "kind" (string-downcase (symbol-name kind))
                                 "id" (entry-id entry)
                                 "parent" parent
                                 "time" (entry-time entry)
                                 "payload" (entry-payload entry)))
    entry))

(defun append-record (session kind &rest plist)
  "Write an operational record: outside the tree, never sent to a model.

Silently does nothing without a session, so a caller that traces need not know
whether anyone asked for a transcript."
  (when session
    (let ((entry (make-entry :id (next-entry-id) :parent nil :kind kind
                             :time (get-universal-time)
                             :payload (apply #'object plist))))
      (remember-entry session entry)
      (write-line* session (object "kind" (string-downcase (symbol-name kind))
                                   "id" (entry-id entry)
                                   "time" (entry-time entry)
                                   "payload" (entry-payload entry)))
      entry)))

(defun record-entry (session kind payload)
  "Append one conversation entry. The name the harness already calls."
  (append-entry session kind payload))

(defun entries-of (session)
  (reverse (session-entries session)))

(defun records-of (entries &optional kind)
  (let ((entries (if (session-p entries) (entries-of entries) entries)))
    (remove-if-not (lambda (entry)
                     (and (record-p entry)
                          (or (null kind) (eq kind (entry-kind entry)))))
                   entries)))

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
              :usage (let ((usage (gethash "usage" table))) (and (hash-table-p usage) usage))
              :stop-reason (a:make-keyword (string-upcase (or (gethash "stop_reason" table) "stop")))))
            ((equal "tool" role)
             (msg:make-tool-result-message :call-id (gethash "call_id" table)
                                           :output (or (gethash "output" table) "")
                                           :error-p (and (gethash "error" table) t)))
            (t (msg:make-user-message :content (content)))))))

(defun load-session (path)
  "Read a session file back, rebuilding the tree. Returns a SESSION with no open
stream: reading is not writing, and a reader that reopened for append would be
one crash away from corrupting what it came to inspect.

A truncated final line is dropped rather than fatal, which is the whole point of
the format."
  (let ((session (make-session :path (namestring path))))
    (with-open-file (in path :external-format '(:utf-8 :replacement #\replacement_character))
      (loop for line = (read-line in nil nil)
            while line
            for table = (ignore-errors (jzon:parse line))
            when (hash-table-p table)
              do (let ((kind (gethash "kind" table)))
                   (if (equal "header" kind)
                       (setf (session-id session) (or (gethash "id" table) "")
                             (session-cwd session) (or (gethash "cwd" table) "")
                             (session-parent session) (let ((p (gethash "parent" table)))
                                                        (and (stringp p) p)))
                       (let ((entry (make-entry
                                     :id (or (gethash "id" table) (next-entry-id))
                                     :parent (let ((p (gethash "parent" table))) (and (stringp p) p))
                                     :kind (a:make-keyword (string-upcase (or kind "message")))
                                     :time (or (gethash "time" table) 0)
                                     :payload (gethash "payload" table))))
                         (remember-entry session entry)
                         ;; The leaf is the last tree entry written. In a linear
                         ;; session that is the end; in a branched one it is the
                         ;; branch last worked on, which is what resuming means.
                         (unless (record-p entry)
                           (setf (session-leaf session) (entry-id entry))))))))
    session))

;;; Walking the tree -- what makes this a session rather than a log

(defun entry-at (session id)
  (and id (gethash id (session-index session))))

(defun ancestry (session &optional (leaf (session-leaf session)))
  "Entries from LEAF back to the root, oldest first.

Stops at a compaction: everything older has already been replaced by its
summary, and walking past would send the model both."
  (let ((chain '()) (id leaf))
    (loop while id
          for entry = (entry-at session id)
          while entry
          do (push entry chain)
             (setf id (if (eq :compaction (entry-kind entry)) nil (entry-parent entry))))
    chain))

(defun children-of (session id)
  (remove-if-not (lambda (entry) (equal id (entry-parent entry))) (entries-of session)))

(defun context-entries (session &optional (leaf (session-leaf session)))
  "The entries making up the live conversation at LEAF."
  (remove-if #'record-p (ancestry session leaf)))

(defun compaction-messages (entry)
  "What a compaction contributes in place of everything it replaced."
  (let* ((payload (entry-payload entry))
         (summary (and (hash-table-p payload) (gethash "summary" payload)))
         (tail (and (hash-table-p payload) (gethash "retained" payload))))
    (append (when summary
              (list (msg:make-user-message
                     :content (list (msg:make-text
                                     (format nil "<earlier_conversation>~%~a~%</earlier_conversation>"
                                             summary))))))
            (map 'list #'decode-message (or tail #())))))

(defun session-messages (entries)
  "The conversation, ready to hand back to the loop.

Accepts a SESSION or a list of entries, because the caller almost always wants
the live branch and should not have to say so twice."
  (let ((entries (if (session-p entries) (context-entries entries) entries)))
    (loop for entry in entries
          append (case (entry-kind entry)
                   (:compaction (compaction-messages entry))
                   (:message (when (hash-table-p (entry-payload entry))
                               (list (decode-message (entry-payload entry)))))
                   (t '())))))

(defun compact (session summary &key (keep 0) (tokens-before 0))
  "Replace the branch behind the leaf with SUMMARY, keeping the last KEEP
messages verbatim.

Written as an entry rather than by rewriting the file: the older turns stay on
disk and stay reachable from a different leaf, so compaction loses nothing a
person might later want to read."
  (let* ((live (context-entries session))
         (kept (last (remove-if-not (lambda (entry) (eq :message (entry-kind entry))) live) keep)))
    (append-entry session :compaction
                  (object "summary" summary
                          "tokens_before" tokens-before
                          "retained" (coerce (mapcar #'entry-payload kept) 'vector)))))

(defun fork (session &optional (at (session-leaf session)))
  "Continue from an earlier point. The next entry attaches to AT, so the old
branch and the new one share their history and neither is copied."
  (setf (session-leaf session) at)
  session)

;;; Accounting

(defun usage-of (entries)
  "Total prompt and completion tokens, as the provider reported them.
Returns (values PROMPT COMPLETION REQUESTS-WITH-USAGE)."
  (let ((entries (if (session-p entries) (entries-of entries) entries))
        (prompt 0) (completion 0) (counted 0))
    (dolist (entry entries (values prompt completion counted))
      (let* ((payload (entry-payload entry))
             (usage (and (hash-table-p payload)
                         (or (gethash "usage" payload)
                             (and (eq :usage (entry-kind entry)) payload)))))
        (when (hash-table-p usage)
          (incf prompt (or (gethash "prompt_tokens" usage) 0))
          (incf completion (or (gethash "completion_tokens" usage) 0))
          (incf counted))))))

(defun latest-session (&optional (directory (session-directory)))
  (a:when-let ((files (ignore-errors (directory (merge-pathnames "*.jsonl" directory)))))
    (first (sort files #'string> :key #'namestring))))
