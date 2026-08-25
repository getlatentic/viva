;;;; The capability boundary: files and processes.
;;;;
;;;; Every Level 1 tool is written against this and nothing else, so the tools
;;;; never touch the host directly. That buys three things the project already
;;;; knows it needs: a restricted environment for a scored arm, a recording one
;;;; for observation burden, and a remote one later -- none of which require
;;;; touching a tool.
;;;;
;;;; Paths are STRINGS, never pathnames. A CL pathname parses `*`, `?`, `[` and
;;;; a trailing dot as structure, so `find . -name "*.ts"` and a file literally
;;;; called `notes[1].md` both come apart on the way through. Native namestrings
;;;; are produced only at the moment a CL function demands one.

(in-package #:viva.env)

(define-condition env-error (error)
  ((code :initarg :code :reader env-error-code :type keyword)
   (path :initarg :path :reader env-error-path :initform nil)
   (detail :initarg :detail :initform "" :reader env-error-detail))
  (:report (lambda (condition stream)
             (format stream "~a~@[: ~a~]"
                     (env-error-detail condition)
                     (env-error-path condition)))))

(defun complain (code path format &rest arguments)
  (error 'env-error :code code :path path
                    :detail (apply #'format nil format arguments)))

;;; Path arithmetic, textual and total
;;;
;;; No syscall, no symlink resolution, no requirement that anything exists.
;;; `..` is resolved lexically, which is what a tool reporting a path back to a
;;; model should show it -- the canonical path through symlinks is a separate
;;; question and a separate call.

(defun split-path (path)
  "Components of PATH, and whether it was absolute."
  (let ((absolute (and (plusp (length path)) (char= #\/ (char path 0)))))
    (values (remove "" (uiop:split-string path :separator "/") :test #'string=)
            absolute)))

(defun normalize (components)
  (let ((stack '()))
    (dolist (component components (nreverse stack))
      (cond ((string= "." component))
            ((and (string= ".." component) stack (not (string= ".." (first stack))))
             (pop stack))
            (t (push component stack))))))

(defun render-path (components absolute)
  (cond (absolute (format nil "/~{~a~^/~}" components))
        (components (format nil "~{~a~^/~}" components))
        (t ".")))

(defun join-path (&rest parts)
  "Join PARTS textually. A later absolute part discards the earlier ones."
  (let ((accumulated '()) (absolute nil))
    (dolist (part (remove nil parts))
      (multiple-value-bind (components part-absolute) (split-path part)
        (when part-absolute (setf accumulated '() absolute t))
        (setf accumulated (append accumulated components))))
    (render-path (normalize accumulated) absolute)))

(defun parent-path (path)
  (multiple-value-bind (components absolute) (split-path path)
    (render-path (butlast (normalize components)) absolute)))

(defun base-name (path)
  (multiple-value-bind (components) (split-path path)
    (or (first (last components)) path)))

(defun relative-path (root path)
  "PATH expressed relative to ROOT, or PATH unchanged if it lies outside."
  (let ((prefix (if (a:ends-with #\/ root) root (concatenate 'string root "/"))))
    (cond ((string= root path) ".")
          ((a:starts-with-subseq prefix path) (subseq path (length prefix)))
          (t path))))

;;; Where viva keeps its own files
;;;
;;; One place, because the name is a product decision and it was spelled into
;;; twenty modules. Everything below derives from HOME-DIRECTORY, so moving any
;;; of it is one edit and no two callers can disagree about where a thing is.

(defparameter +data-directory+ ".viva")

(defun data-directory (parent)
  "PARENT's viva directory."
  (join-path parent +data-directory+))

(defun home-directory ()
  "The machine-level viva directory.

VIVA_HOME names it outright, which is how a test gets a directory of its own
and how somebody keeps their keys and sessions somewhere other than home."
  (or (sb-posix:getenv "VIVA_HOME")
      (data-directory (uiop:native-namestring (user-homedir-pathname)))))

(defun home-path (&rest leaves)
  (apply #'join-path (home-directory) leaves))

(defun project-path (cwd &rest leaves)
  (apply #'join-path (data-directory cwd) leaves))

;;; One name per thing kept, so no caller spells a path itself

(defun auth-path () (home-path "auth.json"))
(defun machine-config-file () (home-path "config"))
(defun machine-memory-file () (home-path "MEMORY.md"))
(defun sessions-directory () (home-path "sessions"))
(defun journal-directory () (home-path "journal"))
(defun trust-file () (home-path "trusted.sexp"))

(defun project-config-file (cwd) (project-path cwd "config"))
(defun project-memory-file (cwd) (project-path cwd "MEMORY.md"))
(defun services-directory (cwd) (project-path cwd "services"))
(defun retired-directory (cwd) (project-path cwd "retired"))

;;; Skills, tools, prompts and extensions are NOT here. Each exists at both
;;; levels and the machine's is merged with the project's, which HARNESS
;;; already does. A second name for one of the two halves would be a name that
;;; answers half the question.

;;; The environment

(defclass environment ()
  ((cwd :initarg :cwd :accessor env-cwd :type string
        :documentation "Absolute directory relative paths resolve against.")
   (root :initarg :root :accessor env-root :initform nil
         :documentation "When set, a path outside it is refused.

Not a sandbox. It is the same guard the image harness already enforces on its
shell: a scored agent that can read the directory holding its own answer key is
not being measured. Ordinary use leaves it NIL.")))

(defclass local-environment (environment) ()
  (:documentation "The host filesystem and a real shell."))

(defun canonical-directory (path)
  "PATH with symlinks resolved, or PATH unchanged if it does not exist.

EXPORTED, because every place that compares two paths needs it and every place
that has skipped it has produced the same bug. On macOS /tmp is a symlink to
/private/tmp, so two spellings of one directory do not compare equal:

  a trust record written under one name was invisible under the other, and a
  project silently refused to load its own extensions;
  a session directory inside the working tree was not recognised as inside it,
  so a search walked into the transcript of the search.

Three occurrences, one cause. Canonicalise before comparing, always."
  (let ((lexical (string-right-trim "/" (join-path path))))
    (or (ignore-errors
         (string-right-trim "/" (uiop:native-namestring
                                 (truename (uiop:parse-native-namestring
                                            (concatenate 'string lexical "/"))))))
        lexical)))

(defun make-local-environment (&key (cwd (uiop:native-namestring (uiop:getcwd))) root)
  (make-instance 'local-environment
                 :cwd (canonical-directory cwd)
                 :root (and root (canonical-directory root))))

(defstruct (info (:conc-name info-))
  (name "" :type string)
  (path "" :type string)
  (kind :file :type keyword)
  (size 0 :type integer))

(defgeneric absolute-path (environment path)
  (:documentation "PATH as an absolute string, resolved against the cwd.")
  (:method ((environment environment) path)
    (let ((resolved (join-path (env-cwd environment) path)))
      (a:when-let ((root (env-root environment)))
        (unless (or (string= root resolved)
                    (a:starts-with-subseq (concatenate 'string root "/") resolved))
          (complain :permission-denied resolved
                    "Refused: this agent only reaches ~a" root)))
      resolved)))

(defgeneric read-text (environment path)
  (:documentation "Whole file as a string. Undecodable bytes become U+FFFD."))

(defgeneric read-bytes (environment path))

(defgeneric write-text (environment path content)
  (:documentation "Create or replace PATH, creating parent directories."))

(defgeneric file-info (environment path)
  (:documentation "An INFO for PATH, or NIL when it does not exist.
Symlinks are reported as :SYMLINK and are not followed."))

(defgeneric list-directory (environment path)
  (:documentation "Direct children of PATH as INFOs, unsorted."))

(defgeneric ensure-directory (environment path))

(defgeneric delete-path (environment path &key recursive))

(defgeneric rename-path (environment from to)
  (:documentation "Move FROM to TO. BOTH ends are resolved through the
environment, so a move cannot be the way something leaves the root that
ABSOLUTE-PATH is there to confine it to."))

(defgeneric exec (environment command &key directory timeout on-output)
  (:documentation "Run COMMAND through a shell. Returns (values status output),
output being stdout and stderr interleaved as the terminal would show them.

ON-OUTPUT, when given, is called with each piece as it arrives, so a caller can
show a slow command working instead of showing nothing until it ends."))

(defun path-exists-p (environment path)
  (and (file-info environment path) t))

;;; The local implementation

(defmethod read-bytes ((environment local-environment) path)
  (let ((resolved (absolute-path environment path)))
    (handler-case
        (with-open-file (in (uiop:parse-native-namestring resolved)
                            :element-type '(unsigned-byte 8))
          (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
            (read-sequence bytes in)
            bytes))
      (file-error () (complain :not-found resolved "No such file")))))

(defmethod read-text ((environment local-environment) path)
  (let ((resolved (absolute-path environment path)))
    (let ((info (file-info environment resolved)))
      (unless info (complain :not-found resolved "No such file"))
      (when (eq :directory (info-kind info))
        (complain :is-directory resolved "That is a directory, not a file")))
    (with-open-file (in (uiop:parse-native-namestring resolved)
                        :external-format '(:utf-8 :replacement #\replacement_character))
      (let ((text (make-string (file-length in))))
        (subseq text 0 (read-sequence text in))))))

(defmethod write-text ((environment local-environment) path content)
  (let ((resolved (absolute-path environment path)))
    (ensure-directories-exist (uiop:parse-native-namestring (concatenate 'string (parent-path resolved) "/")))
    (with-open-file (out (uiop:parse-native-namestring resolved)
                         :direction :output :if-exists :supersede
                         :if-does-not-exist :create :external-format :utf-8)
      (write-string content out))
    resolved))

(defun kind-of-mode (mode)
  (cond ((sb-posix:s-isdir mode) :directory)
        ((sb-posix:s-islnk mode) :symlink)
        (t :file)))

(defmethod file-info ((environment local-environment) path)
  (let ((resolved (absolute-path environment path)))
    (handler-case
        (let ((stat (sb-posix:lstat resolved)))
          (make-info :name (base-name resolved) :path resolved
                     :kind (kind-of-mode (sb-posix:stat-mode stat))
                     :size (sb-posix:stat-size stat)))
      (sb-posix:syscall-error () nil))))

(defmethod list-directory ((environment local-environment) path)
  (let ((resolved (absolute-path environment path))
        (entries '()))
    (let ((directory (handler-case (sb-posix:opendir resolved)
                       (sb-posix:syscall-error ()
                         (complain :not-found resolved "Cannot list")))))
      (unwind-protect
           (loop for entry = (sb-posix:readdir directory)
                 until (sb-alien:null-alien entry)
                 for name = (sb-posix:dirent-name entry)
                 unless (member name '("." "..") :test #'string=)
                   do (a:when-let ((info (file-info environment (join-path resolved name))))
                        (push info entries)))
        (sb-posix:closedir directory)))
    entries))

(defmethod ensure-directory ((environment local-environment) path)
  (let ((resolved (absolute-path environment path)))
    (ensure-directories-exist (uiop:parse-native-namestring (concatenate 'string resolved "/")))
    resolved))

(defmethod rename-path ((environment local-environment) from to)
  (let ((source (absolute-path environment from))
        (target (absolute-path environment to)))
    (ensure-directories-exist
     (uiop:parse-native-namestring (concatenate 'string (parent-path target) "/")))
    ;; RENAME rather than copy-then-delete: a move interrupted halfway leaves
    ;; the thing in one place or the other, never in neither and never in both.
    (sb-posix:rename source target)
    target))

(defmethod delete-path ((environment local-environment) path &key recursive)
  (let* ((resolved (absolute-path environment path))
         (info (file-info environment resolved)))
    (cond ((null info) nil)
          ((eq :directory (info-kind info))
           (if recursive
               (uiop:delete-directory-tree (uiop:parse-native-namestring (concatenate 'string resolved "/"))
                                           :validate t)
               (sb-posix:rmdir resolved))
           t)
          (t (sb-posix:unlink resolved) t))))

;;; Process execution
;;;
;;; Streams are merged rather than kept apart because the tool result is one
;;; string in the end and a model reading interleaved output sees what a person
;;; running the command sees. A test runner that writes progress to stderr and
;;; failures to stdout is unreadable any other way.

(defun drain-available (stream sink on-output)
  "Move whatever STREAM has ready into SINK, and hand the same text onward.

READ-CHAR-NO-HANG rather than READ-LINE: a build that prints a progress bar
with no newline for thirty seconds would otherwise show nothing, which is the
hang this exists to remove."
  (let ((chunk (with-output-to-string (piece)
                 (loop for character = (read-char-no-hang stream nil nil)
                       while character
                       do (write-char character piece)
                          (write-char character sink)))))
    (when (and on-output (plusp (length chunk)))
      (ignore-errors (funcall on-output chunk)))
    chunk))

(defmethod exec ((environment local-environment) command
                 &key directory (timeout 120) on-output)
  "Run COMMAND, returning (values STATUS OUTPUT).

ON-OUTPUT, when given, is called with each piece as it arrives. Collecting
everything and returning at the end is why a slow command read as a hang: two
minutes of nothing, then everything at once. Pi has streamed since it existed
and needs no background option for the `slow command` case because of it."
  (let ((resolved (absolute-path environment (or directory (env-cwd environment)))))
    (let* ((sink (make-string-output-stream))
           (process (sb-ext:run-program "/bin/sh" (list "-c" command)
                                        ;; :STREAM, so this can be read while it
                                        ;; runs. The pipe is drained on every
                                        ;; poll -- an undrained pipe fills and
                                        ;; stops the process producing it.
                                        :output :stream :error :output
                                        :directory (uiop:parse-native-namestring
                                                    (concatenate 'string resolved "/"))
                                        :environment (sb-ext:posix-environ)
                                        :wait nil :search nil))
           (from (sb-ext:process-output process))
           (deadline (+ (get-internal-real-time)
                        (* timeout internal-time-units-per-second)))
           (timed-out nil))
      (loop while (eq :running (sb-ext:process-status process))
            do (drain-available from sink on-output)
               (when (> (get-internal-real-time) deadline)
                 (setf timed-out t)
                 (sb-ext:process-kill process sb-posix:sigkill :process-group)
                 (return))
               (sleep 0.02))
      (sb-ext:process-wait process)
      ;; Whatever landed between the last poll and the exit.
      (drain-available from sink on-output)
      (ignore-errors (close from))
      (values (if timed-out :timeout (or (sb-ext:process-exit-code process) 1))
              (let ((text (get-output-stream-string sink)))
                (if timed-out
                    (format nil "~a~%[killed after ~ds]" text timeout)
                    text))))))
