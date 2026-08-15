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

(in-package #:vivarium.env)

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

Resolved once, here, so that everything downstream agrees on what directory it
is in. On macOS /tmp is a symlink to /private/tmp, and a trust record written
under one name is invisible under the other -- an extension directory that
silently refuses to load because two spellings of the same path did not
compare equal."
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

(defgeneric exec (environment command &key directory timeout)
  (:documentation "Run COMMAND through a shell. Returns (values status output),
output being stdout and stderr interleaved as the terminal would show them."))

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

(defmethod exec ((environment local-environment) command &key directory (timeout 120))
  (let ((resolved (absolute-path environment (or directory (env-cwd environment)))))
    (let* ((output (make-string-output-stream))
           (process (sb-ext:run-program "/bin/sh" (list "-c" command)
                                        :output output :error output
                                        :directory (uiop:parse-native-namestring
                                                    (concatenate 'string resolved "/"))
                                        :environment (sb-ext:posix-environ)
                                        :wait nil :search nil))
           (deadline (+ (get-internal-real-time)
                        (* timeout internal-time-units-per-second)))
           (timed-out nil))
      (loop while (eq :running (sb-ext:process-status process))
            do (when (> (get-internal-real-time) deadline)
                 (setf timed-out t)
                 (sb-ext:process-kill process sb-posix:sigkill :process-group)
                 (return))
               (sleep 0.02))
      (sb-ext:process-wait process)
      (values (if timed-out :timeout (or (sb-ext:process-exit-code process) 1))
              (let ((text (get-output-stream-string output)))
                (if timed-out
                    (format nil "~a~%[killed after ~ds]" text timeout)
                    text))))))
