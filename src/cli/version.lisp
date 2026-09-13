;;;; What build this is.
;;;;
;;;; A binary somebody downloaded has no checkout to ask, and a checkout has no
;;;; business reporting a version somebody baked in before the last edit. Those
;;;; are two different answers to one question, so both are here rather than
;;;; wherever each is convenient.

(in-package #:viva.cli)

(defparameter *build-version* nil
  "Stamped into a saved image at build time, and NIL in a source run.")

(defun git-description (root)
  "What git calls the checkout at ROOT, or NIL where there is neither."
  (a:when-let ((line (ignore-errors
                      (string-trim '(#\Space #\Newline #\Return)
                                   (uiop:run-program
                                    (list "git" "-C" (namestring root)
                                          "describe" "--tags" "--always" "--dirty")
                                    :output :string :error-output nil)))))
    (when (plusp (length line)) line)))

(defun version ()
  "The version to report.

THE STAMP FIRST, because a standalone binary has no repository to ask. Falling
through to the checkout is for a source run, where the working tree is the truth
and a baked string would be wrong the moment somebody edited a file."
  (or *build-version*
      (a:when-let ((root (ignore-errors (repository-root))))
        (git-description root))
      "unknown"))
