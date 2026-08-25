;;;; Whose code may this process run?
;;;;
;;;; Extensions asked this question first and answered it well: loading a file
;;;; from a repository is arbitrary code execution, so a project directory is
;;;; only loaded once its root has been trusted, and the trust record lives
;;;; OUTSIDE the project, where the project cannot edit itself into it.
;;;;
;;;; The tool registry has exactly the same exposure and had none of the
;;;; answer. `.viva/tools/` in a cloned repository is a script somebody
;;;; else wrote, and pointing viva at that repository ran it. So the
;;;; mechanism moves here, where two consumers can share one answer rather
;;;; than one consumer having it and the other forgetting.
;;;;
;;;; The machine's own directory (~/.viva) is always trusted: it is the
;;;; user's, not a project's, and requiring them to trust themselves would
;;;; teach the habit of clicking through the question that matters.

(in-package #:viva.trust)

(defvar *trust-file* nil
  "Where the trust record lives, or NIL for the user's own. Bound by the
suite so tests neither read nor pollute a real person's trusted projects --
the same isolation the journal root already takes.")

(defun trust-file ()
  ;; Through the resolver, not the constant. Spelling the directory name here
  ;; skipped the fallback, so a machine still on the former directory kept its
  ;; sessions and its keys and lost track of what it had trusted.
  (or *trust-file* (env:trust-file)))

(defun home-directory ()
  (env:home-directory))

(defun canonical (environment path)
  "PATH in the one form both sides must agree on: symlinks resolved, no
trailing slash.

Load-bearing, and found by driving the real server rather than the API. On
macOS /var is a symlink to /private/var, so a project trusted as
/var/folders/x and run as /private/var/folders/x is one directory and two
strings -- and the CLI reaches TRUENAME while the trust record did not, so
trusting a project left it refused. The trailing slash is a second source of
the same disagreement. TRUENAME fails on a path that does not exist, which is
not an error here: an untrusted non-existent path is still untrusted."
  (let* ((absolute (env:absolute-path environment path))
         (resolved (or (ignore-errors (namestring (truename absolute))) absolute)))
    (string-right-trim "/" resolved)))

(defun within-p (parent child)
  "Is CHILD inside PARENT, or PARENT itself?

Prefix matching alone claims /foo contains /foobar, which for a control that
decides what may execute is not a rounding error."
  (or (string= parent child)
      (and (a:starts-with-subseq parent child)
           (> (length child) (length parent))
           (char= #\/ (char child (length parent))))))

(defun trusted-roots (environment)
  (let ((path (trust-file)))
    (when (env:path-exists-p environment path)
      ;; *READ-EVAL* NIL: the trust file is data. A file that decides what may
      ;; execute must not itself execute while being read.
      (ignore-errors (with-standard-io-syntax
                       (let ((*read-eval* nil))
                         (read-from-string (env:read-text environment path))))))))

(defun trusted-p (environment root)
  (let ((wanted (canonical environment root)))
    (loop for recorded in (trusted-roots environment)
          thereis (string= wanted (canonical environment recorded)))))

(defun trust (environment root)
  "Record ROOT as a directory whose code may be loaded."
  (let ((roots (adjoin (canonical environment root) (trusted-roots environment)
                       :test #'string=)))
    (env:write-text environment (trust-file) (format nil "~s~%" roots))
    roots))

(defun machine-directory-p (environment directory)
  "Is DIRECTORY inside the user's own ~/.viva rather than a project's?"
  (within-p (canonical environment (home-directory))
            (canonical environment directory)))

(defun permitted-p (environment directory project)
  "May code under DIRECTORY be loaded for PROJECT?

The machine's own always. A project's only once trusted. Anything else is
refused, and the refusal is the caller's to report -- silently loading
nothing looks identical to there being nothing to load, which is how a
security control becomes invisible."
  (or (machine-directory-p environment directory)
      (not (within-p (canonical environment project)
                     (canonical environment directory)))
      (and (trusted-p environment project) t)))
