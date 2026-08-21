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
  ;; Lane name -> leaf id. A LANE is an independent line of conversation in one
  ;; session, and it needs no new machinery: the tree already branches, so a
  ;; lane is a second name for a second leaf. "main" is the one everything uses
  ;; unless it says otherwise.
  (lanes (make-hash-table :test #'equal) :type hash-table))

(defparameter +conversation-kinds+
  '(:message :compaction :branch-summary :custom :custom-message
    ;; Settings changes are part of the conversation's history, not telemetry:
    ;; a session resumed under a different model or a wider tool set is not the
    ;; session that was recorded.
    :model-change :thinking-change :active-tools-change)
  "Kinds that live in the tree. Everything else is a record.")

(defparameter +main-lane+ "main")

(defun lane-leaf (session &optional (lane +main-lane+))
  (gethash lane (session-lanes session)))

(defun (setf lane-leaf) (id session &optional (lane +main-lane+))
  (setf (gethash lane (session-lanes session)) id))

(defun session-leaf (session)
  "The main lane's leaf. Kept as a name because most callers have only one lane
and should not have to say so."
  (lane-leaf session +main-lane+))

(defun (setf session-leaf) (id session)
  (setf (lane-leaf session +main-lane+) id))

(defun lanes-of (session)
  (sort (loop for name being the hash-keys of (session-lanes session) collect name) #'string<))

(defun record-p (entry)
  (not (member (entry-kind entry) +conversation-kinds+)))

(defun slug (path)
  "A directory name that survives being a path. Pi's --<path>-- scheme: the
separators become dashes so one flat directory holds every project's sessions
and `latest for this project` is a glob rather than a scan of every file."
  (let ((flat (substitute #\- #\/ (string-trim "/" (or path "")))))
    (if (zerop (length flat)) "root" flat)))

(defun session-directory (&optional cwd)
  "Where sessions live. Namespaced by working directory when one is given, so
resuming asks for the last session HERE rather than the last session anywhere."
  (let ((root (merge-pathnames ".vivarium/sessions/" (user-homedir-pathname))))
    (if cwd (merge-pathnames (format nil "~a/" (slug cwd)) root) root)))

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
  "Close the transcript, and remove it if nothing was ever said.

A session with no messages is not a session, it is an accident of attaching:
somebody opened the organism in a directory, looked at it, and left. Keeping
those files makes `vivarium sessions` a list of mostly nothing, and any future
`continue the last conversation` would keep landing on an empty one.

CONSERVATIVE ON PURPOSE. Only a transcript with NO message entries at all is
removed -- header and nothing else. One message, even an unanswered one, is
somebody's work and stays. Deleting a person's record is not a place to be
clever about thresholds."
  (when (session-stream session)
    (close (session-stream session))
    (setf (session-stream session) nil))
  (when (transcript-is-only-a-header-p (session-path session))
    (ignore-errors (delete-file (session-path session))))
  session)

(defun transcript-is-only-a-header-p (path)
  "Does this file contain a header line and nothing else?

THE FILE, not the in-memory entry list. Two attempts at this asked the session
object -- first with a string kind against an EQ test on keywords, then with
the keyword -- and both answered `empty` for a session that plainly had a
message in it, which would have deleted somebody's transcript. Counting lines
in the file cannot be misread: one line is the header a session is born with,
and anything more is content."
  (and (plusp (length path))
       (probe-file path)
       (handler-case
           (with-open-file (in path :if-does-not-exist nil)
             (and in
                  (let ((first (read-line in nil nil))
                        (second (read-line in nil nil)))
                    (and first (null second)))))
         (error () nil))))

(defun remember-entry (session entry)
  (push entry (session-entries session))
  (setf (gethash (entry-id entry) (session-index session)) entry)
  entry)

(defun append-entry (session kind payload &key (lane +main-lane+)
                                            (parent (lane-leaf session lane)))
  "Add one entry to the conversation tree and make it the new leaf.

PARENT defaults to the current leaf, so ordinary appends form a line. Passing an
older entry's id starts a branch there -- which is the whole of forking, and
needs no second file."
  (let ((entry (make-entry :id (next-entry-id) :parent parent :kind kind
                           :time (get-universal-time)
                           :payload (if (msg:message-p payload) (encode-message payload) payload))))
    (remember-entry session entry)
    (setf (lane-leaf session lane) (entry-id entry))
    (write-line* session (object "kind" (string-downcase (symbol-name kind))
                                 "id" (entry-id entry)
                                 "parent" parent
                                 "lane" (unless (string= lane +main-lane+) lane)
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

(defun append-custom-message (session custom-type message &key (display t))
  "A message an extension put into the conversation, marked as its own.

The distinction from an ordinary entry is the whole point. An extension that
injects by REWRITING the user's message destroys the record of what the person
actually typed, and on resume its words are indistinguishable from theirs. Kept
separate, the transcript still says who said what, and a reader can strip an
extension's contributions without guessing which ones they were."
  (append-entry session :custom-message
                (object "custom_type" custom-type
                        "display" display
                        "message" (encode-message message))))

(defun append-custom (session custom-type data)
  "Extension state, persisted beside the conversation and never sent to a model.

Pi's CustomEntry. In the tree so it is ordered against the turns it relates to,
but SESSION-MESSAGES yields nothing for it."
  (append-entry session :custom (object "custom_type" custom-type "data" data)))

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
                           (setf (lane-leaf session (or (gethash "lane" table) +main-lane+))
                                 (entry-id entry))))))))
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
                   ;; A custom MESSAGE is in the conversation; a custom ENTRY is
                   ;; state and is not. One letter of difference in the name and
                   ;; the whole difference in what reaches the model.
                   (:branch-summary
                    (a:when-let ((summary (and (hash-table-p (entry-payload entry))
                                               (gethash "summary" (entry-payload entry)))))
                      (list (msg:make-user-message
                             :content (list (msg:make-text
                                             (format nil "<abandoned_branch>~%~a~%</abandoned_branch>"
                                                     summary)))))))
                   (:custom-message
                    (a:when-let ((inner (and (hash-table-p (entry-payload entry))
                                             (gethash "message" (entry-payload entry)))))
                      (list (decode-message inner))))
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

(defun path-to-root (session leaf)
  "Ids from LEAF to the root, nearest first. Unlike ANCESTRY this does not stop
at a compaction: it is answering where two branches meet, not what to send."
  (let ((ids '()) (id leaf))
    (loop while id
          for entry = (entry-at session id)
          while entry
          do (push (entry-id entry) ids)
             (setf id (entry-parent entry)))
    (nreverse ids)))

(defun branch-point (session from to)
  "The nearest entry both branches share, or NIL when they share nothing."
  (let ((theirs (path-to-root session to)))
    (find-if (lambda (id) (member id theirs :test #'equal))
             (path-to-root session from))))

(defun abandoned-branch (session from to)
  "The entries on FROM's side that TO does not share, oldest first.

What a person is walking away from, and therefore what is worth summarising
before they lose sight of it."
  (let ((shared (branch-point session from to)))
    (reverse (loop for id = from then (entry-parent entry)
                   while (and id (not (equal id shared)))
                   for entry = (entry-at session id)
                   while entry
                   collect entry))))

(defun append-branch-summary (session summary &key from)
  "Record what an abandoned branch established, on the branch being resumed.

Pi's BranchSummaryEntry. Without it, trying a second approach means the first
one's findings are still on disk and entirely absent from the conversation --
so the model rediscovers what it already knows, having been given no way to
know that it knows it."
  (append-entry session :branch-summary (object "from" from "summary" summary)))

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

(defstruct (summary (:conc-name summary-))
  (id "" :type string) (path "" :type string) (cwd "" :type string)
  (time 0 :type integer) (messages 0 :type integer) (opening "" :type string))

(defun describe-session (path)
  "Enough to choose one from a list, without loading the whole file into a
picker: when it was, how long it ran, and what was first asked."
  (let* ((session (ignore-errors (load-session path)))
         (messages (and session (session-messages session))))
    (when session
      (make-summary :id (session-id session) :path (namestring path)
                    :cwd (session-cwd session)
                    :time (reduce #'max (mapcar #'entry-time (session-entries session))
                                  :initial-value 0)
                    :messages (length messages)
                    :opening (a:if-let ((first-message (first messages)))
                               (let ((text (substitute #\Space #\Newline (msg:text-of first-message))))
                                 (subseq text 0 (min 70 (length text))))
                               "")))))

(defun list-sessions (&key cwd (limit 20))
  "Sessions for CWD, or everywhere when CWD is NIL. Newest first."
  (let ((files (if cwd
                   (ignore-errors (directory (merge-pathnames "*.jsonl" (session-directory cwd))))
                   (ignore-errors (directory (merge-pathnames "*/*.jsonl" (session-directory)))))))
    (let ((found (sort (remove nil (mapcar #'describe-session files)) #'> :key #'summary-time)))
      (subseq found 0 (min limit (length found))))))

(defun find-session (id &key cwd)
  "A session by id or by any unambiguous prefix of one."
  (let ((matches (remove-if-not (lambda (each) (a:starts-with-subseq id (summary-id each)))
                                (list-sessions :cwd cwd :limit 1000))))
    (cond ((null matches) nil)
          ((rest matches) (error "~a matches ~d sessions. Use more of the id." id (length matches)))
          (t (first matches)))))

(defun search-sessions (text &key cwd (limit 20))
  "Sessions whose conversation contains TEXT, newest first.

Scans rather than indexes. An index would be faster and would then need
invalidating, rebuilding and reconciling against files another process appends
to; a few hundred JSONL files is not the problem an index solves."
  (let ((needle (string-downcase text)))
    (remove-if-not
     (lambda (each)
       (a:when-let ((session (ignore-errors (load-session (summary-path each)))))
         (some (lambda (message)
                 (search needle (string-downcase (msg:text-of message))))
               (session-messages session))))
     (list-sessions :cwd cwd :limit limit))))

(defun latest-session (&optional cwd)
  (first (list-sessions :cwd cwd :limit 1)))
