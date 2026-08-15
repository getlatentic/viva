;;;; READ, WRITE, EDIT.
;;;;
;;;; Deliberately the same three verbs, the same argument names and the same
;;;; output limits as Pi. Vivarium is going to be compared against Pi on the
;;;; same model and the same task, and a comparison where one side reads 2000
;;;; lines and the other reads 400 measures the constant, not the harness.

(in-package #:vivarium.workspace)

(defvar *environment* nil
  "The execution environment tools act on. Bound per run, never global state.")

(defun environment ()
  (or *environment*
      (error "No environment bound. Use WITH-ENVIRONMENT, or bind ~
VIVARIUM.WORKSPACE:*ENVIRONMENT* to an ENV:ENVIRONMENT.")))

(defmacro with-environment ((environment) &body body)
  `(let ((*environment* ,environment)) ,@body))

(defun display-path (path)
  "How a path is echoed back: relative to the cwd when it is under it."
  (env:relative-path (env:env-cwd (environment)) path))

;;; read

(defun continuation (start shown total limit-hit)
  (let ((last (+ start shown -1)))
    (cond ((not limit-hit) "")
          (t (format nil "~%~%[Showing lines ~d-~d of ~d. Use offset=~d to continue.]"
                     start last total (1+ last))))))

(defun read-file (path &key offset limit)
  "The body of the READ tool, callable directly so a Lisp program can use the
same code path the model does."
  (let* ((text (env:read-text (environment) path))
         (lines (uiop:split-string text :separator (string #\Newline)))
         (total (length lines))
         (start (max 1 (or offset 1))))
    ;; An empty file is not an error. UIOP:SPLIT-STRING returns NIL rather than
    ;; ("") for "", so a zero-byte file reported "0 lines" and every read of one
    ;; failed -- which happened four times across the runs, on __init__.py.
    (when (zerop total)
      (return-from read-file ""))
    (when (> start total)
      (error "Offset ~d is past the end of the file, which has ~d lines." start total))
    (let* ((selected (subseq lines (1- start) (if limit
                                                  (min total (+ (1- start) limit))
                                                  total)))
           (cut (bound:truncate-head (format nil "~{~a~^~%~}" selected))))
      (cond ((bound:truncation-first-line-too-long-p cut)
             (format nil "[Line ~d is longer than the ~a limit. Read it with bash: ~
sed -n '~dp' ~a | head -c ~d]"
                     start (bound:format-size bound:+max-bytes+) start path bound:+max-bytes+))
            ((bound:truncation-cut-p cut)
             (format nil "~a~a" (bound:truncation-text cut)
                     (continuation start (bound:truncation-lines cut) total t)))
            ((< (+ (1- start) (length selected)) total)
             (format nil "~a~a" (bound:truncation-text cut)
                     (continuation start (length selected) total t)))
            (t (bound:truncation-text cut))))))

(tool:define-tool read-tool (args context)
  :name "read"
  :description "Read the contents of a file. Output is truncated to 2000 lines
or 50KB, whichever comes first; use offset and limit for large files, and keep
going with offset until you have what you need."
  :parameters (("path" :string "Path to the file, relative or absolute" :required-p t)
               ("offset" :integer "Line to start from, 1-indexed" :required-p nil)
               ("limit" :integer "How many lines to read" :required-p nil))
  (read-file (gethash "path" args)
             :offset (gethash "offset" args)
             :limit (gethash "limit" args)))

;;; write

(defun write-file (path content)
  (env:write-text (environment) path content)
  (format nil "Wrote ~d bytes to ~a." (length content) (display-path
                                                        (env:absolute-path (environment) path))))

(tool:define-tool write-tool (args context)
  :name "write"
  :description "Write a file, creating it and any parent directories, replacing
it if it already exists. To change part of an existing file use edit instead."
  :parameters (("path" :string "Path to the file, relative or absolute" :required-p t)
               ("content" :string "The complete new contents" :required-p t))
  (write-file (gethash "path" args) (gethash "content" args)))

;;; edit

(defun field (table &rest names)
  (loop for name in names
        for value = (and (hash-table-p table) (gethash name table))
        when value return value))

(defun coerce-edits (args)
  "Read the EDITS argument in any of the shapes models actually send it.

A model that has been told `edits` is an array sends it as a JSON string often
enough to matter, and one that has seen an older single-replacement edit tool
sends bare old_text/new_text. Both are the model getting the intent right and
the encoding wrong, and both are cheaper to accept than to explain."
  (let ((raw (gethash "edits" args)))
    (when (stringp raw)
      (setf raw (ignore-errors (jzon:parse raw))))
    (let ((edits (loop for entry across (if (vectorp raw) raw (coerce (or raw '()) 'vector))
                       for old = (field entry "old_text" "oldText" "old")
                       for new = (or (field entry "new_text" "newText" "new") "")
                       when old collect (cons old new))))
      (a:if-let ((old (field args "old_text" "oldText")))
        (append edits (list (cons old (or (field args "new_text" "newText") ""))))
        edits))))

(defun edit-file (path edits)
  (let* ((original (env:read-text (environment) path))
         (ending (edit:line-ending-of original))
         (normalized (edit:normalize-endings original)))
    (multiple-value-bind (updated placements) (edit:apply-edits normalized edits)
      (env:write-text (environment) path (edit:restore-endings updated ending))
      (values (format nil "Replaced ~d block~:p in ~a." (length edits) (display-path path))
              (edit:unified-diff (display-path path) normalized placements)))))

(tool:define-tool edit-tool (args context)
  :name "edit"
  :description "Change parts of a file by exact text replacement. Every old_text
must appear exactly once in the file as it is now, and two edits may not touch
the same lines -- merge those into one edit. All edits are matched against the
file's current contents, not against each other's results."
  :parameters (("path" :string "Path to the file, relative or absolute" :required-p t)
               ("edits" (:array (:object (("old_text" :string "Text to replace. Must be unique in the file." :required-p t)
                                          ("new_text" :string "What to put in its place." :required-p t))))
                "The replacements to make" :required-p t))
  (let ((edits (coerce-edits args)))
    (when (null edits)
      (return-from edit-tool
        (tool:make-tool-result
         :output "No edits given. Pass edits as [{\"old_text\": \"...\", \"new_text\": \"...\"}]."
         :error-p t)))
    (multiple-value-bind (summary diff) (edit-file (gethash "path" args) edits)
      (format nil "~a~%~a" summary diff))))

(defun file-tools ()
  (list read-tool write-tool edit-tool))
