;;;; Settings, so they are not trapped in the clone.
;;;;
;;;; `bin/vivarium` resolves its root to the REPOSITORY and sources that
;;;; `.env`, which was fine while the only way to run vivarium was from inside
;;;; the repository. Once `vivarium install` puts the command on PATH, a
;;;; person's configuration lived in a directory they might never open again,
;;;; and there was no way to say "this project uses deepseek, that one uses the
;;;; local server".
;;;;
;;;;     ~/.vivarium/config      the machine's
;;;;     .vivarium/config        this project's, and it wins
;;;;
;;;; KEY=VALUE, the same shape as `.env`, deliberately. Every setting here is
;;;; a flat scalar, so a TOML or JSON parser would be a dependency taken on for
;;;; nesting that does not exist -- and it is the format people already
;;;; hand-edit in this project. `#` starts a comment.
;;;;
;;;; NO CREDENTIALS, and that is enforced rather than advised. `.env` is
;;;; gitignored; `.vivarium/config` is a file people commit, so a key in one is
;;;; a key published. A credential-shaped name is refused by name.

(in-package #:vivarium.config)

(defparameter +settings+
  '(("model" . "Which model to use, by catalogue name: deepseek, openai, openrouter, bedrock, local.")
    ("limit" . "Model requests one prompt may spend.")
    ("retain" . "Run the retention policy after each task: true or false.")
    ("colour" . "Paint output: true, false, or unset to follow the terminal.")
    ("root" . "Refuse any path outside this directory.")
    ("context-limit" . "How much context the model will accept."))
  "Every setting, and what it is for. A table rather than scattered lookups so
`vivarium config` cannot drift out of step with what is actually read.")

(defparameter +credential-marks+ '("KEY" "TOKEN" "SECRET" "PASSWORD" "CREDENTIAL")
  "Name fragments that mean a value nobody should commit.")

(defstruct (resolved (:conc-name resolved-))
  (value nil)
  ;; :flag :environment :project :machine -- so a person can be told not just
  ;; what the setting is but which of four files decided it.
  (source :default :type keyword))

(defun credential-like-p (name)
  (let ((upper (string-upcase name)))
    (some (lambda (mark) (search mark upper)) +credential-marks+)))

(defun parse-line (line)
  "One KEY=VALUE line, or NIL. Returns (values NAME VALUE)."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (unless (or (zerop (length trimmed)) (char= #\# (char trimmed 0)))
      (a:when-let ((equals (position #\= trimmed)))
        (values (string-downcase (string-trim " " (subseq trimmed 0 equals)))
                (string-trim '(#\Space #\") (subseq trimmed (1+ equals))))))))

(defun read-config (environment path)
  "Returns (values SETTINGS COMPLAINTS). A malformed file is named, never
silently treated as absent -- a config that quietly does nothing is worse than
one that is missing, because you go looking at the wrong thing."
  (let ((settings '()) (complaints '()))
    (when (env:path-exists-p environment path)
      (let ((text (or (ignore-errors (env:read-text environment path))
                      (progn (push (format nil "~a could not be read" path) complaints) ""))))
        (loop for line in (uiop:split-string text :separator '(#\Newline))
              for number from 1
              do (multiple-value-bind (name value) (parse-line line)
                   (cond ((null name)
                          (unless (or (zerop (length (string-trim '(#\Space #\Tab #\Return) line)))
                                      (a:starts-with #\# (string-left-trim " " line)))
                            (push (format nil "~a:~d is neither a comment nor NAME=VALUE" path number)
                                  complaints)))
                         ((credential-like-p name)
                          (push (format nil "~a:~d sets ~a. Credentials belong in .env, which is ~
gitignored -- this file is not, and a key committed is a key published."
                                        path number name)
                                complaints))
                         ((not (assoc name +settings+ :test #'string=))
                          (push (format nil "~a:~d sets ~a, which is not a setting. Known: ~{~a~^, ~}"
                                        path number name (mapcar #'car +settings+))
                                complaints))
                         (t (push (cons name value) settings)))))))
    (values (nreverse settings) (nreverse complaints))))

(defun machine-config-path ()
  (env:join-path (uiop:native-namestring (user-homedir-pathname)) ".vivarium" "config"))

(defun project-config-path (cwd)
  (env:join-path cwd ".vivarium" "config"))

(defparameter +reserved-variables+ '("VIVARIUM_ROOT" "VIVARIUM_SOCKET" "VIVARIUM_CWD")
  "Variables vivarium sets for its own machinery. A setting must never map onto
one of these: VIVARIUM_ROOT is the REPOSITORY, set by the launcher on every
run, and the `root` setting is the workspace jail. The mechanical mapping put
them on the same name, so every run in every project silently took the
repository as its jail and the agent could not touch the work it was pointed
at.")

(defparameter +environment-names+ '(("root" . "VIVARIUM_WORKSPACE_ROOT"))
  "Settings whose variable is not the mechanical one, and why: see
+RESERVED-VARIABLES+.")

(defun environment-name (setting)
  (or (cdr (assoc setting +environment-names+ :test #'string=))
      (format nil "VIVARIUM_~a" (substitute #\_ #\- (string-upcase setting)))))

(defun load-settings (cwd)
  "Every setting resolved, each remembering which layer decided it.

Order, weakest first: machine config, project config, environment. A flag beats
all of them and is applied by the caller, which is the only layer this cannot
see. The environment sits above the files because that is what every other tool
means by an exported variable -- and because the repository's `.env` is sourced
into it by the launcher, so a person who has always configured vivarium that
way keeps working unchanged.

Returns (values TABLE COMPLAINTS)."
  (let ((environment (env:make-local-environment :cwd cwd))
        (table (make-hash-table :test #'equal))
        (complaints '()))
    (flet ((absorb (path source)
             (multiple-value-bind (settings said) (read-config environment path)
               (setf complaints (append complaints said))
               (loop for (name . value) in settings
                     do (setf (gethash name table)
                              (make-resolved :value value :source source))))))
      (absorb (machine-config-path) :machine)
      (absorb (project-config-path cwd) :project))
    ;; SB-POSIX directly, as MODELS does: ENV is the filesystem abstraction and
    ;; knows nothing about the process environment.
    (loop for (name . nil) in +settings+
          for from-environment = (sb-posix:getenv (environment-name name))
          when (and from-environment (plusp (length from-environment)))
            do (setf (gethash name table)
                     (make-resolved :value from-environment :source :environment)))
    (values table complaints)))

(defun setting (table name &optional default)
  (a:if-let ((found (gethash name table)))
    (resolved-value found)
    default))

(defun source (table name)
  (a:if-let ((found (gethash name table)))
    (resolved-source found)
    :default))
