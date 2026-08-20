;;;; Where a command's options actually come from.
;;;;
;;;; A flag beats a config file beats a default, and until this existed there
;;;; was no middle term: every option was a flag or a hard-coded default, so
;;;; choosing a model meant `--model deepseek` on every command forever.
;;;;
;;;; The resolution is in ONE place because the alternative is each command
;;;; deciding for itself, which is how `--limit` came to mean 60 in a command
;;;; documented as 200.

(in-package #:vivarium.cli)

(defvar *settings* nil
  "This run's resolved settings, or NIL before they are loaded.")

(defun load-cli-settings (parsed)
  "Read the config for wherever this run is working, and report what is wrong
with it. Complaints go to stderr and never stop the run: a mistyped setting
should not stand between a person and their work, but it must not be silent
either -- a config that quietly does nothing sends you looking at the wrong
thing."
  (let ((cwd (or (a:when-let ((given (flag parsed "cwd")))
                   (ignore-errors (namestring (truename given))))
                 (uiop:native-namestring (uiop:getcwd)))))
    (multiple-value-bind (table complaints) (config:load-settings cwd)
      (dolist (complaint complaints) (format *error-output* "~&! ~a~%" complaint))
      (setf *settings* table))))

(defun option (parsed name &optional default)
  "NAME as a flag, else from config, else DEFAULT."
  (or (flag parsed name)
      (a:when-let ((table *settings*)) (config:setting table name))
      default))

(defun option-integer (parsed name default)
  (let ((raw (option parsed name)))
    (if raw
        (or (parse-integer raw :junk-allowed t)
            (error "~a wants a number, got ~s" name raw))
        default)))

(defun option-true-p (parsed name &optional (default "false"))
  (string= "true" (option parsed name default)))

(defun option-source (parsed name)
  (cond ((flag parsed name) :flag)
        ((null *settings*) :default)
        (t (config:source *settings* name))))

;;; vivarium config

(defun describe-source (source)
  (ecase source
    (:flag "a flag on this command")
    (:environment "the environment")
    (:project ".vivarium/config")
    (:machine "~/.vivarium/config")
    (:default "the built-in default")))

(defun command-config (parsed)
  "Show every setting, its value, and which layer decided it.

The source is the point. `why is it using that model` is unanswerable from a
value alone when four layers can supply it, and guessing wrong sends a person
editing a file that was never being read."
  (let ((cwd (namestring (truename (or (first (args-positional parsed))
                                       (flag parsed "cwd") ".")))))
   (multiple-value-bind (table complaints) (config:load-settings cwd)
    (format t "~&~a~%~%" cwd)
    ;; First, and on stdout. This command is where a person comes to find out
    ;; why their config is not working, so the reason it is not working cannot
    ;; be the one thing the command drops.
    (when complaints
      (dolist (complaint complaints) (format t "~&! ~a~%" complaint))
      (terpri))
    (format t "~&~14a ~20a ~a~%" "setting" "value" "from")
    (dolist (entry config:+settings+)
      (let* ((name (car entry))
             (value (config:setting table name))
             (source (if (flag parsed name) :flag (config:source table name))))
        (format t "~&~14a ~20a ~a~%" name (or (flag parsed name) value "-")
                (describe-source source))))
    (format t "~&~%  ~a~%  ~a~%~%" (config:machine-config-path)
            (config:project-config-path cwd))
    (dolist (entry config:+settings+)
      (format t "~&~14a ~a~%" (car entry) (cdr entry)))
    (format t "~&~%Credentials are not settings: they stay in .env, which is ~
gitignored.~%A config file is committed, and a key in a committed file is ~
published.~%")
    0)))
